import Foundation

/// 由 Network Extension IPC 返回的轻量连接快照。
struct ConnectionsSnapshot: Decodable, Sendable {
    let downloadTotal: Int64
    let uploadTotal: Int64
    let connections: [ActiveConnection]
    /// Total number of live connections reported by the core. This remains
    /// available for totals-only snapshots where `connections` is intentionally
    /// empty to keep the App memory footprint low.
    let total: Int
    let tcpCount: Int
    let udpCount: Int

    init(downloadTotal: Int64 = 0,
         uploadTotal: Int64 = 0,
         connections: [ActiveConnection] = [],
         total: Int? = nil) {
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
        self.connections = connections
        self.total = max(0, total ?? connections.count)
        let counts = Self.networkCounts(connections)
        tcpCount = counts.tcp
        udpCount = counts.udp
    }

    private enum CodingKeys: String, CodingKey {
        case downloadTotal, uploadTotal, connections, total
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        downloadTotal = values.lossyInt64(forKey: .downloadTotal)
        uploadTotal = values.lossyInt64(forKey: .uploadTotal)
        let decoded = try values.decodeIfPresent([ActiveConnection].self, forKey: .connections) ?? []
        connections = decoded.sorted { $0.start > $1.start }
        total = max(0, values.decodeIfPresent(Int.self, forKey: .total) ?? connections.count)
        let counts = Self.networkCounts(connections)
        tcpCount = counts.tcp
        udpCount = counts.udp
    }

    private static func networkCounts(_ connections: [ActiveConnection]) -> (tcp: Int, udp: Int) {
        connections.reduce(into: (tcp: 0, udp: 0)) { counts, connection in
            if connection.networkKey == "tcp" { counts.tcp += 1 }
            if connection.networkKey == "udp" { counts.udp += 1 }
        }
    }
}

struct ConnectionHistoryEntry: Codable, Identifiable, Sendable {
    let connection: ActiveConnection
    let isActive: Bool
    let endedAt: Date?

    var id: String { connection.id }
}

extension ActiveConnection {
    init(historyRecord record: ConnectionHistoryRecord) {
        id = record.id
        metadata = ConnectionMetadata(network: record.network,
                                      type: record.connectionType,
                                      sourceIP: record.sourceIP,
                                      destinationIP: record.destinationIP,
                                      sourcePort: record.sourcePort,
                                      destinationPort: record.destinationPort,
                                      host: record.host,
                                      sniffHost: record.sniffHost,
                                      process: record.process,
                                      processPath: record.processPath)
        upload = record.upload
        download = record.download
        start = record.startedAt.ISO8601Format()
        startDate = record.startedAt
        chains = record.chains
        rule = record.rule
        rulePayload = record.rulePayload
        networkKey = record.network.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// 会话级流量累积项。它只保存名称和两个 Int64，不保存完整连接详情。
struct ConnectionTrafficVolume: Codable, Sendable, Equatable {
    var upload: Int64 = 0
    var download: Int64 = 0

    var total: Int64 { upload + download }

    mutating func add(upload: Int64, download: Int64) {
        self.upload += max(0, upload)
        self.download += max(0, download)
    }
}

/// 与详情记录分离的当前 VPN 会话统计；VPN 停止或重连时重置。
struct ConnectionSessionSummary: Codable, Sendable {
    var totalConnectionCount = 0
    var activeConnectionCount = 0
    var uploadTotal: Int64 = 0
    var downloadTotal: Int64 = 0
    var strategyVolumes: [String: ConnectionTrafficVolume] = [:]
    var hostVolumes: [String: ConnectionTrafficVolume] = [:]

    var totalTraffic: Int64 {
        uploadTotal + downloadTotal
    }
}

struct ActiveConnection: Codable, Identifiable, Sendable {
    let id: String
    let metadata: ConnectionMetadata
    let upload: Int64
    let download: Int64
    let start: String
    let startDate: Date?
    let chains: [String]
    let rule: String
    let rulePayload: String
    let networkKey: String

    private enum CodingKeys: String, CodingKey {
        case id, metadata, upload, download, start, chains, rule, rulePayload
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.lossyString(forKey: .id)
        let decodedMetadata = try values.decodeIfPresent(ConnectionMetadata.self, forKey: .metadata)
            ?? ConnectionMetadata()
        metadata = decodedMetadata
        networkKey = decodedMetadata.network
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        upload = values.lossyInt64(forKey: .upload)
        download = values.lossyInt64(forKey: .download)
        start = values.lossyString(forKey: .start)
        startDate = Self.parseStartDate(start)
        chains = try values.decodeIfPresent([String].self, forKey: .chains) ?? []
        rule = values.lossyString(forKey: .rule)
        rulePayload = values.lossyString(forKey: .rulePayload)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(metadata, forKey: .metadata)
        try values.encode(upload, forKey: .upload)
        try values.encode(download, forKey: .download)
        try values.encode(start, forKey: .start)
        try values.encode(chains, forKey: .chains)
        try values.encode(rule, forKey: .rule)
        try values.encode(rulePayload, forKey: .rulePayload)
    }

    var destinationTitle: String {
        if !metadata.host.isEmpty { return metadata.host }
        if !metadata.sniffHost.isEmpty { return metadata.sniffHost }
        return metadata.destinationIP.isEmpty ? "未知目标" : metadata.destinationIP
    }

    /// The canonical key used by SQLite traffic aggregates and detail filters.
    var trafficHostName: String {
        ConnectionHistoryRecord.normalizedHostName(host: metadata.host,
                                                    sniffHost: metadata.sniffHost,
                                                    destinationIP: metadata.destinationIP)
    }

    var destinationAddress: String {
        joinedAddress(ip: metadata.destinationIP, port: metadata.destinationPort)
    }

    var sourceAddress: String {
        joinedAddress(ip: metadata.sourceIP, port: metadata.sourcePort)
    }

    var endpointText: String {
        if sourceAddress.isEmpty { return destinationAddress }
        if destinationAddress.isEmpty { return sourceAddress }
        return "\(sourceAddress) → \(destinationAddress)"
    }

    var routeText: String {
        chains.isEmpty ? "DIRECT" : chains.joined(separator: " → ")
    }

    var strategyName: String {
        let value = chains.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "DIRECT" : value
    }

    /// mihomo 的连接链路从最终出口节点开始，策略组位于后续链路中。
    var proxyNodeName: String {
        let value = chains.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "DIRECT" : value
    }

    var destinationAddressOrTitle: String {
        let title = destinationTitle
        guard !metadata.destinationPort.isEmpty,
              !title.contains(":") else { return title }
        return "\(title):\(metadata.destinationPort)"
    }

    var recordTimeText: String {
        guard let startDate else { return start }
        return startDate.formatted(date: .omitted, time: .shortened)
    }

    var ruleText: String {
        guard !rule.isEmpty else { return "" }
        return rulePayload.isEmpty ? rule : "\(rule) · \(rulePayload)"
    }

    var networkLabel: String {
        networkKey.isEmpty ? "IP" : networkKey.uppercased()
    }

    var transferred: Int64 {
        upload + download
    }

    var durationText: String {
        guard let startDate else { return "" }
        let seconds = max(0, Int(Date().timeIntervalSince(startDate)))
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时 \(minutes % 60) 分" }
        return "\(hours / 24) 天 \(hours % 24) 小时"
    }

    var searchableText: String {
        [destinationTitle, destinationAddress, sourceAddress, metadata.process,
         metadata.processPath, routeText, ruleText, metadata.network]
            .joined(separator: " ")
            .lowercased()
    }

    private func joinedAddress(ip: String, port: String) -> String {
        guard !ip.isEmpty else { return "" }
        guard !port.isEmpty else { return ip }
        return ip.contains(":") ? "[\(ip)]:\(port)" : "\(ip):\(port)"
    }

    private static func parseStartDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(value) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(value)
    }
}

struct ConnectionMetadata: Codable, Sendable {
    let network: String
    let type: String
    let sourceIP: String
    let destinationIP: String
    let sourcePort: String
    let destinationPort: String
    let host: String
    let sniffHost: String
    let process: String
    let processPath: String

    init(network: String = "",
         type: String = "",
         sourceIP: String = "",
         destinationIP: String = "",
         sourcePort: String = "",
         destinationPort: String = "",
         host: String = "",
         sniffHost: String = "",
         process: String = "",
         processPath: String = "") {
        self.network = network
        self.type = type
        self.sourceIP = sourceIP
        self.destinationIP = destinationIP
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.host = host
        self.sniffHost = sniffHost
        self.process = process
        self.processPath = processPath
    }

    private enum CodingKeys: String, CodingKey {
        case network, type, sourceIP, destinationIP, sourcePort, destinationPort
        case host, sniffHost, process, processPath
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        network = values.lossyString(forKey: .network)
        type = values.lossyString(forKey: .type)
        sourceIP = values.lossyString(forKey: .sourceIP)
        destinationIP = values.lossyString(forKey: .destinationIP)
        sourcePort = values.lossyString(forKey: .sourcePort)
        destinationPort = values.lossyString(forKey: .destinationPort)
        host = values.lossyString(forKey: .host)
        sniffHost = values.lossyString(forKey: .sniffHost)
        process = values.lossyString(forKey: .process)
        processPath = values.lossyString(forKey: .processPath)
    }
}

@MainActor
final class ConnectionsController: ObservableObject {
    private static let maximumRememberedConnectionIDs = 20_000
    private static let maximumStrategyStatistics = 256
    private static let maximumHostStatistics = 4_096
    private static let persistenceKey = "connectionSession.v1"
    private static let persistenceInterval: TimeInterval = 5
    private static let pollIntervalNanoseconds: UInt64 = 3_000_000_000

    @Published private(set) var snapshot: ConnectionsSnapshot?
    @Published private(set) var history: [ConnectionHistoryEntry] = []
    @Published private(set) var sessionSummary = ConnectionSessionSummary()
    @Published private(set) var historySummary = ConnectionHistorySummary.empty
    @Published private(set) var hasMoreHistory = false
    @Published private(set) var isLoadingMoreHistory = false
    @Published private(set) var isLoading = false
    @Published private(set) var closingIDs: Set<String> = []
    @Published private(set) var isClosingAll = false
    @Published var error: String?
    private var generation = 0
    private var activeSamples: [String: ActiveConnectionSample] = [:]
    // These compact, bounded IDs live in the main App rather than the Network
    // Extension. They keep session totals stable if the IPC active list is
    // temporarily truncated, without retaining full connection details.
    private var rememberedConnectionIDs: Set<UInt64> = []
    private var rememberedConnectionOrder: [UInt64] = []
    private var lastPersistenceDate = Date.distantPast
    private var lastKernelUploadTotal: Int64?
    private var lastKernelDownloadTotal: Int64?
    private let historyStore = ConnectionHistoryStore.openShared()
    private var historyOffset = 0
    private var lastHistoryRefreshDate = Date.distantPast
    private var lastHistoryCountRefreshDate = Date.distantPast
    // The overview only needs totals. A full connection array is requested
    // while the record screen is visible, avoiding a large JSON allocation in
    // the App every second when the user is on another tab.
    private var wantsFullSnapshot = false
    private var isRefreshInFlight = false

    private struct ActiveConnectionSample: Codable {
        let upload: Int64
        let download: Int64
        let strategyName: String
        let hostName: String
    }

    /// A compact snapshot of the current VPN session. It stays in the App's own
    /// storage, never in the Network Extension, so restoring the record screen
    /// cannot increase the extension's memory footprint.
    private struct PersistedSession: Codable {
        let version: Int
        let summary: ConnectionSessionSummary
        let history: [ConnectionHistoryEntry]
        let activeSamples: [String: ActiveConnectionSample]
        let rememberedConnectionOrder: [UInt64]
        let lastKernelUploadTotal: Int64?
        let lastKernelDownloadTotal: Int64?
        let savedAt: Date
    }

    init() {
        restorePersistedSession()
        // The root view starts with a totals-only IPC poll. Load only the
        // counts needed by the overview here; the record page fetches its
        // first detail page when it becomes visible.
        reloadHistoryCountsFromStore(force: true)
    }

    /// 由页面 `.task` 持有生命周期；离开页面后 SwiftUI 会取消轮询。
    func poll() async {
        await refresh(showLoading: wantsFullSnapshot)
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            } catch {
                return
            }
            await refresh(showLoading: false)
        }
    }

    func setFullSnapshotEnabled(_ enabled: Bool) {
        guard wantsFullSnapshot != enabled else { return }
        wantsFullSnapshot = enabled
        guard enabled else {
            // Detail rows are owned by the record screen. Once that screen is
            // gone (or the app enters the background), release its bounded
            // page and chart aggregates while retaining the scalar counters
            // used by the overview cards.
            snapshot = snapshot.map {
                ConnectionsSnapshot(downloadTotal: $0.downloadTotal,
                                    uploadTotal: $0.uploadTotal,
                                    connections: [],
                                    total: $0.total)
            }
            history.removeAll(keepingCapacity: false)
            historyOffset = 0
            hasMoreHistory = false
            historySummary = ConnectionHistorySummary(
                recordCount: historySummary.recordCount,
                activeCount: historySummary.activeCount,
                uploadTotal: historySummary.uploadTotal,
                downloadTotal: historySummary.downloadTotal,
                strategyVolumes: [],
                hostVolumes: [])
            return
        }
        Task { [weak self] in
            await self?.refresh(showLoading: true)
        }
    }

    func reset() {
        generation &+= 1
        snapshot = nil
        historyStore?.clearAll()
        history = []
        historySummary = .empty
        historyOffset = 0
        hasMoreHistory = false
        lastHistoryRefreshDate = .distantPast
        lastHistoryCountRefreshDate = .distantPast
        isLoadingMoreHistory = false
        sessionSummary = ConnectionSessionSummary()
        activeSamples = [:]
        rememberedConnectionIDs.removeAll(keepingCapacity: true)
        rememberedConnectionOrder.removeAll(keepingCapacity: true)
        lastKernelUploadTotal = nil
        lastKernelDownloadTotal = nil
        isLoading = false
        closingIDs.removeAll()
        isClosingAll = false
        error = nil
        lastPersistenceDate = .distantPast
        UserDefaults.standard.removeObject(forKey: Self.persistenceKey)
        KernelController.shared.updateConnectionTotals(download: 0, upload: 0)
    }

    /// Flushes only compact view statistics. Full connection records live in
    /// the App Group SQLite store owned by the running Network Extension.
    func flushPersistence() {
        persistSession(force: true)
    }

    func refresh(showLoading: Bool = true) async {
        let currentGeneration = generation
        guard !isRefreshInFlight else { return }
        isRefreshInFlight = true
        defer { isRefreshInFlight = false }
        if showLoading { isLoading = true }
        defer { if showLoading { isLoading = false } }

        let fullSnapshot = wantsFullSnapshot
        let result = await CoreStateManager.shared.sendMessage([
            "cmd": "connections",
            "limit": fullSnapshot ? 200 : 0,
        ])
        switch result {
        case .ok(let data):
            do {
                let latest = try JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
                guard !Task.isCancelled, generation == currentGeneration else { return }
                KernelController.shared.updateConnectionTotals(download: latest.downloadTotal,
                                                                upload: latest.uploadTotal)
                // A totals-only poll deliberately drops any previously loaded
                // detail array. Keeping the old 200-row snapshot alive while
                // the overview is visible only increases App memory; the
                // record page will request a fresh bounded page when opened.
                let retainedConnections = fullSnapshot ? latest.connections : []
                snapshot = ConnectionsSnapshot(downloadTotal: latest.downloadTotal,
                                               uploadTotal: latest.uploadTotal,
                                               connections: retainedConnections,
                                               total: latest.total)
                if hasStartedNewKernelSession(with: latest) {
                    clearSessionState()
                }
                lastKernelUploadTotal = latest.uploadTotal
                lastKernelDownloadTotal = latest.downloadTotal
                if fullSnapshot {
                    mergeSessionStatistics(with: latest.connections)
                    reconcileSessionTotals(uploadTotal: latest.uploadTotal,
                                           downloadTotal: latest.downloadTotal)
                    persistSession()
                    reloadHistoryFromStore(activeConnections: latest.connections,
                                           force: showLoading)
                } else {
                    // The overview only needs counts and totals. Avoid loading
                    // a page and running strategy/host GROUP BY on every poll.
                    reloadHistoryCountsFromStore(force: false)
                }
                error = nil
            } catch {
                guard !Task.isCancelled, generation == currentGeneration else { return }
                self.error = "连接快照无法解析：\(error.localizedDescription)"
            }
        case .failure(let reason):
            guard !Task.isCancelled, generation == currentGeneration else { return }
            self.error = reason
        }
    }

    func close(_ connection: ActiveConnection) async {
        guard !closingIDs.contains(connection.id) else { return }
        let currentGeneration = generation
        closingIDs.insert(connection.id)
        defer { closingIDs.remove(connection.id) }

        let result = await CoreStateManager.shared.sendMessage([
            "cmd": "closeConnection",
            "id": connection.id,
        ])
        switch Self.commandError(result) {
        case nil:
            guard generation == currentGeneration else { return }
            if let current = snapshot {
                snapshot = ConnectionsSnapshot(
                    downloadTotal: current.downloadTotal,
                    uploadTotal: current.uploadTotal,
                    connections: current.connections.filter { $0.id != connection.id },
                    total: max(0, current.total - 1))
                mergeSessionStatistics(with: snapshot?.connections ?? [])
                persistSession(force: true)
                reloadHistoryFromStore(activeConnections: snapshot?.connections ?? [])
            }
            error = nil
        case .some(let reason):
            guard generation == currentGeneration else { return }
            self.error = "关闭连接失败：\(reason)"
        }
    }

    func closeAll() async {
        guard !isClosingAll else { return }
        let currentGeneration = generation
        isClosingAll = true
        defer { isClosingAll = false }

        let result = await CoreStateManager.shared.sendMessage(["cmd": "closeAllConnections"])
        switch Self.commandError(result) {
        case nil:
            guard generation == currentGeneration else { return }
            if let current = snapshot {
                snapshot = ConnectionsSnapshot(
                    downloadTotal: current.downloadTotal,
                    uploadTotal: current.uploadTotal,
                    total: 0)
                mergeSessionStatistics(with: [])
                persistSession(force: true)
                reloadHistoryFromStore(activeConnections: [])
            }
            error = nil
        case .some(let reason):
            guard generation == currentGeneration else { return }
            self.error = "关闭全部连接失败：\(reason)"
        }
    }

    private static func commandError(_ result: TunnelManager.IPCResult) -> String? {
        switch result {
        case .failure(let reason):
            return reason
        case .ok(let data):
            guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return "Tunnel 返回了无法识别的响应" }
            guard (response["ok"] as? Bool) == true else {
                return (response["error"] as? String) ?? "未知错误"
            }
            return nil
        }
    }

    func reloadHistoryFromStore(activeConnections: [ActiveConnection]? = nil,
                                force: Bool = true) {
        guard let historyStore else {
            if let activeConnections { history = activeEntries(activeConnections) }
            return
        }
        let active = activeConnections ?? snapshot?.connections ?? []
        let now = Date()
        guard force || now.timeIntervalSince(lastHistoryRefreshDate) >= 2 else {
            // Keep the visible active rows responsive without repeating the
            // full SQLite aggregate query on every one-second App poll.
            let stored = history.filter { !$0.isActive }
            history = activeEntries(active) + stored
            return
        }
        lastHistoryRefreshDate = now
        historyOffset = 0
        let persisted = historyStore.fetchPage(offset: 0)
        history = mergedHistory(activeConnections: active, persisted: persisted)
        historyOffset = persisted.count
        hasMoreHistory = persisted.count == ConnectionHistoryStore.defaultFetchPageSize
        historySummary = historyStore.summary()
    }

    /// Refreshes only the values shown by the overview connection cards.
    /// Keeping this path separate from `reloadHistoryFromStore` avoids
    /// materializing connection details and aggregate dictionaries during the
    /// normal three-second totals poll.
    private func reloadHistoryCountsFromStore(force: Bool = false) {
        guard let historyStore else {
            let activeCount = snapshot?.total ?? snapshot?.connections.count ?? 0
            let recordCount = max(history.count, activeCount)
            let current = historySummary
            guard current.recordCount != recordCount ||
                    current.activeCount != activeCount else { return }
            historySummary = ConnectionHistorySummary(
                recordCount: recordCount,
                activeCount: activeCount,
                uploadTotal: current.uploadTotal,
                downloadTotal: current.downloadTotal,
                strategyVolumes: current.strategyVolumes,
                hostVolumes: current.hostVolumes)
            return
        }

        let now = Date()
        guard force || now.timeIntervalSince(lastHistoryCountRefreshDate) >= 2 else {
            return
        }
        lastHistoryCountRefreshDate = now
        let counts = historyStore.countSummary()
        let current = historySummary
        guard current.recordCount != counts.recordCount ||
                current.activeCount != counts.activeCount ||
                current.uploadTotal != counts.uploadTotal ||
                current.downloadTotal != counts.downloadTotal else {
            return
        }
        historySummary = ConnectionHistorySummary(
            recordCount: counts.recordCount,
            activeCount: counts.activeCount,
            uploadTotal: counts.uploadTotal,
            downloadTotal: counts.downloadTotal,
            strategyVolumes: current.strategyVolumes,
            hostVolumes: current.hostVolumes)
    }

    /// Loads one bounded page for a strategy/host detail screen. The filter is
    /// executed in SQLite so opening a detail view never materializes the full
    /// retained history in the App process.
    func historyPage(for query: ConnectionHistoryQuery,
                     offset: Int,
                     limit: Int = ConnectionHistoryStore.defaultFetchPageSize)
        -> [ConnectionHistoryEntry] {
        if let historyStore {
            return historyStore.fetchPage(offset: offset, limit: limit, query: query)
                .map(historyEntry)
        }

        // App Group access can be unavailable under an unsigned build. Keep a
        // bounded fallback using the already-loaded page rather than failing
        // the record screen or retaining additional history.
        let filtered = history.filter { query.matches($0) }
        return Array(filtered.dropFirst(max(0, offset)).prefix(max(1, limit)))
    }

    func historySummary(for query: ConnectionHistoryQuery) -> ConnectionHistorySummary {
        historyStore?.summary(for: query) ?? .empty
    }

    func loadMoreHistory() {
        guard !isLoadingMoreHistory, hasMoreHistory, let historyStore else { return }
        isLoadingMoreHistory = true
        let page = historyStore.fetchPage(offset: historyOffset)
        historyOffset += page.count
        hasMoreHistory = page.count == ConnectionHistoryStore.defaultFetchPageSize
        let knownIDs = Set(history.map(\.id))
        let extra = page.filter { !knownIDs.contains($0.id) }.map(historyEntry)
        history.append(contentsOf: extra)
        isLoadingMoreHistory = false
    }

    private func mergedHistory(activeConnections: [ActiveConnection],
                               persisted: [ConnectionHistoryRecord]) -> [ConnectionHistoryEntry] {
        let active = activeEntries(activeConnections)
        let activeIDs = Set(active.map(\.id))
        let stored = persisted.filter { !activeIDs.contains($0.id) }.map(historyEntry)
        return active + stored
    }

    private func activeEntries(_ connections: [ActiveConnection]) -> [ConnectionHistoryEntry] {
        connections.map { ConnectionHistoryEntry(connection: $0, isActive: true, endedAt: nil) }
    }

    private func historyEntry(_ record: ConnectionHistoryRecord) -> ConnectionHistoryEntry {
        ConnectionHistoryEntry(connection: ActiveConnection(historyRecord: record),
                               isActive: record.isActive,
                               endedAt: record.endedAt)
    }

    /// 用每个活动连接的增量更新会话统计，避免把最近 120 条详情缓存误当作总流量。
    private func mergeSessionStatistics(with activeConnections: [ActiveConnection]) {
        var updatedSummary = sessionSummary
        var nextSamples: [String: ActiveConnectionSample] = [:]
        nextSamples.reserveCapacity(activeConnections.count)

        for connection in activeConnections {
            let strategyName = connection.strategyName
            let hostName = connection.trafficHostName
            let previous = activeSamples[connection.id]
            let uploadDelta = previous.map { max(0, connection.upload - $0.upload) } ?? connection.upload
            let downloadDelta = previous.map { max(0, connection.download - $0.download) } ?? connection.download

            let statisticStrategy = previous?.strategyName ?? strategyName
            let statisticHost = previous?.hostName ?? hostName

            if previous == nil, rememberConnectionID(connection.id) {
                updatedSummary.totalConnectionCount += 1
            }
            updatedSummary.uploadTotal += uploadDelta
            updatedSummary.downloadTotal += downloadDelta
            addTraffic(upload: uploadDelta,
                       download: downloadDelta,
                       named: statisticStrategy,
                       to: &updatedSummary.strategyVolumes,
                       maximumEntries: Self.maximumStrategyStatistics)
            addTraffic(upload: uploadDelta,
                       download: downloadDelta,
                       named: statisticHost,
                       to: &updatedSummary.hostVolumes,
                       maximumEntries: Self.maximumHostStatistics)
            nextSamples[connection.id] = ActiveConnectionSample(
                upload: connection.upload,
                download: connection.download,
                strategyName: strategyName,
                hostName: hostName)
        }

        updatedSummary.activeConnectionCount = activeConnections.count
        activeSamples = nextSamples
        sessionSummary = updatedSummary
    }

    private func addTraffic(upload: Int64,
                            download: Int64,
                            named rawName: String,
                            to volumes: inout [String: ConnectionTrafficVolume],
                            maximumEntries: Int) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = name.isEmpty ? "未知" : name
        if volumes[key] == nil, volumes.count >= maximumEntries,
           let smallest = volumes.min(by: { $0.value.total < $1.value.total })?.key {
            volumes.removeValue(forKey: smallest)
        }
        var volume = volumes[key, default: ConnectionTrafficVolume()]
        volume.add(upload: upload, download: download)
        volumes[key] = volume
    }

    /// mihomo keeps traffic totals for the lifetime of the running tunnel, even
    /// while the App process is not resident. Make those counters authoritative
    /// when the App comes back so traffic from that gap is not lost.
    private func reconcileSessionTotals(uploadTotal: Int64, downloadTotal: Int64) {
        var updatedSummary = sessionSummary
        updatedSummary.uploadTotal = max(updatedSummary.uploadTotal, max(0, uploadTotal))
        updatedSummary.downloadTotal = max(updatedSummary.downloadTotal, max(0, downloadTotal))
        sessionSummary = updatedSummary
    }

    /// Avoid counting an active connection twice when it briefly falls outside
    /// the IPC response limit and appears again on a later refresh.
    private func rememberConnectionID(_ id: String) -> Bool {
        let hash = id.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { value, byte in
            (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
        guard rememberedConnectionIDs.insert(hash).inserted else { return false }
        rememberedConnectionOrder.append(hash)
        if rememberedConnectionOrder.count > Self.maximumRememberedConnectionIDs {
            let expired = rememberedConnectionOrder.removeFirst()
            rememberedConnectionIDs.remove(expired)
        }
        return true
    }

    /// A lower core counter means the Network Extension was restarted while the
    /// App was absent. Keep the persisted view state for a live tunnel, but do
    /// not accidentally merge two separate VPN sessions.
    private func hasStartedNewKernelSession(with snapshot: ConnectionsSnapshot) -> Bool {
        guard let previousUpload = lastKernelUploadTotal,
              let previousDownload = lastKernelDownloadTotal else {
            return false
        }
        return snapshot.uploadTotal < previousUpload || snapshot.downloadTotal < previousDownload
    }

    private func clearSessionState() {
        sessionSummary = ConnectionSessionSummary()
        activeSamples = [:]
        rememberedConnectionIDs.removeAll(keepingCapacity: true)
        rememberedConnectionOrder.removeAll(keepingCapacity: true)
        lastKernelUploadTotal = nil
        lastKernelDownloadTotal = nil
        UserDefaults.standard.removeObject(forKey: Self.persistenceKey)
    }

    private func restorePersistedSession() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistenceKey),
              let persisted = try? JSONDecoder().decode(PersistedSession.self, from: data),
              persisted.version == 1 else {
            return
        }

        sessionSummary = persisted.summary
        // Older App-only history is intentionally ignored. The shared store is
        // authoritative and survives App termination while the VPN keeps running.
        history = []
        activeSamples = persisted.activeSamples
        rememberedConnectionOrder = Array(
            persisted.rememberedConnectionOrder.suffix(Self.maximumRememberedConnectionIDs))
        rememberedConnectionIDs = Set(rememberedConnectionOrder)
        lastKernelUploadTotal = persisted.lastKernelUploadTotal
        lastKernelDownloadTotal = persisted.lastKernelDownloadTotal
        lastPersistenceDate = persisted.savedAt
    }

    private func persistSession(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPersistenceDate) >= Self.persistenceInterval else {
            return
        }

        let persisted = PersistedSession(
            version: 1,
            summary: sessionSummary,
            history: [],
            activeSamples: activeSamples,
            rememberedConnectionOrder: rememberedConnectionOrder,
            lastKernelUploadTotal: lastKernelUploadTotal,
            lastKernelDownloadTotal: lastKernelDownloadTotal,
            savedAt: now)
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistenceKey)
        lastPersistenceDate = now
    }
}

private extension ConnectionHistoryQuery {
    func matches(_ entry: ConnectionHistoryEntry) -> Bool {
        if let isActive, entry.isActive != isActive { return false }
        if let network, entry.connection.networkKey != network { return false }
        if let searchText, !entry.connection.searchableText.contains(searchText) { return false }
        return matches(entry.connection)
    }

    func matches(_ connection: ActiveConnection) -> Bool {
        if let strategyName, connection.strategyName != strategyName { return false }
        if let hostName, connection.trafficHostName != hostName { return false }
        return true
    }
}

private extension KeyedDecodingContainer {
    func lossyString(forKey key: Key) -> String {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Int64.self, forKey: key) { return String(value) }
        return ""
    }

    func lossyInt64(forKey key: Key) -> Int64 {
        if let value = try? decode(Int64.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key) { return Int64(value) }
        if let value = try? decode(String.self, forKey: key) { return Int64(value) ?? 0 }
        return 0
    }
}
