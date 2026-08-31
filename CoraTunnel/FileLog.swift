import Foundation

/// NE 扩展的运行日志。
///
/// 用户证书来自他人、无法控制开发者账号 → 注册不了 App Group。因此日志**不依赖
/// App Group 共享文件**。日志保留在进程内缓冲，普通签名经系统 IPC 回传；
/// TrollStore 包经共享目录文件 IPC 调用同一个 handleAppMessage 命令处理器。
/// 这条通道不需要任何共享容器，只要 NE 在运行即可读取。
///
/// 若 App Group 可用，会写入有界的 ne.log，并在新会话开始时轮换为
/// ne.previous.log。这样 NE 被系统停止后，主 App 仍有机会导出上一会话的现场。
enum FileLog {

    private static let queue = DispatchQueue(label: "com.cora.tunnel.filelog")
    private static let maxBufferedLines = 512
    private static let trimBufferedLinesAt = 640
    private static let maxFileBytes: UInt64 = 512 * 1024
    private static let currentFileName = "ne.log"
    private static let previousFileName = "ne.previous.log"
    private static var buffer: [String] = []
    private static var bufferedBytes: UInt64 = 0
    private static var persistedBytes: UInt64 = 0
    private static var pendingPersistedData = Data()
    private static var persistedHandle: FileHandle?
    private static let persistBatchLines = 32
    private static let persistBatchBytes = 16 * 1024
    private static let persistBatchDelay: TimeInterval = 0.1
    private static var persistFlushScheduled = false
    private static var persistFlushGeneration: UInt64 = 0

    struct Stats {
        let bufferedLines: Int
        let bufferedBytes: UInt64
        let persistedBytes: UInt64
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 开始新会话：清空内存缓冲，但保留上一会话的持久化日志。
    static func reset() {
        queue.sync {
            flushPersistedLogLocked(close: true)
            buffer.removeAll()
            bufferedBytes = 0
            persistedBytes = 0
            rotatePersistedLogLocked()
        }
    }

    /// 追加一行（带时间戳）。
    static func write(_ message: String) {
        queue.sync {
            let line = "\(formatter.string(from: Date())) [NE] \(message)"
            buffer.append(line)
            bufferedBytes += UInt64(line.utf8.count)
            if buffer.count >= trimBufferedLinesAt {
                let removeCount = buffer.count - maxBufferedLines
                for removed in buffer.prefix(removeCount) {
                    bufferedBytes = bufferedBytes >= UInt64(removed.utf8.count)
                        ? bufferedBytes - UInt64(removed.utf8.count) : 0
                }
                buffer.removeFirst(removeCount)
            }

            // best-effort：App Group 可用时也落一份有界文件，便于将来排查。
            if let url = AppGroup.containerURL?.appendingPathComponent(currentFileName) {
                let data = Data((line + "\n").utf8.prefix(64 * 1024))
                if persistedBytes + UInt64(pendingPersistedData.count) + UInt64(data.count) > maxFileBytes {
                    flushPersistedLogLocked(close: true)
                    rotatePersistedLogLocked()
                    persistedBytes = 0
                }
                if persistedHandle == nil {
                    if !FileManager.default.fileExists(atPath: url.path) {
                        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
                    }
                    persistedHandle = try? FileHandle(forWritingTo: url)
                    if let handle = persistedHandle { persistedBytes = (try? handle.seekToEnd()) ?? persistedBytes }
                }
                if persistedHandle != nil {
                    pendingPersistedData.append(data)
                    if pendingPersistedData.count >= persistBatchBytes || buffer.count % persistBatchLines == 0 {
                        flushPersistedLogLocked(close: false)
                    } else {
                        schedulePersistFlushLocked()
                    }
                } else if (try? data.write(to: url, options: .atomic)) != nil {
                    persistedBytes = UInt64(data.count)
                }
            }
        }
    }

    /// 导出 NE 专用日志。最多返回当前与上一会话各一份有界文件，
    /// 不把完整日志长期留在进程内；无 App Group 时退回当前内存缓冲。
    static func export() -> String {
        queue.sync {
            flushPersistedLogLocked(close: true)
            guard let directory = AppGroup.containerURL else {
                let current = buffer.joined(separator: "\n")
                return current.isEmpty ? "(App Group 不可用，暂无 NE 持久化日志)" : current
            }

            let currentURL = directory.appendingPathComponent(currentFileName)
            let previousURL = directory.appendingPathComponent(previousFileName)
            let previous = readFileLocked(previousURL, maxBytes: maxFileBytes)
            let current = readFileLocked(currentURL, maxBytes: maxFileBytes)
            var sections: [String] = []
            if let previous, !previous.isEmpty {
                sections.append("===== ne.previous.log（上一会话）=====\n" + previous)
            }
            if let current, !current.isEmpty {
                sections.append("===== ne.log（当前会话）=====\n" + current)
            }
            if sections.isEmpty {
                let fallback = buffer.joined(separator: "\n")
                return fallback.isEmpty ? "(暂无 NE 日志)" : fallback
            }
            return sections.joined(separator: "\n\n")
        }
    }

    private static func flushPersistedLogLocked(close: Bool) {
        persistFlushGeneration &+= 1
        persistFlushScheduled = false
        if pendingPersistedData.isEmpty {
            if close, let handle = persistedHandle {
                try? handle.synchronize()
                try? handle.close()
                persistedHandle = nil
            }
            return
        }
        guard let directory = AppGroup.containerURL else {
            pendingPersistedData.removeAll(keepingCapacity: true)
            if close, let handle = persistedHandle {
                try? handle.close()
                persistedHandle = nil
            }
            return
        }
        let url = directory.appendingPathComponent(currentFileName)
        if persistedHandle == nil { persistedHandle = try? FileHandle(forWritingTo: url) }
        if let handle = persistedHandle {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: pendingPersistedData)
            persistedBytes += UInt64(pendingPersistedData.count)
            try? handle.synchronize()
            if close { try? handle.close(); persistedHandle = nil }
            pendingPersistedData.removeAll(keepingCapacity: true)
        }
    }

    /// Flush low-volume logs after a short delay so a quiet NE still leaves
    /// recent diagnostics on disk, while keeping the common burst path batched.
    private static func schedulePersistFlushLocked() {
        guard !persistFlushScheduled, !pendingPersistedData.isEmpty else { return }
        persistFlushScheduled = true
        let generation = persistFlushGeneration
        queue.asyncAfter(deadline: .now() + persistBatchDelay) {
            guard generation == persistFlushGeneration else { return }
            persistFlushScheduled = false
            flushPersistedLogLocked(close: false)
        }
    }

    /// 在轮换前移动当前文件，不使用 Data(contentsOf:) 将整份文件加载到堆中。
    private static func rotatePersistedLogLocked() {
        guard let directory = AppGroup.containerURL else { return }
        let currentURL = directory.appendingPathComponent(currentFileName)
        let previousURL = directory.appendingPathComponent(previousFileName)
        let manager = FileManager.default

        guard manager.fileExists(atPath: currentURL.path) else { return }
        let size: UInt64
        if let attributes = try? manager.attributesOfItem(atPath: currentURL.path),
           let number = attributes[.size] as? NSNumber {
            size = number.uint64Value
        } else {
            size = 0
        }
        guard size > 0 else {
            try? Data().write(to: currentURL, options: .atomic)
            return
        }

        do {
            if manager.fileExists(atPath: previousURL.path) {
                try manager.removeItem(at: previousURL)
            }
            try manager.moveItem(at: currentURL, to: previousURL)
            try Data().write(to: currentURL, options: .atomic)
        } catch {
            // 轮换失败时仍截断当前文件，避免日志持续增长；内存缓冲仍可经 IPC 导出。
            try? Data().write(to: currentURL, options: .atomic)
        }
    }

    private static func readFileLocked(_ url: URL, maxBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let offset = size > maxBytes ? size - maxBytes : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// 导出当前缓冲全部内容（供 handleAppMessage 回传主 App）。
    static func dump() -> String {
        queue.sync { buffer.joined(separator: "\n") }
    }

    static func stats() -> Stats {
        queue.sync {
            Stats(bufferedLines: buffer.count,
                  bufferedBytes: bufferedBytes,
                  persistedBytes: persistedBytes)
        }
    }
}
