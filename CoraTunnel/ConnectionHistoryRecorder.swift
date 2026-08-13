import Foundation

/// Samples Mihomo's bounded active-connection snapshot while the App may be
/// absent, then writes only compact rows to the shared SQLite store. The sample
/// map is capped well below a Packet Tunnel's memory budget and is never sent
/// across IPC as a history payload.
final class ConnectionHistoryRecorder {
    private static let pollInterval: TimeInterval = 2
    private static let snapshotLimit = 500
    private static let closedBatchLimit = 512

    private let store: ConnectionHistoryStore?
    private let queue = DispatchQueue(label: "com.cora.tunnel.connection-history",
                                      qos: .utility)
    private var timer: DispatchSourceTimer?
    private var closedCursor: Int64 = 0
    private var isStopped = false

    init() {
        store = ConnectionHistoryStore.openShared()
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil, self.store != nil else { return }
            self.isStopped = false
            // Mihomo's close queue cursor belongs to the current core process.
            // A restarted core begins again at zero.
            self.closedCursor = 0
            // A prior extension instance can be killed without stopTunnel. Mark
            // any stale active rows as finished before this instance begins.
            self.store?.finishAllActive()
            self.sampleLocked()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + Self.pollInterval,
                           repeating: Self.pollInterval,
                           leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.sampleLocked() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            sampleLocked()
            store?.finishAllActive()
        }
    }

    private func sampleLocked() {
        guard let store else { return }
        let payload = Data(MihomoConnectionsSnapshot(Self.snapshotLimit).utf8)
        if let snapshot = ConnectionHistoryRecord.coreSnapshot(from: payload) {
            store.upsertActive(snapshot.records)
            // The IPC snapshot is normally complete. When it is capped, a
            // missing ID might still be live, so rely on Mihomo's bounded
            // close queue instead of falsely ending it.
            if !snapshot.isTruncated {
                store.finishActive(except: Set(snapshot.records.map(\.id)))
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
                store.finish(ids: Set(closed.map(\.id)))
            }
        }

    }
}
