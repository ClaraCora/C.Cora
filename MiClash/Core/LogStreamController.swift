import Foundation

struct LogLine: Identifiable {
    let id = UUID()
    let time: Date
    let type: String       // info / warning / error / debug
    let payload: String
}

/// 日志页数据源：**优先读 App Group 共享的 run.log（文件 tail），否则退回 /logs WebSocket**。
///
/// 级别过滤与搜索一律**客户端做**：原始日志全存 rawLines，展示用的 lines = rawLines 按
/// level + 搜索词过滤。切级别/改搜索只是重过滤，**绝不清空、绝不重连**——这修了「切级别再切
/// 回来日志就没了」的问题（旧实现 WS 切级别会清空 lines 并重连流）。
/// WS 源以最宽的 debug 订阅一次（mihomo 日志总线本就推送所有级别），拿全后客户端再筛。
@MainActor
final class LogStreamController: ObservableObject {

    /// 全局共享：由 RootView 按连接状态驱动启停，切 tab 后日志缓冲不清空。
    static let shared = LogStreamController()

    /// 展示用（已按 level + 搜索过滤）。
    @Published private(set) var lines: [LogLine] = []
    @Published var isStreaming = false
    @Published var error: String?
    /// 过滤级别（silent/error/warning/info/debug），默认取设置里的级别。
    @Published private(set) var level: String = SettingsStore.shared.logLevel
    /// 搜索词（不区分大小写，匹配正文）。
    @Published var searchText: String = "" { didSet { recompute() } }

    private let stream = MihomoStream()
    private var tailer: LogFileTailer?
    private var rawLines: [LogLine] = []     // 所有收到的原始日志
    private var usingFile = false
    private let maxLines = 1000

    private static var sharedLogURL: URL? {
        AppGroup.containerURL?.appendingPathComponent("run.log")
    }

    func start() {
        isStreaming = true
        error = nil
        rawLines.removeAll()
        lines.removeAll()

        if let url = Self.sharedLogURL {
            usingFile = true
            startFileTail(url)
        } else {
            usingFile = false
            startSocket()
        }
    }

    func stop() {
        stream.stop()
        tailer?.stop()
        tailer = nil
        isStreaming = false
    }

    /// 切换过滤级别：只重过滤，保留已有日志，不清空也不重连。
    func setLevel(_ newLevel: String) {
        guard newLevel != level else { return }
        level = newLevel
        recompute()
    }

    func clear() {
        rawLines.removeAll()
        lines.removeAll()
    }

    // MARK: - 过滤

    private func append(_ new: [LogLine]) {
        rawLines.append(contentsOf: new)
        if rawLines.count > maxLines { rawLines.removeFirst(rawLines.count - maxLines) }
        // 增量：只把通过过滤的新行追加进 lines（避免每行全量重算）
        let minRank = Self.rank(level)
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        for line in new where Self.rank(line.type) >= minRank
            && (q.isEmpty || line.payload.lowercased().contains(q)) {
            lines.append(line)
        }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    private func recompute() {
        let minRank = Self.rank(level)
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        lines = rawLines.filter {
            Self.rank($0.type) >= minRank && (q.isEmpty || $0.payload.lowercased().contains(q))
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

    private func startFileTail(_ url: URL) {
        let t = LogFileTailer(url: url)
        t.onLines = { [weak self] new in
            Task { @MainActor in self?.append(new) }
        }
        tailer = t
        t.start()
    }

    // MARK: - WebSocket 源（以 debug 全量订阅，客户端再筛）

    private func startSocket() {
        stream.onObject = { [weak self] obj in
            let line = LogLine(
                time: Date(),
                type: obj["type"] as? String ?? "info",
                payload: obj["payload"] as? String ?? "")
            Task { @MainActor in self?.append([line]) }
        }
        stream.onClose = { [weak self] _ in
            Task { @MainActor in
                if self?.rawLines.isEmpty ?? true { self?.error = "未连接内核（请先连接 VPN）" }
            }
        }
        stream.start(path: "logs", query: [URLQueryItem(name: "level", value: "debug")])
    }
}
