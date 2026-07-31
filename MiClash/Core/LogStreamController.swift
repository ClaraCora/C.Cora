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

/// 日志页数据源：**优先读 App Group 共享的 run.log（文件 tail），否则退回 /logs WebSocket**。
///
/// 天花板是「设置里的日志级别」：文件源(run.log)由内核按该级别过滤后落盘，WS 源以该级别订阅。
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

    private let stream = MihomoStream()
    private var tailer: LogFileTailer?
    private var rawLines: [LogLine] = []     // 所有收到的原始日志
    private var pendingSocketLines: [LogLine] = []
    private var socketFlushTask: Task<Void, Never>?
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
        socketFlushTask?.cancel()
        pendingSocketLines.removeAll(keepingCapacity: true)
        searchTask?.cancel()
        // connecting 阶段先保留上一会话，检测到 run.log 截断（或第一帧 WS）再切换。
        if !awaitingNewSession { beginNewSession() }

        if let url = Self.sharedLogURL {
            startFileTail(url, expectFileReset: awaitingNewSession,
                          generation: currentGeneration)
        } else {
            startSocket(generation: currentGeneration)
        }
    }

    func stop() {
        if isAwaitingNewSession, tailer != nil {
            // 秒断时可能尚未来得及轮询截断；重读当前文件后再做最后一次 flush。
            restartWithCurrentSession()
        }
        stream.stop()
        tailer?.stop(flushRemaining: true)
        tailer = nil
        socketFlushTask?.cancel()
        socketFlushTask = nil
        if !pendingSocketLines.isEmpty {
            let pending = pendingSocketLines
            pendingSocketLines.removeAll(keepingCapacity: true)
            append(pending)
        }
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
        socketFlushTask?.cancel()
        socketFlushTask = nil
        pendingSocketLines.removeAll(keepingCapacity: true)
        rawLines.removeAll()
        display = .empty
    }

    // MARK: - 过滤

    private func append(_ new: [LogLine]) {
        guard !new.isEmpty else { return }
        rawLines.append(contentsOf: new)
        if rawLines.count > maxLines { rawLines.removeFirst(rawLines.count - maxLines) }
        // 一批数据只修改一次 Published 数组，避免每条日志触发一次整页刷新。
        let minRank = Self.rank(level)
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let accepted = new.filter {
            Self.rank($0.type) >= minRank
                && (q.isEmpty || $0.payload.lowercased().contains(q))
        }
        var updated = display.lines
        let retainedIDs = Set(rawLines.map(\.id))
        updated.removeAll { !retainedIDs.contains($0.id) }
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
        stream.stop()
        tailer?.stop()
        tailer = nil
        socketFlushTask?.cancel()
        socketFlushTask = nil
        pendingSocketLines.removeAll(keepingCapacity: true)
        error = nil
        beginNewSession()

        if let url = Self.sharedLogURL {
            startFileTail(url, expectFileReset: false, generation: currentGeneration)
        } else {
            startSocket(generation: currentGeneration)
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

    // MARK: - WebSocket 源（以 debug 全量订阅，客户端再筛）

    private func startSocket(generation: Int) {
        stream.onObject = { [weak self] obj in
            let line = LogLine(
                time: Date(),
                type: obj["type"] as? String ?? "info",
                payload: obj["payload"] as? String ?? "")
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.enqueueSocketLine(line)
            }
        }
        stream.onClose = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                if self.rawLines.isEmpty { self.error = "未连接内核（请先连接 VPN）" }
            }
        }
        // 以「设置里的日志级别」为天花板订阅（不再固定 debug），与文件源/设置语义一致；
        // 视图里切级别只在此天花板内客户端再筛。
        stream.start(path: "logs", query: [URLQueryItem(name: "level", value: SettingsStore.shared.logLevel)])
    }

    /// App Group 不可用时 WS 可能逐帧回调；合并 150ms 后再发布到 UI。
    private func enqueueSocketLine(_ line: LogLine) {
        if isAwaitingNewSession { beginNewSession() }
        pendingSocketLines.append(line)
        guard socketFlushTask == nil else { return }
        socketFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard let self else { return }
            let pending = self.pendingSocketLines
            self.pendingSocketLines.removeAll(keepingCapacity: true)
            self.socketFlushTask = nil
            self.append(pending)
        }
    }
}
