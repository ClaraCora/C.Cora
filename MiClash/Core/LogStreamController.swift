import Foundation

struct LogLine: Identifiable {
    let id = UUID()
    let time: Date
    let type: String       // info / warning / error / debug
    let payload: String
}

/// 日志页：订阅 mihomo external-controller 的 /logs 流。
///
/// 重点：mihomo `/logs` 的级别过滤靠 **`level` 查询参数**，缺省时它按 `info` 过滤——
/// 日志总线本身会推送所有级别，所以不带 level 就会看到 info。这里把用户设置的级别
/// 作为 level 参数下发，并支持在日志页里实时切换（切换即重连流，无需重连 VPN）。
@MainActor
final class LogStreamController: ObservableObject {

    /// 全局共享：由 RootView 按连接状态驱动启停，切 tab 后日志缓冲不清空。
    static let shared = LogStreamController()

    @Published private(set) var lines: [LogLine] = []
    @Published var isStreaming = false
    @Published var error: String?
    /// 当前过滤级别（silent/error/warning/info/debug）。默认取设置里的级别。
    @Published private(set) var level: String = SettingsStore.shared.logLevel

    private let stream = MihomoStream()
    private let maxLines = 500

    func start() {
        isStreaming = true
        error = nil
        stream.onObject = { [weak self] obj in
            let line = LogLine(
                time: Date(),
                type: obj["type"] as? String ?? "info",
                payload: obj["payload"] as? String ?? "")
            Task { @MainActor in self?.append(line) }
        }
        stream.onClose = { [weak self] _ in
            Task { @MainActor in
                if self?.lines.isEmpty ?? true { self?.error = "未连接内核（请先连接 VPN）" }
            }
        }
        stream.start(path: "logs", query: [URLQueryItem(name: "level", value: level)])
    }

    func stop() {
        stream.stop()
        isStreaming = false
    }

    /// 实时切换过滤级别：清空当前缓冲并以新级别重连流。
    func setLevel(_ newLevel: String) {
        guard newLevel != level else { return }
        level = newLevel
        guard isStreaming else { return }
        lines.removeAll()
        stream.start(path: "logs", query: [URLQueryItem(name: "level", value: level)])
    }

    func clear() { lines.removeAll() }

    private func append(_ line: LogLine) {
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }
}
