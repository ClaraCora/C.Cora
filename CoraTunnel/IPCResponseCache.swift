import Foundation

/// Short-lived IPC hand-offs only. Encoding and in-flight bridge copies are
/// separate from this cache's 512 KiB retained payload budget.
final class IPCResponseCache: @unchecked Sendable {
    static let chunkSize = 12 * 1_024
    static let maximumPayloadBytes = 8 * 1_024 * 1_024
    static let maximumResponses = 12
    static let maximumMemoryBytes = 512 * 1_024
    static let memoryResponseThreshold = 64 * 1_024

    struct Descriptor {
        let token: String
        let total: Int
    }

    struct Stats {
        let count: Int
        let payloadBytes: Int
        let memoryBytes: Int
        let fileBytes: Int
    }

    enum CacheError: Error {
        case expiredSession
        case oversizedResponse
        case storageUnavailable

        var message: String {
            switch self {
            case .expiredSession: return "IPC 响应已过期"
            case .oversizedResponse: return "控制响应超过 8 MB 上限"
            case .storageUnavailable: return "无法暂存控制响应，请稍后重试"
            }
        }
    }

    private enum Storage {
        case memory(Data)
        case file(URL)
    }

    private struct Entry {
        let storage: Storage
        let size: Int
        let expiresAt: Date
    }

    private let lock = NSLock()
    private let cleanupQueue = DispatchQueue(label: "com.cora.tunnel.ipc-cleanup", qos: .utility)
    private let directory: URL
    private let lifetime: TimeInterval
    private let writePayload: (Data, URL) throws -> Void
    private var entries: [String: Entry] = [:]
    private var payloadBytes = 0
    private var memoryBytes = 0
    private var generation: UInt64 = 0
    private var enabled = true
    private var cleanupWorkItem: DispatchWorkItem?
    private var cleanupDeadline: Date?
    private var cleanupRevision: UInt64 = 0

    init(directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("cora-ipc-responses", isDirectory: true),
         lifetime: TimeInterval = 30,
         writePayload: ((Data, URL) throws -> Void)? = nil) {
        self.directory = directory
        self.lifetime = lifetime
        self.writePayload = writePayload ?? IPCResponseCache.writeFile
        // This directory belongs only to this cache in the NE sandbox. A killed
        // extension cannot run reset(), so clear its leftovers on process launch.
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path)
            #endif
            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
            for file in files { try FileManager.default.removeItem(at: file) }
        } catch {
            // The bounded memory fallback remains available if storage is locked
            // before first unlock or the temporary directory cannot be prepared.
        }
    }

    deinit {
        cleanupWorkItem?.cancel()
        for entry in entries.values {
            if case .file(let url) = entry.storage { try? FileManager.default.removeItem(at: url) }
        }
    }

    func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled && expectedGeneration == generation
    }

    func stats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return Stats(count: entries.count, payloadBytes: payloadBytes,
                     memoryBytes: memoryBytes, fileBytes: payloadBytes - memoryBytes)
    }

    func store(_ data: Data, generation expectedGeneration: UInt64) throws -> Descriptor {
        guard !data.isEmpty, data.count <= Self.maximumPayloadBytes else {
            throw CacheError.oversizedResponse
        }
        let token = UUID().uuidString
        lock.lock()
        guard enabled, expectedGeneration == generation else {
            lock.unlock()
            throw CacheError.expiredSession
        }
        purgeExpiredLocked(now: Date())
        if data.count <= Self.memoryResponseThreshold,
           memoryBytes + data.count <= Self.maximumMemoryBytes {
            installLocked(token: token, storage: .memory(data), size: data.count)
            lock.unlock()
            return Descriptor(token: token, total: data.count)
        }
        lock.unlock()

        // Large writes never hold the cache lock or block unrelated chunk reads.
        // The session can end while this write runs; validate again before commit.
        let url = directory.appendingPathComponent(token + ".response")
        var didWrite = false
        do {
            try writePayload(data, url)
            didWrite = true
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
        lock.lock()
        guard enabled, expectedGeneration == generation else {
            lock.unlock()
            if didWrite { try? FileManager.default.removeItem(at: url) }
            throw CacheError.expiredSession
        }
        purgeExpiredLocked(now: Date())
        if didWrite {
            installLocked(token: token, storage: .file(url), size: data.count)
        } else if memoryBytes + data.count <= Self.maximumMemoryBytes {
            installLocked(token: token, storage: .memory(data), size: data.count)
        } else {
            lock.unlock()
            throw CacheError.storageUnavailable
        }
        lock.unlock()
        return Descriptor(token: token, total: data.count)
    }

    func chunk(token: String, offset: Int, generation expectedGeneration: UInt64) -> Data {
        guard UUID(uuidString: token) != nil, offset >= 0 else { return Data() }
        lock.lock()
        defer { lock.unlock() }
        guard enabled, expectedGeneration == generation else { return Data() }
        purgeExpiredLocked(now: Date())
        guard let entry = entries[token], offset < entry.size else {
            removeLocked(token)
            return Data()
        }
        let length = min(Self.chunkSize, entry.size - offset)
        let chunk: Data
        do {
            switch entry.storage {
            case .memory(let data):
                chunk = data.subdata(in: offset..<(offset + length))
            case .file(let url):
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(offset))
                chunk = try handle.read(upToCount: length) ?? Data()
                guard chunk.count == length else {
                    removeLocked(token)
                    return Data()
                }
            }
        } catch {
            removeLocked(token)
            return Data()
        }
        if offset + chunk.count == entry.size { removeLocked(token) }
        return chunk
    }

    func reset(enableCaching: Bool? = nil) {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        cleanupRevision &+= 1
        cleanupWorkItem?.cancel()
        cleanupWorkItem = nil
        cleanupDeadline = nil
        for token in Array(entries.keys) { removeLocked(token) }
        entries.removeAll(keepingCapacity: false)
        if let enableCaching { enabled = enableCaching }
    }

    private func installLocked(token: String, storage: Storage, size: Int) {
        while entries.count >= Self.maximumResponses || payloadBytes + size > Self.maximumPayloadBytes {
            guard let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key else { break }
            removeLocked(oldest)
        }
        entries[token] = Entry(storage: storage, size: size,
                               expiresAt: Date().addingTimeInterval(lifetime))
        payloadBytes += size
        if case .memory = storage { memoryBytes += size }
        scheduleCleanupLocked()
    }

    private func removeLocked(_ token: String) {
        guard let entry = entries.removeValue(forKey: token) else { return }
        payloadBytes -= entry.size
        switch entry.storage {
        case .memory: memoryBytes -= entry.size
        case .file(let url): try? FileManager.default.removeItem(at: url)
        }
    }

    private func purgeExpiredLocked(now: Date) {
        let expired = entries.compactMap { $0.value.expiresAt <= now ? $0.key : nil }
        for token in expired { removeLocked(token) }
    }

    private func scheduleCleanupLocked() {
        guard let deadline = entries.values.map({ $0.expiresAt }).min() else { return }
        if let scheduled = cleanupDeadline, scheduled <= deadline { return }
        cleanupWorkItem?.cancel()
        cleanupRevision &+= 1
        let revision = cleanupRevision
        let expectedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            self?.expire(revision: revision, generation: expectedGeneration)
        }
        cleanupDeadline = deadline
        cleanupWorkItem = work
        cleanupQueue.asyncAfter(deadline: .now() + max(0.01, deadline.timeIntervalSinceNow), execute: work)
    }

    private func expire(revision: UInt64, generation expectedGeneration: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard revision == cleanupRevision, expectedGeneration == generation else { return }
        cleanupWorkItem = nil
        cleanupDeadline = nil
        purgeExpiredLocked(now: Date())
        scheduleCleanupLocked()
    }

    private static func writeFile(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
