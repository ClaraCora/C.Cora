import Foundation

struct LogLine: Identifiable, Sendable {
    let id = UUID()
    let time: Date
    let type: String       // info / warning / error / debug
    let payload: String
}

private struct LogDisplayState {
    let lines: [LogLine]
    let bufferedLineCount: Int

    static let empty = LogDisplayState(lines: [], bufferedLineCount: 0)
}

/// 日志页数据源：优先读 App Group 共享的 run.log；不可用时经版本化 NE IPC 增量读取。
///
/// 天花板是「设置里的日志级别」：run.log 由内核按该级别过滤后落盘。
/// 视图里的级别只在这个天花板内**客户端再筛**：原始日志全存 rawLines，展示用的 lines = rawLines
/// 按 level + 搜索词过滤。切级别/改搜索只是重过滤，**绝不清空、绝不重连**——修了「切级别再切回来
/// 日志就没了」。所以设 info 时最多到 info；想看 debug 要把设置里的日志级别调到 debug。
@MainActor
final class LogStreamController: ObservableObject {

    /// 全局共享：由 RootView 按连接状态驱动启停，切 tab 后日志缓冲不清空。
    static let shared = LogStreamController()

    /// 展示行与原始缓冲数量一起发布，一批日志只触发一次视图刷新。
    @Published private var display = LogDisplayState.empty
    @Published var isStreaming = false
    @Published private(set) var isAwaitingNewSession = false
    @Published var error: String?
    /// 过滤级别（silent/error/warning/info/debug），默认取设置里的级别。
    @Published private(set) var level: String = SettingsStore.shared.logLevel
    /// 搜索词（不区分大小写，匹配正文）。
    @Published var searchText: String = "" { didSet { scheduleSearch() } }

    var lines: [LogLine] { display.lines }
    var hasBufferedLines: Bool { display.bufferedLineCount > 0 }
    var bufferedLineCount: Int { display.bufferedLineCount }

    private var tailer: LogFileTailer?
    private var rawLines: [LogLine] = []     // 所有收到的原始日志
    private var ipcTask: Task<Void, Never>?
    private var ipcOffset = -1
    private var ipcLogGeneration = 0
    private var searchTask: Task<Void, Never>?
    private var generation = 0
    private let maxLines = 1000

    private static var sharedLogURL: URL? {
        AppGroup.containerURL?.appendingPathComponent("run.log")
    }

    func start(awaitingNewSession: Bool = false) {
        if isStreaming {
            // connecting 通知若晚于 NE 写入新文件，baseline 可能已是本次会话。
            // connected 时重开当前文件，保证不会永远停在 awaiting 状态。
            if isAwaitingNewSession && !awaitingNewSession {
                restartWithCurrentSession()
            }
            return
        }
        generation &+= 1
        let currentGeneration = generation
        isStreaming = true
        isAwaitingNewSession = awaitingNewSession
        error = nil
        ipcTask?.cancel()
        searchTask?.cancel()
        // connecting 阶段先保留上一会话，检测到 run.log 截断或新会话标记后再切换。
        if !awaitingNewSession { beginNewSession() }

        if let url = Self.sharedLogURL {
            startFileTail(url, expectFileReset: awaitingNewSession,
                          generation: currentGeneration)
        } else {
            if !awaitingNewSession {
                ipcOffset = -1
                ipcLogGeneration = 0
            }
            startIPCPoll(generation: currentGeneration,
                         needsBaseline: awaitingNewSession && ipcLogGeneration == 0)
        }
    }

    func stop() {
        if isAwaitingNewSession, tailer != nil {
            // 秒断时可能尚未来得及轮询截断；重读当前文件后再做最后一次 flush。
            restartWithCurrentSession()
        }
        tailer?.stop(flushRemaining: true)
        tailer = nil
        ipcTask?.cancel()
        ipcTask = nil
        isStreaming = false
        isAwaitingNewSession = false
    }

    /// 切换过滤级别：只重过滤，保留已有日志，不清空也不重连。
    func setLevel(_ newLevel: String) {
        guard newLevel != level else { return }
        level = newLevel
        searchTask?.cancel()
        recompute()
    }

    func clear() {
        if !isStreaming { generation &+= 1 }
        searchTask?.cancel()
        ipcTask?.cancel()
        ipcTask = nil
        rawLines.removeAll()
        display = .empty
    }

    // MARK: - 过滤

    private func append(_ new: [LogLine]) {
        guard !new.isEmpty else { return }
        let previousCount = rawLines.count
        rawLines.append(contentsOf: new)
        let overflow = max(0, rawLines.count - maxLines)
        let droppedIDs = overflow > 0
            ? Set(rawLines.prefix(overflow).map(\.id))
            : Set<UUID>()
        if overflow > 0 { rawLines.removeFirst(overflow) }
        // 一批数据只修改一次 Published 数组，避免每条日志触发一次整页刷新。
        let minRank = Self.rank(level)
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let droppedFromNew = max(0, overflow - previousCount)
        let accepted = new.dropFirst(min(droppedFromNew, new.count)).filter {
            Self.rank($0.type) >= minRank
                && (q.isEmpty || $0.payload.lowercased().contains(q))
        }
        var updated = display.lines
        if !droppedIDs.isEmpty {
            updated.removeAll { droppedIDs.contains($0.id) }
        }
        updated.append(contentsOf: accepted)
        if updated.count > maxLines { updated.removeFirst(updated.count - maxLines) }
        display = LogDisplayState(lines: updated, bufferedLineCount: rawLines.count)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch {
                return
            }
            self?.recompute()
        }
    }

    private func recompute() {
        let minRank = Self.rank(level)
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = rawLines.filter {
            Self.rank($0.type) >= minRank && (q.isEmpty || $0.payload.lowercased().contains(q))
        }
        display = LogDisplayState(lines: filtered, bufferedLineCount: rawLines.count)
    }

    private func beginNewSession() {
        rawLines.removeAll()
        display = .empty
        isAwaitingNewSession = false
    }

    private func restartWithCurrentSession() {
        generation &+= 1
        let currentGeneration = generation
        tailer?.stop()
        tailer = nil
        ipcTask?.cancel()
        ipcTask = nil
        error = nil
        beginNewSession()

        if let url = Self.sharedLogURL {
            startFileTail(url, expectFileReset: false, generation: currentGeneration)
        } else {
            ipcOffset = -1
            ipcLogGeneration = 0
            startIPCPoll(generation: currentGeneration, needsBaseline: false)
        }
    }

    /// 级别严重度排序：debug < info < warning < error < silent。选某级别即显示「≥ 它」的行。
    private static func rank(_ level: String) -> Int {
        switch level.lowercased() {
        case "debug":           return 0
        case "info":            return 1
        case "warning", "warn": return 2
        case "error":           return 3
        case "silent":          return 4
        default:                return 1
        }
    }

    // MARK: - 文件源

    private func startFileTail(_ url: URL,
                               expectFileReset: Bool,
                               generation: Int) {
        let t = LogFileTailer(url: url)
        t.onLines = { [weak self] new, fileWasReset in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                var received = new
                if fileWasReset {
                    self.beginNewSession()
                } else if self.isAwaitingNewSession {
                    guard let marker = received.lastIndex(where: {
                        $0.type.lowercased() == "wrap"
                            && $0.payload.hasPrefix("StartWithConfig:")
                    }) else { return }
                    self.beginNewSession()
                    received = Array(received[marker...])
                }
                self.append(received)
            }
        }
        tailer = t
        t.start(expectFileReset: expectFileReset)
    }

    // MARK: - IPC 增量源

    private func startIPCPoll(generation: Int, needsBaseline initialBaseline: Bool) {
        ipcTask = Task { [weak self] in
            var needsBaseline = initialBaseline
            while !Task.isCancelled {
                guard let self, self.generation == generation else { return }
                let result = await CoreStateManager.shared.sendMessage([
                    "cmd": "runLogChunk",
                    "offset": self.ipcOffset,
                    "generation": self.ipcLogGeneration,
                ])
                guard !Task.isCancelled, self.generation == generation else { return }
                switch result {
                case .failure(let reason):
                    if self.rawLines.isEmpty { self.error = reason }
                case .ok(let data):
                    guard let object = (try? JSONSerialization.jsonObject(with: data))
                            as? [String: Any],
                          let offset = (object["offset"] as? NSNumber)?.intValue,
                          let logGeneration = (object["generation"] as? NSNumber)?.intValue
                    else {
                        if self.rawLines.isEmpty { self.error = "日志 IPC 响应无法解析" }
                        break
                    }
                    if let reason = object["error"] as? String, !reason.isEmpty {
                        if self.rawLines.isEmpty { self.error = reason }
                        break
                    }
                    self.ipcOffset = offset
                    self.ipcLogGeneration = logGeneration
                    let text = object["text"] as? String ?? ""
                    let lines = text.split(separator: "\n").map {
                        LogFileTailer.parseLine(String($0))
                    }
                    if needsBaseline {
                        needsBaseline = false
                        if let marker = lines.lastIndex(where: {
                            $0.type.lowercased() == "wrap"
                                && $0.payload.hasPrefix("StartWithConfig:")
                        }) {
                            self.beginNewSession()
                            self.append(Array(lines[marker...]))
                            self.error = nil
                        }
                        break
                    }
                    if (object["reset"] as? Bool) == true {
                        self.beginNewSession()
                    }
                    self.append(lines)
                    self.error = nil
                }
                do {
                    try await Task.sleep(nanoseconds: 800_000_000)
                } catch {
                    return
                }
            }
        }
    }
}
