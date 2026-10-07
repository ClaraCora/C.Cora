import Foundation

/// Control work only; packet forwarding never enters this scheduler. Pending
/// jobs are values, not threads blocked on semaphores. Reset drops them at once.
final class IPCControlScheduler: @unchecked Sendable {
    enum WorkClass: String, CaseIterable {
        case light, snapshot, heavy, script
        var limit: Int {
            switch self {
            case .light: return 4
            case .script: return 8
            case .snapshot: return 3
            case .heavy: return 2
            }
        }
    }
    struct Stats {
        let inFlight: Int
        let peakInFlight: Int
        let rejected: Int
        let cancelled: Int
        let timedOut: Int
        let queueDepth: Int
        let peakQueueDepth: Int
        let completedByClass: [String: Int]
        let durationMsByClass: [String: Double]
    }
    private struct Job {
        let workClass: WorkClass
        let key: String?
        let scriptID: String?
        let epoch: UInt64
        let queuedAt: TimeInterval
        let operation: () -> Void
        let onCancel: () -> Void
        let onTimeout: () -> Void
    }
    private static let maximumPending = 24
    private static let maximumInFlight = 8
    private let workers = DispatchQueue(label: "com.cora.tunnel.ipc-workers",
                                       qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var pending: [Job] = []
    private var inFlight = 0
    private var classCounts: [WorkClass: Int] = [:]
    private var scriptCounts: [String: Int] = [:]
    private var activeKeys: Set<String> = []
    private var epoch: UInt64 = 0
    private var peakInFlight = 0
    private var peakQueueDepth = 0
    private var rejected = 0
    private var cancelled = 0
    private var timedOut = 0
    private var completedByClass: [String: Int] = [:]
    private var durationMsByClass: [String: Double] = [:]
    private var expirationTimer: DispatchSourceTimer?
    private let maximumQueueWait: TimeInterval

    init(maximumQueueWait: TimeInterval = 30) {
        self.maximumQueueWait = maximumQueueWait
    }
    @discardableResult
    func submit(_ workClass: WorkClass, key: String? = nil, scriptID: String? = nil,
                operation: @escaping () -> Void, onReject: @escaping () -> Void,
                onCancel: @escaping () -> Void = {}, onTimeout: @escaping () -> Void = {}) -> Bool {
        lock.lock()
        let job = Job(workClass: workClass, key: key, scriptID: scriptID, epoch: epoch,
                      queuedAt: ProcessInfo.processInfo.systemUptime,
                      operation: operation, onCancel: onCancel, onTimeout: onTimeout)
        // Single-flight keys must win over capacity: a Provider refresh that
        // conflicts with an active/all-provider refresh is rejected even when
        // another worker slot is currently free.
        let conflicts = key.map { hasConflictLocked($0) } ?? false
        guard !conflicts,
              (pending.count < Self.maximumPending || canStartLocked(job)) else {
            rejected += 1
            lock.unlock()
            onReject()
            return false
        }
        if let key { activeKeys.insert(key) }
        pending.append(job)
        drainLocked()
        peakQueueDepth = max(peakQueueDepth, pending.count)
        lock.unlock()
        return true
    }
    func cancelPending() {
        lock.lock()
        epoch &+= 1
        let removed = pending
        pending.removeAll(keepingCapacity: false)
        cancelled += removed.count
        expirationTimer?.setEventHandler {}
        expirationTimer?.cancel()
        expirationTimer = nil
        for job in removed { if let key = job.key { activeKeys.remove(key) } }
        lock.unlock()
        for job in removed { job.onCancel() }
    }
    func stats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return Stats(inFlight: inFlight, peakInFlight: peakInFlight, rejected: rejected,
                     cancelled: cancelled, timedOut: timedOut, queueDepth: pending.count,
                     peakQueueDepth: peakQueueDepth, completedByClass: completedByClass,
                     durationMsByClass: durationMsByClass)
    }
    private func canStartLocked(_ job: Job) -> Bool {
        inFlight < Self.maximumInFlight && classCounts[job.workClass, default: 0] < job.workClass.limit
            && (job.scriptID.map { scriptCounts[$0, default: 0] < 4 } ?? true)
    }
    private func drainLocked() {
        // Skip saturated classes so they cannot starve unrelated small queries.
        while let index = pending.firstIndex(where: { canStartLocked($0) }) {
            let job = pending.remove(at: index)
            inFlight += 1
            classCounts[job.workClass, default: 0] += 1
            if let scriptID = job.scriptID { scriptCounts[scriptID, default: 0] += 1 }
            peakInFlight = max(peakInFlight, inFlight)
            workers.async { [self] in
                let startedAt = ProcessInfo.processInfo.systemUptime
                lock.lock()
                let stale = job.epoch != epoch
                let expired = startedAt - job.queuedAt > maximumQueueWait
                if stale { cancelled += 1 }
                else if expired { timedOut += 1 }
                lock.unlock()
                if stale { job.onCancel() }
                else if expired { job.onTimeout() }
                else { autoreleasepool { job.operation() } }
                finish(job, elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
                       wasExecuted: !stale && !expired)
            }
        }
        scheduleExpirationLocked()
    }
    private func scheduleExpirationLocked() {
        guard let first = pending.first else {
            expirationTimer?.setEventHandler {}
            expirationTimer?.cancel()
            expirationTimer = nil
            return
        }
        if expirationTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: workers)
            timer.setEventHandler { [weak self] in self?.expirePending() }
            expirationTimer = timer
            timer.resume()
        }
        let delay = max(0.001, first.queuedAt + maximumQueueWait - ProcessInfo.processInfo.systemUptime)
        expirationTimer?.schedule(deadline: .now() + delay)
    }
    private func expirePending() {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let expired = pending.filter { now - $0.queuedAt >= maximumQueueWait }
        pending.removeAll { now - $0.queuedAt >= maximumQueueWait }
        timedOut += expired.count
        for job in expired { if let key = job.key { activeKeys.remove(key) } }
        scheduleExpirationLocked()
        lock.unlock()
        for job in expired { job.onTimeout() }
    }
    private func finish(_ job: Job, elapsed: TimeInterval, wasExecuted: Bool) {
        lock.lock()
        // Running operations unwind through the Go cancellation token. Count
        // their session cancellation here, once, after their slot is released.
        if wasExecuted && job.epoch != epoch { cancelled += 1 }
        inFlight -= 1
        classCounts[job.workClass, default: 0] -= 1
        if let scriptID = job.scriptID {
            let remaining = scriptCounts[scriptID, default: 0] - 1
            if remaining == 0 { scriptCounts.removeValue(forKey: scriptID) }
            else { scriptCounts[scriptID] = remaining }
        }
        if let key = job.key { activeKeys.remove(key) }
        if wasExecuted {
            completedByClass[job.workClass.rawValue, default: 0] += 1
            durationMsByClass[job.workClass.rawValue, default: 0] += elapsed * 1_000
        }
        drainLocked()
        lock.unlock()
    }
    private func hasConflictLocked(_ key: String) -> Bool {
        if activeKeys.contains(key) { return true }
        // The final separator identifies the session even if a name contains '#'.
        func parts(_ value: String) -> (String, String) {
            guard let separator = value.lastIndex(of: "#") else { return (value, "") }
            return (String(value[..<separator]), String(value[value.index(after: separator)...]))
        }
        let (name, generation) = parts(key)
        for family in ["proxyProviders:", "ruleProviders:"] where name.hasPrefix(family) {
            return activeKeys.contains {
                let (otherName, otherGeneration) = parts($0)
                return otherGeneration == generation && otherName.hasPrefix(family)
                    && (name == family + "all" || otherName == family + "all")
            }
        }
        return false
    }
}
