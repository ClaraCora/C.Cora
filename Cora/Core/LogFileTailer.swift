import Foundation

/// 轮询式 tail：定时从 run.log 上次读到的位置续读新增内容，解析成 LogLine。
///
/// run.log 由 mihomo 封装层（startLogCapture）逐行写入，格式：
/// `2026-08-02T02:12:30.123Z [info] payload`。
/// 文件在每次连接时被 O_TRUNC 清空——检测到文件变小即从头重读。
final class LogFileTailer: @unchecked Sendable {

    private let url: URL
    private var offset: UInt64 = 0
    private var prefix = Data()
    private var partialLine = Data()
    private var expectingReset = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.cora.logtail", qos: .utility)
    private static let maxReadBytes = 256 * 1024
    private static let maxPartialLineBytes = 64 * 1024

    /// 新解析出的日志行（在后台队列回调，调用方自行切主线程）。
    var onLines: (([LogLine], _ fileWasReset: Bool) -> Void)?

    init(url: URL) { self.url = url }

    func start(expectFileReset: Bool = false) {
        offset = 0
        prefix.removeAll()
        partialLine.removeAll()
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
            partialLine.removeAll(keepingCapacity: true)
        }
        guard size > offset else {
            if fileWasReset { onLines?([], true) }
            return
        }

        try? handle.seek(toOffset: offset)
        let data = (try? handle.read(upToCount: Self.maxReadBytes)) ?? Data()
        offset += UInt64(data.count)

        guard !data.isEmpty else {
            if fileWasReset { onLines?([], true) }
            return
        }
        partialLine.append(data)
        var chunks = partialLine.split(separator: 0x0A, omittingEmptySubsequences: false)
        if partialLine.last == 0x0A {
            partialLine.removeAll(keepingCapacity: true)
            if chunks.last?.isEmpty == true { chunks.removeLast() }
        } else if let trailing = chunks.popLast() {
            partialLine = Data(trailing.suffix(Self.maxPartialLineBytes))
        }
        let parsed = chunks.compactMap { bytes -> LogLine? in
            guard !bytes.isEmpty else { return nil }
            return Self.parseLine(String(decoding: bytes, as: UTF8.self))
        }
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

    /// 解析带时区的新时间戳，并兼容旧版只有 UTC 时分秒的日志。
    static func parseLine(_ line: String) -> LogLine {
        guard let lb = line.firstIndex(of: "["),
              let rb = line.firstIndex(of: "]"), lb < rb else {
            return LogLine(time: Date(), type: "info", payload: line)
        }
        let level = line[line.index(after: lb)..<rb].lowercased()
        let payload = line[line.index(after: rb)...].trimmingCharacters(in: .whitespaces)
        let timeToken = line[..<lb].trimmingCharacters(in: .whitespaces)
        let time = Self.timestampFormatter.date(from: timeToken)
            ?? Self.legacyUTCFormatter.date(from: timeToken)
            ?? Date()
        return LogLine(time: time, type: level, payload: payload)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 旧版 Go/iOS 运行时写出的无时区时间实际为 UTC。
    private static let legacyUTCFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
