import Foundation
import SQLite3

/// A compact, cross-process representation of one Mihomo connection.  It is
/// deliberately independent from the App UI models so the packet tunnel can
/// persist it without loading SwiftUI or retaining a REST-sized snapshot.
struct ConnectionHistoryRecord: Identifiable, Sendable {
    static let maximumStringLength = 512

    let id: String
    let startedAt: Date
    let endedAt: Date?
    let isActive: Bool
    let upload: Int64
    let download: Int64
    let network: String
    let connectionType: String
    let sourceIP: String
    let sourcePort: String
    let destinationIP: String
    let destinationPort: String
    let host: String
    let sniffHost: String
    let process: String
    let processPath: String
    let chains: [String]
    let rule: String
    let rulePayload: String

    var strategyName: String {
        Self.normalizedStrategyName(chains)
    }

    var hostName: String {
        Self.normalizedHostName(host: host, sniffHost: sniffHost, destinationIP: destinationIP)
    }

    static func normalizedStrategyName(_ chains: [String]) -> String {
        let value = chains.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "DIRECT" : value
    }

    static func normalizedHostName(host: String,
                                   sniffHost: String,
                                   destinationIP: String) -> String {
        let value = [host, sniffHost, destinationIP]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        return value.isEmpty ? "未知" : value
    }

    struct CoreSnapshot: Sendable {
        let records: [ConnectionHistoryRecord]
        let isTruncated: Bool
    }

    static func coreSnapshot(from data: Data,
                             capturedAt: Date = Date()) -> CoreSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawConnections = root["connections"] as? [[String: Any]] else {
            return nil
        }
        return CoreSnapshot(
            records: rawConnections.compactMap {
                ConnectionHistoryRecord(object: $0, capturedAt: capturedAt)
            },
            isTruncated: (root["truncated"] as? Bool) ?? false)
    }

    static func records(fromCoreSnapshot data: Data,
                        capturedAt: Date = Date()) -> [ConnectionHistoryRecord]? {
        coreSnapshot(from: data, capturedAt: capturedAt)?.records
    }

    init?(object: [String: Any], capturedAt: Date) {
        let identifier = Self.string(object["id"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return nil }

        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let chainValues = object["chains"] as? [Any] ?? []
        let start = Self.string(object["start"])

        id = identifier
        startedAt = Self.parseDate(start) ?? capturedAt
        endedAt = nil
        isActive = true
        upload = max(0, Self.int64(object["upload"]))
        download = max(0, Self.int64(object["download"]))
        network = Self.limit(Self.string(metadata["network"]), to: 24)
        connectionType = Self.limit(Self.string(metadata["type"]), to: 48)
        sourceIP = Self.limit(Self.string(metadata["sourceIP"]), to: 64)
        sourcePort = Self.limit(Self.string(metadata["sourcePort"]), to: 16)
        destinationIP = Self.limit(Self.string(metadata["destinationIP"]), to: 64)
        destinationPort = Self.limit(Self.string(metadata["destinationPort"]), to: 16)
        host = Self.limit(Self.string(metadata["host"]), to: Self.maximumStringLength)
        sniffHost = Self.limit(Self.string(metadata["sniffHost"]), to: Self.maximumStringLength)
        process = Self.limit(Self.string(metadata["process"]), to: 256)
        processPath = Self.limit(Self.string(metadata["processPath"]), to: Self.maximumStringLength)
        chains = chainValues.map { Self.limit(Self.string($0), to: 256) }
            .filter { !$0.isEmpty }
            .prefix(12)
            .map { $0 }
        rule = Self.limit(Self.string(object["rule"]), to: 96)
        rulePayload = Self.limit(Self.string(object["rulePayload"]), to: Self.maximumStringLength)
    }

    init(id: String,
         startedAt: Date,
         endedAt: Date?,
         isActive: Bool,
         upload: Int64,
         download: Int64,
         network: String,
         connectionType: String,
         sourceIP: String,
         sourcePort: String,
         destinationIP: String,
         destinationPort: String,
         host: String,
         sniffHost: String,
         process: String,
         processPath: String,
         chains: [String],
         rule: String,
         rulePayload: String) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isActive = isActive
        self.upload = upload
        self.download = download
        self.network = network
        self.connectionType = connectionType
        self.sourceIP = sourceIP
        self.sourcePort = sourcePort
        self.destinationIP = destinationIP
        self.destinationPort = destinationPort
        self.host = host
        self.sniffHost = sniffHost
        self.process = process
        self.processPath = processPath
        self.chains = chains
        self.rule = rule
        self.rulePayload = rulePayload
    }

    private static func string(_ value: Any?) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return ""
        }
    }

    private static func int64(_ value: Any?) -> Int64 {
        switch value {
        case let number as NSNumber: return number.int64Value
        case let string as String: return Int64(string) ?? 0
        default: return 0
        }
    }

    private static func limit(_ value: String, to maximum: Int) -> String {
        String(value.prefix(maximum))
    }

    private static func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(value)
    }
}

/// A bounded database-side filter used by record detail pages.
/// Keeping the filter here lets both the App and the Network Extension share
/// the same column names without transferring the complete history into RAM.
struct ConnectionHistoryQuery: Equatable, Hashable, Sendable {
    let strategyName: String?
    let hostName: String?
    let network: String?
    let isActive: Bool?
    let searchText: String?

    init(strategyName: String? = nil,
         hostName: String? = nil,
         network: String? = nil,
         isActive: Bool? = nil,
         searchText: String? = nil) {
        let strategy = strategyName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = hostName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNetwork = network?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSearch = searchText?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.strategyName = strategy?.isEmpty == true ? nil : strategy
        self.hostName = host?.isEmpty == true ? nil : host
        self.network = normalizedNetwork?.isEmpty == true ? nil : normalizedNetwork
        self.isActive = isActive
        self.searchText = normalizedSearch?.isEmpty == true ? nil : normalizedSearch
    }

    static let all = ConnectionHistoryQuery()

    fileprivate var sqlPredicate: (clause: String, values: [String]) {
        var clauses: [String] = []
        var values: [String] = []
        if let strategyName {
            clauses.append("strategy_name = ?")
            values.append(strategyName)
        }
        if let hostName {
            clauses.append("host_name = ?")
            values.append(hostName)
        }
        if let network {
            clauses.append("LOWER(network) = ?")
            values.append(network)
        }
        if let isActive {
            clauses.append("is_active = \(isActive ? 1 : 0)")
        }
        if let searchText {
            clauses.append("(LOWER(host) LIKE ? OR LOWER(sniff_host) LIKE ? "
                           + "OR LOWER(destination_ip) LIKE ? OR LOWER(source_ip) LIKE ? "
                           + "OR LOWER(process) LIKE ? OR LOWER(process_path) LIKE ? "
                           + "OR LOWER(strategy_name) LIKE ? OR LOWER(host_name) LIKE ? "
                           + "OR LOWER(rule) LIKE ? OR LOWER(rule_payload) LIKE ?)")
            let pattern = "%\(searchText)%"
            values.append(contentsOf: Array(repeating: pattern, count: 10))
        }
        return (clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "), values)
    }
}

struct ConnectionHistoryTrafficVolume: Sendable {
    let name: String
    let upload: Int64
    let download: Int64

    var total: Int64 { upload + download }
}

struct ConnectionHistorySummary: Sendable {
    let recordCount: Int
    let activeCount: Int
    let uploadTotal: Int64
    let downloadTotal: Int64
    let strategyVolumes: [ConnectionHistoryTrafficVolume]
    let hostVolumes: [ConnectionHistoryTrafficVolume]

    static let empty = ConnectionHistorySummary(recordCount: 0,
                                                activeCount: 0,
                                                uploadTotal: 0,
                                                downloadTotal: 0,
                                                strategyVolumes: [],
                                                hostVolumes: [])
}

/// Shared, bounded connection history. Both the App and Network Extension use
/// their own SQLite handle; WAL plus a short busy timeout makes those writers
/// cooperate without putting a database-sized cache in either process.
final class ConnectionHistoryStore: @unchecked Sendable {
    static let retentionDays = 7
    static let maximumRecordCount = 20_000
    static let maximumDatabaseBytes: Int64 = 50 * 1_024 * 1_024

    // Leave 8 MiB for the WAL and SQLite metadata while enforcing the
    // user-visible 50 MB limit. A history sample is at most 500 rows, so this
    // headroom also covers one complete write transaction before checkpointing.
    private static let maximumDatabasePages: Int64 = 10_752
    // Schema upgrades can need temporary pages for a rebuilt table or index.
    // Remove that temporary growth allowance after migration and compaction.
    private static let migrationDatabasePages: Int64 = maximumDatabasePages + 16_384
    private static let migrationBusyTimeoutMilliseconds = 5_000
    private static let runtimeBusyTimeoutMilliseconds = 1_200
    private static let currentSchemaVersion: Int64 = 2
    private static let defaultPageSize = 100
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let databaseURL: URL
    private var database: OpaquePointer?
    private let queue = DispatchQueue(label: "com.cora.connection-history.sqlite",
                                      qos: .utility)

    static var defaultFetchPageSize: Int { Int(defaultPageSize) }

    static func openShared(performMigrations: Bool = true) -> ConnectionHistoryStore? {
        guard let container = AppGroup.containerURL else { return nil }
        guard let store = try? ConnectionHistoryStore(
            databaseURL: container.appendingPathComponent("connection-history.sqlite"),
            performMigrations: performMigrations) else { return nil }
        return store
    }

    init(databaseURL: URL, performMigrations: Bool) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard openResult == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw StoreError.openFailed
        }
        database = handle
        do {
            let migrated = try configure(performMigrations: performMigrations)
            try trimLocked(now: Date())
            if migrated {
                try restoreDatabasePageLimitLocked()
            } else {
                try applySteadyStatePageLimitLocked()
            }
            // The Network Extension opens the store with migrations disabled.
            // Keep SQLite temporary work on disk there so an aggregate or
            // checkpoint cannot consume the same small memory budget as the
            // packet tunnel. The App can use a modest in-memory temp cache.
            let temporaryStore = performMigrations ? "MEMORY" : "FILE"
            let cacheSize = performMigrations ? -2048 : -512
            try execute("PRAGMA temp_store = \(temporaryStore)")
            try execute("PRAGMA cache_size = \(cacheSize)")
            try execute("PRAGMA busy_timeout = \(Self.runtimeBusyTimeoutMilliseconds)")
        } catch {
            try? execute("PRAGMA max_page_count = \(Self.maximumDatabasePages)")
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    /// Persists the current active sample. Records are upserted in one short
    /// transaction; no full history is ever retained by the Network Extension.
    func upsertActive(_ records: [ConnectionHistoryRecord]) {
        guard !records.isEmpty else { return }
        queue.sync {
            guard database != nil else { return }
            do {
                try execute("BEGIN IMMEDIATE TRANSACTION")
                var recordCount = try totalRecordCountLocked()
                var knownIDs = try existingIDsLocked(for: records)
                for record in records {
                    let exists = knownIDs.contains(record.id)
                    if !exists && recordCount >= Self.maximumRecordCount {
                        // Delete a small finished batch instead of one row at
                        // a time. If every retained row is active, preserve it
                        // and skip this optional history record.
                        let needed = recordCount - Self.maximumRecordCount + 1
                        let removed = try removeOldestCompletedLocked(limit: max(needed, 256))
                        recordCount -= removed
                        guard recordCount < Self.maximumRecordCount else { continue }
                    }
                    try upsertLocked(record)
                    if !exists {
                        knownIDs.insert(record.id)
                        recordCount += 1
                    }
                }
                try execute("COMMIT")
            } catch StoreError.sqlite(let code) where code == SQLITE_FULL {
                try? execute("ROLLBACK")
                // A capped database may still need pages while a WAL reader is
                // present. Free completed records for the next two-second
                // sample, but never block forwarding or evict active rows.
                _ = try? removeOldestCompletedLocked(limit: 1_000)
                try? execute("PRAGMA wal_checkpoint(PASSIVE)")
            } catch {
                try? execute("ROLLBACK")
                // History is observability only. Never make a DB issue affect
                // packet forwarding or tunnel startup.
            }
        }
    }

    func finish(ids: Set<String>, at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        queue.sync {
            guard database != nil else { return }
            do {
                try execute("BEGIN IMMEDIATE TRANSACTION")
                for id in ids {
                    var statement: OpaquePointer?
                    try prepare("UPDATE connection_history SET is_active = 0, ended_at = ? "
                                + "WHERE id = ? AND is_active = 1", into: &statement)
                    defer { sqlite3_finalize(statement) }
                    sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
                    bindText(id, to: statement, index: 2)
                    try stepDone(statement)
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
            }
        }
    }

    /// A complete (non-truncated) core snapshot is authoritative. Finish only
    /// rows no longer reported by that snapshot, avoiding an App-side cache of
    /// all active IDs in the Network Extension.
    func finishActive(except ids: Set<String>, at date: Date = Date()) {
        queue.sync {
            guard database != nil else { return }
            do {
                try execute("BEGIN IMMEDIATE TRANSACTION")
                if ids.isEmpty {
                    try execute("UPDATE connection_history SET is_active = 0, ended_at = "
                                + "\(date.timeIntervalSince1970) WHERE is_active = 1")
                } else {
                    let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
                    let sql = "UPDATE connection_history SET is_active = 0, ended_at = ? "
                        + "WHERE is_active = 1 AND id NOT IN (\(placeholders))"
                    var statement: OpaquePointer?
                    try prepare(sql, into: &statement)
                    defer { sqlite3_finalize(statement) }
                    sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
                    for (index, id) in ids.sorted().enumerated() {
                        bindText(id, to: statement, index: Int32(index + 2))
                    }
                    try stepDone(statement)
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
            }
        }
    }

    /// Called when a new tunnel instance starts or the old one stops. A closed
    /// core cannot emit another sample, so any previous active rows are ended.
    func finishAllActive(at date: Date = Date()) {
        queue.sync {
            do {
                try execute("UPDATE connection_history SET is_active = 0, ended_at = "
                            + "\(date.timeIntervalSince1970) WHERE is_active = 1")
                try trimLocked(now: date)
            } catch { }
        }
    }

    /// Runs retention, page-cap and WAL maintenance outside the hot sampling
    /// path. The caller should invoke this at a coarse interval (for example,
    /// once per minute) so normal connection updates stay short and bounded.
    func maintenance(now: Date = Date()) {
        queue.sync {
            guard database != nil else { return }
            do {
                try trimLocked(now: now)
            } catch {
                // History is observability only. A maintenance failure must
                // never affect tunnel forwarding or the next sample.
            }
        }
    }

    /// Clears all records at a VPN session boundary.
    func clearAll(compact: Bool = true) {
        queue.sync {
            do {
                try execute("BEGIN IMMEDIATE TRANSACTION")
                try execute("DELETE FROM connection_history")
                try execute("COMMIT")
                if compact {
                    try execute("PRAGMA wal_checkpoint(TRUNCATE)")
                    try execute("PRAGMA incremental_vacuum")
                }
            } catch {
                try? execute("ROLLBACK")
            }
        }
    }

    func fetchPage(offset: Int,
                   limit: Int = ConnectionHistoryStore.defaultPageSize,
                   query: ConnectionHistoryQuery = .all) -> [ConnectionHistoryRecord] {
        queue.sync {
            guard database != nil else { return [] }
            let safeOffset = max(0, offset)
            let safeLimit = min(max(1, limit), 250)
            let predicate = query.sqlPredicate
            let sql = """
                SELECT id, started_at, ended_at, is_active, upload, download, network,
                       connection_type, source_ip, source_port, destination_ip,
                       destination_port, host, sniff_host, process, process_path, chains,
                       rule, rule_payload
                FROM connection_history
                \(predicate.clause)
                ORDER BY is_active DESC,
                         CASE WHEN is_active = 1 THEN started_at
                              ELSE COALESCE(ended_at, started_at) END DESC,
                         id DESC
                LIMIT ? OFFSET ?
                """
            do {
                var statement: OpaquePointer?
                try prepare(sql, into: &statement)
                defer { sqlite3_finalize(statement) }
                for (index, value) in predicate.values.enumerated() {
                    bindText(value, to: statement, index: Int32(index + 1))
                }
                let limitIndex = Int32(predicate.values.count + 1)
                sqlite3_bind_int(statement, limitIndex, Int32(safeLimit))
                sqlite3_bind_int(statement, limitIndex + 1, Int32(safeOffset))
                var result: [ConnectionHistoryRecord] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let record = record(from: statement) { result.append(record) }
                }
                return result
            } catch {
                return []
            }
        }
    }

    func summary(for query: ConnectionHistoryQuery = .all) -> ConnectionHistorySummary {
        queue.sync {
            guard database != nil else { return .empty }
            let predicate = query.sqlPredicate
            let totalsSQL = "SELECT COUNT(*), COALESCE(SUM(is_active), 0), "
                + "COALESCE(SUM(upload), 0), COALESCE(SUM(download), 0) "
                + "FROM connection_history \(predicate.clause)"
            guard let totals = row(for: totalsSQL, bindings: predicate.values) else { return .empty }
            let strategies = aggregateLocked(column: "strategy_name", limit: 64, query: query)
            let hosts = aggregateLocked(column: "host_name", limit: 5, query: query)
            return ConnectionHistorySummary(recordCount: Int(totals.int(0)),
                                            activeCount: Int(totals.int(1)),
                                            uploadTotal: totals.int(2),
                                            downloadTotal: totals.int(3),
                                            strategyVolumes: strategies,
                                            hostVolumes: hosts)
        }
    }

    private func configure(performMigrations: Bool) throws -> Bool {
        try execute("PRAGMA busy_timeout = \(Self.runtimeBusyTimeoutMilliseconds)")
        try execute("PRAGMA page_size = 4096")
        try execute("PRAGMA auto_vacuum = INCREMENTAL")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA wal_autocheckpoint = 128")

        let version = row(for: "PRAGMA user_version")?.int(0) ?? 0
        guard version < Self.currentSchemaVersion else { return false }
        guard performMigrations else { throw StoreError.migrationRequired }

        // Only the one-time schema migration may hold the cross-process writer
        // lock longer than the normal observability write budget. Keep index
        // sorting on disk so migration cannot consume the NE memory allowance.
        try execute("PRAGMA busy_timeout = \(Self.migrationBusyTimeoutMilliseconds)")
        try execute("PRAGMA temp_store = FILE")
        // Existing databases may already sit at the normal hard limit. Give
        // the one-time column/index migration bounded room, then compact and
        // restore the normal limit before exposing this handle to callers.
        try execute("PRAGMA max_page_count = \(Self.migrationDatabasePages)")
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            // Another process may have completed the migration while this
            // handle waited for BEGIN IMMEDIATE. Recheck under the writer lock.
            let lockedVersion = row(for: "PRAGMA user_version")?.int(0) ?? 0
            if lockedVersion >= Self.currentSchemaVersion {
                try execute("COMMIT")
                return true
            }

            try execute("""
                CREATE TABLE IF NOT EXISTS connection_history (
                    id TEXT PRIMARY KEY NOT NULL,
                    started_at REAL NOT NULL,
                    ended_at REAL,
                    is_active INTEGER NOT NULL,
                    upload INTEGER NOT NULL,
                    download INTEGER NOT NULL,
                    network TEXT NOT NULL,
                    connection_type TEXT NOT NULL,
                    source_ip TEXT NOT NULL,
                    source_port TEXT NOT NULL,
                    destination_ip TEXT NOT NULL,
                    destination_port TEXT NOT NULL,
                    host TEXT NOT NULL,
                    sniff_host TEXT NOT NULL,
                    process TEXT NOT NULL,
                    process_path TEXT NOT NULL,
                    chains TEXT NOT NULL,
                    strategy_name TEXT NOT NULL,
                    host_name TEXT NOT NULL,
                    rule TEXT NOT NULL,
                    rule_payload TEXT NOT NULL
                )
                """)

            // Older builds used different fallback labels. Normalize them before
            // the shared App and Network Extension handles resume normal writes.
            try execute("UPDATE connection_history SET strategy_name = 'DIRECT' "
                        + "WHERE strategy_name IS NULL OR strategy_name = ''")
            try execute("UPDATE connection_history SET host_name = '未知' "
                        + "WHERE host_name IS NULL OR host_name = '' "
                        + "OR host_name IN ('Unknown', '未知目标')")

            // Schema v1 persisted a second per-node aggregate and maintained it
            // through triggers for every sampled connection update. That work is
            // intentionally retired to keep the Network Extension lean. Keep the
            // old column in place on existing databases: rebuilding the history
            // table merely to remove it would create a larger migration spike.
            if lockedVersion < 2 {
                try execute("DROP TRIGGER IF EXISTS history_node_traffic_insert")
                try execute("DROP TRIGGER IF EXISTS history_node_traffic_update")
                try execute("DROP TABLE IF EXISTS connection_node_traffic")
                try execute("DROP INDEX IF EXISTS history_proxy_node_index")
            }

            try execute("CREATE INDEX IF NOT EXISTS history_started_index "
                        + "ON connection_history(is_active, started_at DESC)")
            try execute("CREATE INDEX IF NOT EXISTS history_ended_index "
                        + "ON connection_history(ended_at ASC)")
            try execute("CREATE INDEX IF NOT EXISTS history_strategy_index "
                        + "ON connection_history(strategy_name, is_active, started_at DESC)")
            try execute("CREATE INDEX IF NOT EXISTS history_host_index "
                        + "ON connection_history(host_name, is_active, started_at DESC)")
            try execute("PRAGMA user_version = \(Self.currentSchemaVersion)")
            try execute("COMMIT")
            return true
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func upsertLocked(_ record: ConnectionHistoryRecord) throws {
        let sql = """
            INSERT INTO connection_history (
                id, started_at, ended_at, is_active, upload, download, network,
                connection_type, source_ip, source_port, destination_ip,
                destination_port, host, sniff_host, process, process_path, chains,
                strategy_name, host_name, rule, rule_payload
            ) VALUES (?, ?, NULL, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                upload = excluded.upload,
                download = excluded.download,
                is_active = 1,
                ended_at = NULL,
                network = excluded.network,
                connection_type = excluded.connection_type,
                source_ip = excluded.source_ip,
                source_port = excluded.source_port,
                destination_ip = excluded.destination_ip,
                destination_port = excluded.destination_port,
                host = excluded.host,
                sniff_host = excluded.sniff_host,
                process = excluded.process,
                process_path = excluded.process_path,
                chains = excluded.chains,
                strategy_name = excluded.strategy_name,
                host_name = excluded.host_name,
                rule = excluded.rule,
                rule_payload = excluded.rule_payload
            """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        let values: [String] = [
            record.network, record.connectionType, record.sourceIP,
            record.sourcePort, record.destinationIP, record.destinationPort, record.host,
            record.sniffHost, record.process, record.processPath,
            (try? String(data: JSONEncoder().encode(record.chains), encoding: .utf8)) ?? "[]",
            record.strategyName, record.hostName, record.rule, record.rulePayload,
        ]
        bindText(record.id, to: statement, index: 1)
        sqlite3_bind_double(statement, 2, record.startedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, record.upload)
        sqlite3_bind_int64(statement, 4, record.download)
        for (index, value) in values.enumerated() {
            bindText(value, to: statement, index: Int32(index + 5))
        }
        try stepDone(statement)
    }

    private func trimLocked(now: Date) throws {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        try execute("DELETE FROM connection_history WHERE is_active = 0 AND "
                    + "COALESCE(ended_at, started_at) < \(cutoff.timeIntervalSince1970)")
        try removeCompletedRecordsPastLimitLocked()

        // Trigger a small checkpoint so the shared WAL is normally under 512 KB.
        try? execute("PRAGMA wal_checkpoint(PASSIVE)")
        while currentDatabaseBytesLocked() > Self.maximumDatabaseBytes {
            guard try removeOldestCompletedLocked(limit: 1_000) > 0 else { break }
            try? execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try? execute("PRAGMA incremental_vacuum(256)")
        }
    }

    private func restoreDatabasePageLimitLocked() throws {
        try? execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try? execute("PRAGMA incremental_vacuum(2048)")

        // A schema migration can temporarily grow the main database beyond
        // its steady-state page cap. Remove only oldest completed details;
        // active connections are never sacrificed.
        var attempts = 0
        var pageCount = row(for: "PRAGMA page_count")?.int(0) ?? 0
        while pageCount > Self.maximumDatabasePages, attempts < 20 {
            guard try removeOldestCompletedLocked(limit: 1_000) > 0 else { break }
            try? execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try? execute("PRAGMA incremental_vacuum(2048)")
            pageCount = row(for: "PRAGMA page_count")?.int(0) ?? pageCount
            attempts += 1
        }
        try applySteadyStatePageLimitLocked(fallbackPageCount: pageCount)
    }

    private func applySteadyStatePageLimitLocked(fallbackPageCount: Int64 = 0) throws {
        let currentPages = row(for: "PRAGMA page_count")?.int(0) ?? fallbackPageCount
        let finalLimit = max(Self.maximumDatabasePages, currentPages)
        try execute("PRAGMA max_page_count = \(finalLimit)")
        guard row(for: "PRAGMA max_page_count")?.int(0) == finalLimit else {
            throw StoreError.openFailed
        }
    }

    private func removeCompletedRecordsPastLimitLocked() throws {
        let activeCount = row(for: "SELECT COUNT(*) FROM connection_history WHERE is_active = 1")?.int(0) ?? 0
        let completedCount = row(for: "SELECT COUNT(*) FROM connection_history WHERE is_active = 0")?.int(0) ?? 0
        let completedLimit = max(0, Self.maximumRecordCount - Int(activeCount))
        let excess = max(0, Int(completedCount) - completedLimit)
        if excess > 0 { _ = try removeOldestCompletedLocked(limit: excess) }
    }

    private func totalRecordCountLocked() throws -> Int {
        guard let value = row(for: "SELECT COUNT(*) FROM connection_history") else {
            throw StoreError.openFailed
        }
        return Int(value.int(0))
    }

    private func existingIDsLocked(for records: [ConnectionHistoryRecord]) throws -> Set<String> {
        let ids = Array(Set(records.map(\.id)))
        guard !ids.isEmpty else { return [] }
        var statement: OpaquePointer?
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        try prepare("SELECT id FROM connection_history WHERE id IN (\(placeholders))", into: &statement)
        defer { sqlite3_finalize(statement) }
        for (index, id) in ids.enumerated() {
            bindText(id, to: statement, index: Int32(index + 1))
        }
        var existing: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            existing.insert(text(statement, index: 0))
        }
        return existing
    }

    @discardableResult
    private func removeOldestCompletedLocked(limit: Int) throws -> Int {
        guard limit > 0 else { return 0 }
        try execute("""
            DELETE FROM connection_history
            WHERE rowid IN (
                SELECT rowid FROM connection_history
                WHERE is_active = 0
                ORDER BY COALESCE(ended_at, started_at) ASC, rowid ASC
                LIMIT \(limit)
            )
            """)
        guard let database else { throw StoreError.openFailed }
        return Int(sqlite3_changes(database))
    }

    private func currentDatabaseBytesLocked() -> Int64 {
        let mainAttributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let walAttributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path + "-wal")
        let main = (mainAttributes?[.size] as? NSNumber)?.int64Value ?? 0
        let wal = (walAttributes?[.size] as? NSNumber)?.int64Value ?? 0
        return main + wal
    }

    private func aggregateLocked(column: String,
                                 limit: Int,
                                 query: ConnectionHistoryQuery = .all)
        -> [ConnectionHistoryTrafficVolume] {
        guard column == "strategy_name" || column == "host_name" else { return [] }
        let predicate = query.sqlPredicate
        let sql = "SELECT \(column), COALESCE(SUM(upload), 0), COALESCE(SUM(download), 0) "
            + "FROM connection_history \(predicate.clause) GROUP BY \(column) "
            + "ORDER BY (SUM(upload) + SUM(download)) DESC, \(column) ASC LIMIT \(limit)"
        do {
            var statement: OpaquePointer?
            try prepare(sql, into: &statement)
            defer { sqlite3_finalize(statement) }
            for (index, value) in predicate.values.enumerated() {
                bindText(value, to: statement, index: Int32(index + 1))
            }
            var values: [ConnectionHistoryTrafficVolume] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(ConnectionHistoryTrafficVolume(
                    name: text(statement, index: 0),
                    upload: sqlite3_column_int64(statement, 1),
                    download: sqlite3_column_int64(statement, 2)))
            }
            return values
        } catch {
            return []
        }
    }

    private func record(from statement: OpaquePointer?) -> ConnectionHistoryRecord? {
        let chainsText = text(statement, index: 16)
        let chains = (try? JSONDecoder().decode([String].self, from: Data(chainsText.utf8))) ?? []
        return ConnectionHistoryRecord(
            id: text(statement, index: 0),
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            endedAt: sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            isActive: sqlite3_column_int(statement, 3) != 0,
            upload: sqlite3_column_int64(statement, 4),
            download: sqlite3_column_int64(statement, 5),
            network: text(statement, index: 6),
            connectionType: text(statement, index: 7),
            sourceIP: text(statement, index: 8),
            sourcePort: text(statement, index: 9),
            destinationIP: text(statement, index: 10),
            destinationPort: text(statement, index: 11),
            host: text(statement, index: 12),
            sniffHost: text(statement, index: 13),
            process: text(statement, index: 14),
            processPath: text(statement, index: 15),
            chains: chains,
            rule: text(statement, index: 17),
            rulePayload: text(statement, index: 18))
    }

    private func row(for sql: String, bindings: [String] = []) -> SQLiteRow? {
        do {
            var statement: OpaquePointer?
            try prepare(sql, into: &statement)
            defer { sqlite3_finalize(statement) }
            for (index, value) in bindings.enumerated() {
                bindText(value, to: statement, index: Int32(index + 1))
            }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return SQLiteRow(statement: statement)
        } catch {
            return nil
        }
    }

    private func prepare(_ sql: String, into statement: inout OpaquePointer?) throws {
        guard let database else { throw StoreError.openFailed }
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw StoreError.sqlite(sqlite3_errcode(database))
        }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw StoreError.sqlite(result) }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw StoreError.openFailed }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        sqlite3_free(errorMessage)
        guard result == SQLITE_OK else { throw StoreError.sqlite(result) }
    }

    private func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.sqliteTransient)
        }
    }

    private func text(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private enum StoreError: Error {
        case openFailed
        case migrationRequired
        case sqlite(Int32)
    }

    private struct SQLiteRow {
        let values: [Int64]

        init(statement: OpaquePointer?) {
            values = (0..<4).map { sqlite3_column_int64(statement, Int32($0)) }
        }

        func int(_ index: Int) -> Int64 { values.indices.contains(index) ? values[index] : 0 }
    }
}
