import Foundation

struct LogLine: Identifiable {
    let id = UUID()
    let type: String       // info / warning / error / debug
    let payload: String
}

/// 日志页：订阅 mihomo external-controller 的 /logs 流。
/// chunked 流逐行返回 {"type","payload"}；只保留最近 N 条，避免内存膨胀。
@MainActor
final class LogStreamController: ObservableObject {

    /// 全局共享：由 RootView 按连接状态驱动启停，切 tab 后日志缓冲不清空。
    static let shared = LogStreamController()

    @Published private(set) var lines: [LogLine] = []
    @Published var isStreaming = false
    @Published var error: String?

    private let stream = MihomoStream()
    private let maxLines = 500

    func start() {
        isStreaming = true
        error = nil
        stream.onObject = { [weak self] obj in
            let line = LogLine(
                type: obj["type"] as? String ?? "info",
                payload: obj["payload"] as? String ?? "")
            Task { @MainActor in self?.append(line) }
        }
        stream.onClose = { [weak self] _ in
            Task { @MainActor in
                if self?.lines.isEmpty ?? true { self?.error = "未连接内核（请先连接 VPN）" }
            }
        }
        stream.start(path: "logs")
    }

    func stop() {
        stream.stop()
        isStreaming = false
    }

    func clear() { lines.removeAll() }

    private func append(_ line: LogLine) {
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }
}
