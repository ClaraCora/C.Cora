import Foundation

/// 轮询式 tail：定时从 run.log 上次读到的位置续读新增内容，解析成 LogLine。
///
/// run.log 由 mihomo 封装层（startLogCapture）逐行写入，格式：`15:04:05.000 [info] payload`。
/// 文件在每次连接时被 O_TRUNC 清空——检测到文件变小即从头重读。
final class LogFileTailer: @unchecked Sendable {

    private let url: URL
    private var offset: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.miclash.logtail", qos: .utility)

    /// 新解析出的日志行（在后台队列回调，调用方自行切主线程）。
    var onLines: (([LogLine]) -> Void)?

    init(url: URL) { self.url = url }

    func start() {
        offset = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(800))
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0 }      // 文件被截断（重连），从头读
        guard size > offset else { return }

        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset = size

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        let parsed = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { parse(String($0)) }
        if !parsed.isEmpty { onLines?(parsed) }
    }

    /// 解析 `15:04:05.000 [info] payload`；解析不出就整行当 info。
    private func parse(_ line: String) -> LogLine {
        guard let lb = line.firstIndex(of: "["),
              let rb = line.firstIndex(of: "]"), lb < rb else {
            return LogLine(time: Date(), type: "info", payload: line)
        }
        let level = line[line.index(after: lb)..<rb].lowercased()
        let payload = line[line.index(after: rb)...].trimmingCharacters(in: .whitespaces)
        let timeToken = line[..<lb].trimmingCharacters(in: .whitespaces)
        let time = Self.timeFormatter.date(from: timeToken) ?? Date()
        return LogLine(time: time, type: level, payload: payload)
    }

    /// 解析行首时间（仅时分秒，日期无关——视图只显示时间）。
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
