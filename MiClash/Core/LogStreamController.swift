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

    @Published private(set) var lines: [LogLine] = []
    @Published var isStreaming = false
    @Published var error: String?

    private var task: Task<Void, Never>?
    private let maxLines = 500

    func start() {
        guard task == nil else { return }
        isStreaming = true
        error = nil
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let stream = try await MihomoAPI.lineStream(path: "logs")
                    self?.error = nil
                    for try await obj in stream {
                        if Task.isCancelled { break }
                        let line = LogLine(
                            type: obj["type"] as? String ?? "info",
                            payload: obj["payload"] as? String ?? "")
                        self?.append(line)
                    }
                } catch {
                    self?.error = "未连接内核（请先连接 VPN）"
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
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
