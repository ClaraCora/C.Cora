import Foundation

private func expect(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cora-ipc-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fileCount(_ directory: URL) throws -> Int {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count
}

private func consume(_ cache: IPCResponseCache, _ descriptor: IPCResponseCache.Descriptor,
                     generation: UInt64) -> Data {
    var result = Data()
    while result.count < descriptor.total {
        let chunk = cache.chunk(token: descriptor.token, offset: result.count, generation: generation)
        expect(!chunk.isEmpty && chunk.count <= IPCResponseCache.chunkSize, "missing or oversized chunk")
        result.append(chunk)
    }
    return result
}

private final class LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [IPCResponseCache.Descriptor] = []
    private var failures = 0
    func append(_ value: IPCResponseCache.Descriptor) {
        lock.lock(); defer { lock.unlock() }
        descriptors.append(value)
    }
    func fail() { lock.lock(); failures += 1; lock.unlock() }
    func snapshot() -> ([IPCResponseCache.Descriptor], Int) {
        lock.lock(); defer { lock.unlock() }
        return (descriptors, failures)
    }
}

@main
struct IPCResponseCacheTests {
    static func main() throws {
        try roundTripsAndMemoryBudget()
        try parallelResponses()
        try evictionAndPayloadLimit()
        try writeFailures()
        try sessionChangeDuringWrite()
        try abandonedResponseExpiration()
        try damagedFileAndStartupCleanup()
        print("IPC response cache tests passed")
    }

    static func roundTripsAndMemoryBudget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = IPCResponseCache(directory: directory)
        let generation = cache.currentGeneration()
        for size in [16_385, 65_536, 65_537, 256 * 1_024 + 3] {
            let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
            let descriptor = try cache.store(payload, generation: generation)
            expect(cache.stats().memoryBytes == (size <= 65_536 ? size : 0), "wrong storage threshold")
            expect(consume(cache, descriptor, generation: generation) == payload, "response bytes changed")
            expect(cache.stats().count == 0 && cache.stats().payloadBytes == 0, "final read did not release entry")
            expect(try fileCount(directory) == 0, "final read left a file")
        }
        var descriptors: [IPCResponseCache.Descriptor] = []
        let payload = Data(repeating: 42, count: 64 * 1_024)
        for _ in 0..<12 { descriptors.append(try cache.store(payload, generation: generation)) }
        expect(cache.stats().count == 12, "lost script response slots")
        expect(cache.stats().memoryBytes == 512 * 1_024, "memory budget exceeded")
        expect(cache.stats().fileBytes == 256 * 1_024, "memory overflow was not spooled")
        for descriptor in descriptors { expect(consume(cache, descriptor, generation: generation) == payload, "burst response changed") }
        expect(cache.stats().count == 0 && cache.stats().memoryBytes == 0, "burst cleanup failed")
    }

    static func parallelResponses() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = IPCResponseCache(directory: directory)
        let generation = cache.currentGeneration()
        let payload = Data(repeating: 99, count: 256 * 1_024)
        let results = LockedResults()
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do { results.append(try cache.store(payload, generation: generation)) }
            catch { results.fail() }
        }
        let (descriptors, failures) = results.snapshot()
        expect(failures == 0 && descriptors.count == 12, "parallel script responses failed")
        expect(cache.stats().count == 12 && cache.stats().memoryBytes == 0, "parallel retention is wrong")
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            expect(consume(cache, descriptors[index], generation: generation) == payload, "parallel chunk bytes changed")
        }
        expect(try fileCount(directory) == 0 && cache.stats().count == 0, "parallel files remain")
    }

    static func evictionAndPayloadLimit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = IPCResponseCache(directory: directory)
        let generation = cache.currentGeneration()
        let old = try cache.store(Data(repeating: 0, count: 65_537), generation: generation)
        Thread.sleep(forTimeInterval: 0.002)
        for _ in 0..<12 { _ = try cache.store(Data(repeating: 1, count: 65_537), generation: generation) }
        expect(cache.stats().count == 12, "response count exceeded 12")
        expect(cache.chunk(token: old.token, offset: 0, generation: generation).isEmpty, "old response not evicted")
        expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(old.token + ".response").path), "eviction left file")
        let full = try cache.store(Data(repeating: 2, count: 8 * 1_024 * 1_024), generation: generation)
        expect(cache.stats().count == 1 && cache.stats().payloadBytes == 8 * 1_024 * 1_024, "total payload cap failed")
        do {
            _ = try cache.store(Data(repeating: 3, count: 8 * 1_024 * 1_024 + 1), generation: generation)
            preconditionFailure("oversized response accepted")
        } catch IPCResponseCache.CacheError.oversizedResponse {}
        expect(cache.stats().count == 1, "failed store evicted valid response")
        _ = try cache.store(Data(repeating: 4, count: 20_000), generation: generation)
        expect(cache.chunk(token: full.token, offset: 0, generation: generation).isEmpty, "byte limit did not evict")
        cache.reset(enableCaching: false)
        expect(cache.stats().count == 0 && cache.stats().memoryBytes == 0, "stop did not clear cache")
        do {
            _ = try cache.store(Data([1]), generation: cache.currentGeneration())
            preconditionFailure("disabled cache accepted response")
        } catch IPCResponseCache.CacheError.expiredSession {}
        expect(try fileCount(directory) == 0, "stop left files")
    }

    static func writeFailures() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = IPCResponseCache(directory: directory, writePayload: { _, url in
            try Data([9]).write(to: url)
            throw CocoaError(.fileWriteOutOfSpace)
        })
        let generation = cache.currentGeneration()
        let payload = Data(repeating: 42, count: 128 * 1_024)
        let descriptor = try cache.store(payload, generation: generation)
        expect(cache.stats().memoryBytes == payload.count && cache.stats().fileBytes == 0, "bounded fallback failed")
        expect(try fileCount(directory) == 0, "failed write left partial file")
        do {
            _ = try cache.store(Data(repeating: 0, count: 512 * 1_024), generation: generation)
            preconditionFailure("fallback exceeded memory budget")
        } catch IPCResponseCache.CacheError.storageUnavailable {}
        expect(cache.stats().count == 1, "write failure destroyed valid response")
        expect(consume(cache, descriptor, generation: generation) == payload, "fallback bytes changed")
    }

    static func sessionChangeDuringWrite() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let results = LockedResults()
        let cache = IPCResponseCache(directory: directory, writePayload: { data, url in
            started.signal()
            expect(finish.wait(timeout: .now() + 3) == .success, "test write stalled")
            try data.write(to: url, options: .atomic)
        })
        let generation = cache.currentGeneration()
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                results.append(try cache.store(Data(repeating: 1, count: 65_537), generation: generation))
            } catch IPCResponseCache.CacheError.expiredSession { results.fail() }
            catch { preconditionFailure("unexpected stale-write error: \(error)") }
        }
        expect(started.wait(timeout: .now() + 3) == .success, "write did not start")
        cache.reset(enableCaching: true)
        let current = cache.currentGeneration()
        let small = try cache.store(Data([7]), generation: current)
        finish.signal()
        expect(done.wait(timeout: .now() + 3) == .success, "write did not finish")
        expect(results.snapshot().1 == 1 && cache.stats().count == 1, "old write polluted new session")
        expect(cache.chunk(token: small.token, offset: 0, generation: generation).isEmpty, "old request read new session")
        expect(consume(cache, small, generation: current) == Data([7]), "new session response lost")
        expect(try fileCount(directory) == 0, "stale write left file")
    }

    static func abandonedResponseExpiration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = IPCResponseCache(directory: directory, lifetime: 0.04)
        _ = try cache.store(Data(repeating: 1, count: 65_537), generation: cache.currentGeneration())
        let deadline = Date().addingTimeInterval(2)
        // stats() does not purge; only the scheduled cleanup can release this.
        while cache.stats().count != 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let remainingFiles = try fileCount(directory)
        expect(cache.stats().count == 0 && remainingFiles == 0, "abandoned response required an App read to expire")
    }

    static func damagedFileAndStartupCleanup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0]).write(to: directory.appendingPathComponent("crash-leftover"))
        let cache = IPCResponseCache(directory: directory)
        expect(try fileCount(directory) == 0, "startup did not remove leftovers")
        let generation = cache.currentGeneration()
        let descriptor = try cache.store(Data(repeating: 8, count: 65_537), generation: generation)
        let file = directory.appendingPathComponent(descriptor.token + ".response")
        try Data([8]).write(to: file)
        expect(cache.chunk(token: descriptor.token, offset: 0, generation: generation).isEmpty, "partial file returned incomplete chunk")
        let remainingFiles = try fileCount(directory)
        expect(cache.stats().count == 0 && remainingFiles == 0, "damaged file remains cached")
    }
}
