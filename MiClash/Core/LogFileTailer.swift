import Foundation

/// 轮询式 tail：定时从 run.log 上次读到的位置续读新增内容，解析成 LogLine。
///
/// run.log 由 mihomo 封装层（startLogCapture）逐行写入，格式：`15:04:05.000 [info] payload`。
/// 文件在每次连接时被 O_TRUNC 清空——检测到文件变小即从头重读。
final class LogFileTailer: @unchecked Sendable {

    private let url: URL
    private var offset: UInt64 = 0
    private var prefix = Data()
    private var expectingReset = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.miclash.logtail", qos: .utility)

    /// 新解析出的日志行（在后台队列回调，调用方自行切主线程）。
    var onLines: (([LogLine], _ fileWasReset: Bool) -> Void)?

    init(url: URL) { self.url = url }

    func start(expectFileReset: Bool = false) {
        offset = 0
        prefix.removeAll()
        expectingReset = expectFileReset
        if expectFileReset {
            // 连接状态先于 NE 启动变为 connecting；记录旧文件末尾，等待新会话截断。
            queue.sync { captureBaseline() }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(800))
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    func stop(flushRemaining: Bool = false) {
        timer?.cancel()
        timer = nil
        if flushRemaining {
            // 队列串行，若定时 poll 已入队也不会重复读取同一偏移。
            queue.async { [self] in poll() }
        }
    }

    private func poll() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let newPrefix = (try? handle.read(upToCount: 512)) ?? Data()
        let prefixChanged = !prefix.isEmpty && !Self.isPrefixGrowth(from: prefix, to: newPrefix)
        let fileCreated = expectingReset && prefix.isEmpty && !newPrefix.isEmpty && offset == 0
        prefix = newPrefix

        let fileWasReset = size < offset || prefixChanged || fileCreated
        if fileWasReset {
            offset = 0
            expectingReset = false
        }
        guard size > offset else {
            if fileWasReset { onLines?([], true) }
            return
        }

        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            if fileWasReset { onLines?([], true) }
            return
        }
        let parsed = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { parse(String($0)) }
        if fileWasReset || !parsed.isEmpty { onLines?(parsed, fileWasReset) }
    }

    private func captureBaseline() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        offset = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        prefix = (try? handle.read(upToCount: 512)) ?? Data()
    }

    /// 正常追加时前缀只会从短内容增长到 512 字节；截断重写则公共前缀会变化。
    private static func isPrefixGrowth(from old: Data, to new: Data) -> Bool {
        if new.count >= old.count { return new.starts(with: old) }
        return old.starts(with: new)
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
