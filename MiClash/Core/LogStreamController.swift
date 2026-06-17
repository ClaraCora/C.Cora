import Foundation

struct LogLine: Identifiable {
    let id = UUID()
    let time: Date
    let type: String       // info / warning / error / debug
    let payload: String
}

/// 日志页数据源：**优先读 App Group 共享的 run.log（文件 tail），否则退回 external-controller 的 /logs WebSocket**。
///
/// - 有 App Group（容器里有 run.log）→ 读文件:无 WebSocket 断流问题,日志由 NE 落盘,
///   级别在客户端按 `level` 过滤,切级别即时生效(无需重连)。
/// - 无 App Group(借证书装) → 走 /logs WS:不依赖共享容器,任何环境可用,
///   级别作为 server 端 `level` 查询参数下发,切级别重连流。
///
/// mihomo `/logs` 缺省按 info 过滤(日志总线推送所有级别),所以 WS 路径要显式带 level。
@MainActor
final class LogStreamController: ObservableObject {

    /// 全局共享：由 RootView 按连接状态驱动启停，切 tab 后日志缓冲不清空。
    static let shared = LogStreamController()

    /// 视图展示用（文件源：已按 level 过滤；WS 源：server 已过滤）。
    @Published private(set) var lines: [LogLine] = []
    @Published var isStreaming = false
    @Published var error: String?
    /// 当前过滤级别（silent/error/warning/info/debug）。默认取设置里的级别。
    @Published private(set) var level: String = SettingsStore.shared.logLevel

    private let stream = MihomoStream()
    private var tailer: LogFileTailer?
    private var rawLines: [LogLine] = []     // 文件源的未过滤缓冲
    private var usingFile = false
    private let maxLines = 500

    /// App Group 共享的 run.log 路径（容器不可用时为 nil）。
    private static var sharedLogURL: URL? {
        AppGroup.containerURL?.appendingPathComponent("run.log")
    }

    func start() {
        isStreaming = true
        error = nil
        rawLines.removeAll()
        lines.removeAll()

        // 决策按「App Group 是否授权」(容器非 nil)，而非 run.log 此刻是否存在——
        // start() 可能在 .connecting 时就触发，NE 还没来得及建文件；tailer 会等它出现。
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

    /// 切换过滤级别。文件源即时重过滤；WS 源以新级别重连流。
    func setLevel(_ newLevel: String) {
        guard newLevel != level else { return }
        level = newLevel
        if usingFile {
            refilter()
        } else if isStreaming {
            lines.removeAll()
            stream.start(path: "logs", query: [URLQueryItem(name: "level", value: level)])
        }
    }

    func clear() {
        rawLines.removeAll()
        lines.removeAll()
    }

    // MARK: - 文件源

    private func startFileTail(_ url: URL) {
        let t = LogFileTailer(url: url)
        t.onLines = { [weak self] new in
            Task { @MainActor in self?.appendFile(new) }
        }
        tailer = t
        t.start()
    }

    private func appendFile(_ new: [LogLine]) {
        rawLines.append(contentsOf: new)
        if rawLines.count > maxLines { rawLines.removeFirst(rawLines.count - maxLines) }
        refilter()
    }

    private func refilter() {
        let minRank = Self.rank(level)
        lines = rawLines.filter { Self.rank($0.type) >= minRank }
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

    // MARK: - WebSocket 源

    private func startSocket() {
        stream.onObject = { [weak self] obj in
            let line = LogLine(
                time: Date(),
                type: obj["type"] as? String ?? "info",
                payload: obj["payload"] as? String ?? "")
            Task { @MainActor in self?.appendSocket(line) }
        }
        stream.onClose = { [weak self] _ in
            Task { @MainActor in
                if self?.lines.isEmpty ?? true { self?.error = "未连接内核（请先连接 VPN）" }
            }
        }
        stream.start(path: "logs", query: [URLQueryItem(name: "level", value: level)])
    }

    private func appendSocket(_ line: LogLine) {
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }
}
