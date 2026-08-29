import Foundation
import Mihomo

/// Samples Mihomo's bounded active-connection snapshot while the App may be
/// absent, then writes only compact rows to the shared SQLite store. The sample
/// map is capped well below a Packet Tunnel's memory budget and is never sent
/// across IPC as a history payload.
final class ConnectionHistoryRecorder {
    // Keep the NE-side JSON and SQLite batch bounded. The App can still page
    // the complete on-disk history; this only limits transient active data.
    private static let pollInterval: TimeInterval = 3
    private static let snapshotLimit = 256
    private static let closedBatchLimit = 512
    private static let storeRetryIntervals: [TimeInterval] = [5, 10, 20, 40, 60]

    private let queue = DispatchQueue(label: "com.cora.tunnel.connection-history",
                                      qos: .utility)
    private var store: ConnectionHistoryStore?
    private var timer: DispatchSourceTimer?
    private var storeRetryWorkItem: DispatchWorkItem?
    private var closedCursor: Int64 = 0
    private var isStopped = true
    private var didLogStoreFailure = false
    private var storeRetryAttempt = 0
    private var sessionGeneration: UInt64 = 0

    func start() {
        queue.async { [weak self] in
            guard let self, self.isStopped else { return }
            self.isStopped = false
            self.sessionGeneration &+= 1
            let generation = self.sessionGeneration
            // Mihomo's close queue cursor belongs to the current core process.
            // A restarted core begins again at zero.
            self.closedCursor = 0
            self.openStoreAndStartTimerLocked(generation: generation)
        }
    }

    func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            sessionGeneration &+= 1
            storeRetryWorkItem?.cancel()
            storeRetryWorkItem = nil
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            // The extension owns the definitive session boundary. Clear here
            // as well as in the App so a Control Center disconnect while the
            // App is terminated cannot leak totals into the next VPN session.
            store?.clearAll(compact: false)
            store = nil
            didLogStoreFailure = false
            storeRetryAttempt = 0
        }
    }

    private func openStoreAndStartTimerLocked(generation: UInt64) {
        guard !isStopped, generation == sessionGeneration, timer == nil else { return }
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
        sampleLocked()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pollInterval,
                       repeating: Self.pollInterval,
                       leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.sampleLocked() }
        self.timer = timer
        timer.resume()
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
        storeRetryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + interval,
                         execute: workItem)
    }

    private func sampleLocked() {
        guard let store else { return }
        autoreleasepool {
            let payload = Data(MihomoConnectionsSnapshot(Self.snapshotLimit).utf8)
            if let snapshot = ConnectionHistoryRecord.coreSnapshot(from: payload) {
                store.upsertActive(snapshot.records)
                // The IPC snapshot is normally complete. When it is capped, a
                // missing ID might still be live, so rely on Mihomo's bounded
                // close queue instead of falsely ending it.
                if !snapshot.isTruncated {
                    store.finishActive(except: Set(snapshot.records.map { $0.id }))
                }
            }

            let closedPayload = Data(MihomoClosedConnectionsSnapshot(
                closedCursor, Self.closedBatchLimit).utf8)
            if let root = try? JSONSerialization.jsonObject(with: closedPayload) as? [String: Any] {
                closedCursor = (root["cursor"] as? NSNumber)?.int64Value ?? closedCursor
                if (root["dropped"] as? Bool) == true {
                    FileLog.write("连接历史关闭队列溢出：极高短连接负载下可能漏记少量详情，VPN 转发未受影响")
                }
                if let closed = ConnectionHistoryRecord.records(fromCoreSnapshot: closedPayload) {
                    // The close queue contains final tracker counters, so update
                    // the row before marking it inactive.
                    store.upsertActive(closed)
                    store.finish(ids: Set(closed.map { $0.id }))
                }
            }
        }
    }
}
