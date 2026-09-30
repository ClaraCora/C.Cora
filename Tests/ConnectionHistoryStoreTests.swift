import Foundation
import SQLite3

// This executable exercises the production store without an App Group or UI.
enum AppGroup {
    static var containerURL: URL? { nil }
}

private enum TestFailure: Error {
    case failed(String)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

@main
struct ConnectionHistoryStoreTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cora-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite")
        let appStore = try ConnectionHistoryStore(databaseURL: databaseURL, performMigrations: true)
        let neStore = try ConnectionHistoryStore(databaseURL: databaseURL, performMigrations: false)

        let first = record("a", upload: 10, download: 100)
        let second = record("b", upload: 20, download: 200)
        try expect(neStore.upsertActive([first, second]), "active batch failed")
        try expect(appStore.countSummary().activeCount == 2, "active rows missing")

        let closedAt = Date()
        let closed = [record("a", upload: 30, download: 300), record("c", upload: 40, download: 400)]
        try expect(neStore.upsertClosed(closed, at: closedAt), "closed batch failed")
        try verifyTotals(appStore, count: 3, active: 1, upload: 90, download: 900)
        for row in appStore.fetchPage(offset: 0, query: ConnectionHistoryQuery(isActive: false)) {
            try expect(row.endedAt.map { abs($0.timeIntervalSince(closedAt)) < 0.000_001 } ?? false,
                       "closed state/time not written with counters")
        }
        let ranking = appStore.nodeTrafficRankings()
        try expect(ranking.total.map(\.name) == ["节点c", "节点a", "节点b"], "node ranking changed")
        let summary = appStore.summary()
        try expect(summary.strategyVolumes.first?.total == 990, "strategy total changed")
        try expect(summary.hostVolumes.map(\.total) == [440, 330, 220], "host ranking changed")
        try expect(neStore.nodeTrafficRankings().total.isEmpty, "ranking ran inside NE")
        try expect(neStore.summary().recordCount == 0, "aggregate query ran inside NE")

        // Re-reading an unacknowledged close batch must update counters,
        // rather than adding them for a second time.
        try expect(neStore.upsertClosed(closed, at: closedAt), "closed retry failed")
        try verifyTotals(appStore, count: 3, active: 1, upload: 90, download: 900)

        // Force a failure after the first row was stepped. The whole batch
        // must roll back and report failure so the recorder can retry its cursor.
        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK else {
            throw TestFailure.failed("test SQLite handle failed")
        }
        defer { sqlite3_close(handle) }
        let trigger = """
            CREATE TRIGGER fail_history BEFORE INSERT ON connection_history
            WHEN NEW.id = 'fail' BEGIN SELECT RAISE(ABORT, 'injected failure'); END
            """
        try expect(sqlite3_exec(handle, trigger, nil, nil, nil) == SQLITE_OK, "test trigger failed")
        let retryBatch = [record("a", upload: 99, download: 999), record("fail", upload: 1, download: 2)]
        try expect(!neStore.upsertClosed(retryBatch), "failed transaction reported success")
        try verifyTotals(appStore, count: 3, active: 1, upload: 90, download: 900)
        try expect(sqlite3_exec(handle, "DROP TRIGGER fail_history", nil, nil, nil) == SQLITE_OK,
                   "test trigger cleanup failed")
        try expect(neStore.upsertClosed(retryBatch), "transaction retry failed")
        try verifyTotals(appStore, count: 4, active: 1, upload: 160, download: 1601)

        // Exercise the full batch and statement reset/clear path, including
        // empty optional fields and live/final state on a later batch.
        let batch = (0..<512).map { record("batch-\($0)", upload: Int64($0), download: 0) }
        try expect(neStore.upsertActive(batch), "512-row active batch failed")
        try expect(neStore.upsertClosed(batch), "512-row closed batch failed")
        try verifyTotals(appStore, count: 516, active: 1, upload: 130_976, download: 1601)
        try expect(neStore.upsertClosed([]), "empty close batch should be acknowledged")
        print("Connection history: batch writes, rollback/retry, rankings and NE query guards passed")
    }

    private static func verifyTotals(_ store: ConnectionHistoryStore, count: Int, active: Int,
                                     upload: Int64, download: Int64) throws {
        let totals = store.countSummary()
        try expect(totals.recordCount == count && totals.activeCount == active,
                   "record/active counts changed")
        try expect(totals.uploadTotal == upload && totals.downloadTotal == download,
                   "traffic totals changed")
    }

    private static func record(_ id: String, upload: Int64, download: Int64) -> ConnectionHistoryRecord {
        ConnectionHistoryRecord(
            id: id, startedAt: Date().addingTimeInterval(-10), endedAt: nil, isActive: true,
            upload: upload, download: download, network: "tcp", connectionType: "Tun",
            sourceIP: "192.0.2.1", sourcePort: "54321", destinationIP: "2001:db8::1",
            destinationPort: "443", host: "\(id).example.org", sniffHost: "",
            process: "", processPath: "", chains: ["节点\(id)", "策略"], rule: "DomainSuffix",
            rulePayload: "example.org")
    }
}
