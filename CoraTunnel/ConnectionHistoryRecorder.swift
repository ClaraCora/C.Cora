import Foundation
import Mihomo

/// Samples Mihomo's bounded active-connection snapshot while the App may be
/// absent, then writes only compact rows to the shared SQLite store. The sample
/// map is capped well below a Packet Tunnel's memory budget and is never sent
/// across IPC as a history payload.
final class ConnectionHistoryRecorder {
    struct Stats {
        var sampleBytes = 0
        var closedBytes = 0
        var closedRows = 0
        var writeDurationMs: Double = 0
        var writeFailures = 0
        var storeRetries = 0
    }
    private let statsLock = NSLock()
    private var diagnosticStats = Stats()

    func stats() -> Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return diagnosticStats
    }

    private func updateStats(_ operation: (inout Stats) -> Void) {
        statsLock.lock()
        operation(&diagnosticStats)
        statsLock.unlock()
    }

    // Keep the NE-side JSON and SQLite batch bounded. Activity is sampled less
    // often than the close queue because active rows change continuously while
    // closed rows need prompt final counters for the record screen.
    private static let snapshotInterval: TimeInterval = 8
    private static let closedQueueInterval: TimeInterval = 2
    private static let maintenanceInterval: TimeInterval = 60
    private static let snapshotLimit = 256
    private static let closedBatchLimit = 512
    private static let storeRetryIntervals: [TimeInterval] = [5, 10, 20, 40, 60]

    private let queue = DispatchQueue(label: "com.cora.tunnel.connection-history",
                                      qos: .utility)
    private var store: ConnectionHistoryStore?
    private var snapshotTimer: DispatchSourceTimer?
    private var closedQueueTimer: DispatchSourceTimer?
    private var storeRetryWorkItem: DispatchWorkItem?
    private var closedCursor: Int64 = 0
    private var isStopped = true
    private var didLogStoreFailure = false
    private var storeRetryAttempt = 0
    private var sessionGeneration: UInt64 = 0
    private var lastMaintenanceDate = Date.distantPast

    func start() {
        queue.sync {
            guard isStopped else { return }
            self.updateStats { $0 = Stats() }
            isStopped = false
            sessionGeneration &+= 1
            let generation = sessionGeneration
            // Mihomo's close queue cursor belongs to the current core process.
            // A restarted core begins again at zero.
            closedCursor = 0
            openStoreAndStartTimerLocked(generation: generation)
        }
    }

    func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            sessionGeneration &+= 1
            storeRetryWorkItem?.cancel()
            storeRetryWorkItem = nil
            snapshotTimer?.setEventHandler {}
            snapshotTimer?.cancel()
            snapshotTimer = nil
            closedQueueTimer?.setEventHandler {}
            closedQueueTimer?.cancel()
            closedQueueTimer = nil
            // The extension owns the definitive session boundary. Clear here
            // as well as in the App so a Control Center disconnect while the
            // App is terminated cannot leak totals into the next VPN session.
            store?.clearAll(compact: false)
            store = nil
            didLogStoreFailure = false
            storeRetryAttempt = 0
            lastMaintenanceDate = .distantPast
        }
    }

    private func openStoreAndStartTimerLocked(generation: UInt64) {
        guard !isStopped, generation == sessionGeneration,
              snapshotTimer == nil, closedQueueTimer == nil else { return }
        // Never run schema migration inside the memory-constrained NE. The
        // main App owns upgrades; this recorder retries once the schema is ready.
        store = store ?? ConnectionHistoryStore.openShared(performMigrations: false)
        guard let store else {
            if !didLogStoreFailure {
                FileLog.write("连接历史数据库暂时不可用，将在后台重试；VPN 转发不受影响")
                didLogStoreFailure = true
            }
            scheduleStoreRetryLocked(generation: generation)
            return
        }

        if didLogStoreFailure {
            FileLog.write("连接历史数据库已恢复")
            didLogStoreFailure = false
        }
        storeRetryAttempt = 0
        // A prior extension instance can be killed without stopTunnel. Mark
        // any stale active rows as finished before this instance begins.
        store.finishAllActive()
        sampleActiveLocked()
        drainClosedQueueLocked()
        lastMaintenanceDate = Date()

        let snapshotTimer = DispatchSource.makeTimerSource(queue: queue)
        snapshotTimer.schedule(deadline: .now() + Self.snapshotInterval,
                               repeating: Self.snapshotInterval,
                               leeway: .milliseconds(250))
        snapshotTimer.setEventHandler { [weak self] in self?.sampleActiveLocked() }
        self.snapshotTimer = snapshotTimer
        snapshotTimer.resume()

        let closedQueueTimer = DispatchSource.makeTimerSource(queue: queue)
        closedQueueTimer.schedule(deadline: .now() + Self.closedQueueInterval,
                                  repeating: Self.closedQueueInterval,
                                  leeway: .milliseconds(100))
        closedQueueTimer.setEventHandler { [weak self] in self?.drainClosedQueueLocked() }
        self.closedQueueTimer = closedQueueTimer
        closedQueueTimer.resume()
    }

    private func scheduleStoreRetryLocked(generation: UInt64) {
        guard !isStopped, generation == sessionGeneration,
              storeRetryWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped,
                  generation == self.sessionGeneration else { return }
            self.storeRetryWorkItem = nil
            self.openStoreAndStartTimerLocked(generation: generation)
        }
        let interval = Self.storeRetryIntervals[
            min(storeRetryAttempt, Self.storeRetryIntervals.count - 1)]
        storeRetryAttempt += 1
        updateStats { $0.storeRetries += 1 }
        storeRetryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + interval,
                         execute: workItem)
    }

    private func sampleActiveLocked() {
        guard let store else { return }
        autoreleasepool {
            if let payload = MihomoConnectionHistorySnapshot(Self.snapshotLimit),
               let snapshot = ConnectionHistoryRecord.coreSnapshot(from: payload) {
                let started = ProcessInfo.processInfo.systemUptime
                let committed = store.upsertActive(snapshot.records)
                updateStats {
                    $0.sampleBytes = payload.count
                    $0.writeDurationMs = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                    if !committed { $0.writeFailures += 1 }
                }
                if committed, !snapshot.isTruncated {
                    store.finishActive(except: snapshot.records.map { $0.id })
                }
            }
            runMaintenanceIfNeededLocked(store: store)
        }
    }

    private func drainClosedQueueLocked() {
        guard let store else { return }
        autoreleasepool {
            if let payload = MihomoClosedConnectionHistorySnapshot(closedCursor, Self.closedBatchLimit),
               let snapshot = ConnectionHistoryRecord.coreSnapshot(from: payload) {
                let started = ProcessInfo.processInfo.systemUptime
                let committed = store.upsertClosed(snapshot.records)
                updateStats {
                    $0.closedBytes = payload.count
                    $0.closedRows = snapshot.records.count
                    $0.writeDurationMs = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                    if !committed { $0.writeFailures += 1 }
                }
                // Acknowledge only a committed batch; failed writes retry the same cursor.
                if committed {
                    closedCursor = snapshot.cursor ?? closedCursor
                    if snapshot.dropped {
                        FileLog.write("连接历史关闭队列溢出：极高短连接负载下可能漏记少量详情，VPN 转发未受影响")
                    }
                }
            }
            runMaintenanceIfNeededLocked(store: store)
        }
    }

    private func runMaintenanceIfNeededLocked(store: ConnectionHistoryStore) {
        let now = Date()
        guard now.timeIntervalSince(lastMaintenanceDate) >= Self.maintenanceInterval else {
            return
        }
        lastMaintenanceDate = now
        store.maintenance(now: now)
    }
}
