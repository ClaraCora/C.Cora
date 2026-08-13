import Foundation

/// 由 Network Extension IPC 返回的轻量连接快照。
struct ConnectionsSnapshot: Decodable, Sendable {
    let downloadTotal: Int64
    let uploadTotal: Int64
    let connections: [ActiveConnection]
    let tcpCount: Int
    let udpCount: Int

    init(downloadTotal: Int64 = 0,
         uploadTotal: Int64 = 0,
         connections: [ActiveConnection] = []) {
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
        self.connections = connections
        let counts = Self.networkCounts(connections)
        tcpCount = counts.tcp
        udpCount = counts.udp
    }

    private enum CodingKeys: String, CodingKey {
        case downloadTotal, uploadTotal, connections
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        downloadTotal = values.lossyInt64(forKey: .downloadTotal)
        uploadTotal = values.lossyInt64(forKey: .uploadTotal)
        let decoded = try values.decodeIfPresent([ActiveConnection].self, forKey: .connections) ?? []
        connections = decoded.sorted { $0.start > $1.start }
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
    // Active connections are supplied by the core with its own limit. Keep only a
    // small, in-memory tail of finished connections for the current VPN session.
    private static let maximumEndedHistory = 120
    private static let maximumRememberedConnectionIDs = 20_000
    private static let maximumStrategyStatistics = 256
    private static let maximumHostStatistics = 4_096
    private static let persistenceKey = "connectionSession.v1"
    private static let persistenceInterval: TimeInterval = 5

    @Published private(set) var snapshot: ConnectionsSnapshot?
    @Published private(set) var history: [ConnectionHistoryEntry] = []
    @Published private(set) var sessionSummary = ConnectionSessionSummary()
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
        let savedAt: Date
    }

    init() {
        restorePersistedSession()
    }

    /// 由页面 `.task` 持有生命周期；离开页面后 SwiftUI 会取消轮询。
    func poll() async {
        await refresh(showLoading: true)
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            await refresh(showLoading: false)
        }
    }

    func reset() {
        generation &+= 1
        snapshot = nil
        history = []
        sessionSummary = ConnectionSessionSummary()
        activeSamples = [:]
        rememberedConnectionIDs.removeAll(keepingCapacity: true)
        rememberedConnectionOrder.removeAll(keepingCapacity: true)
        isLoading = false
        closingIDs.removeAll()
        isClosingAll = false
        error = nil
        UserDefaults.standard.removeObject(forKey: Self.persistenceKey)
        lastPersistenceDate = .distantPast
    }

    /// Flushes the compact session state before the App is suspended. This is
    /// intentionally owned by the App process; NE should only keep live VPN
    /// state and must not become a long-lived connection-history database.
    func flushPersistence() {
        persistSession(force: true)
    }

    func refresh(showLoading: Bool = true) async {
        let currentGeneration = generation
        if showLoading { isLoading = true }
        defer { if showLoading { isLoading = false } }

        let result = await CoreStateManager.shared.sendMessage([
            "cmd": "connections",
            "limit": 200,
        ])
        switch result {
        case .ok(let data):
            do {
                let latest = try JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
                guard !Task.isCancelled, generation == currentGeneration else { return }
                snapshot = latest
                mergeSessionStatistics(with: latest.connections)
                mergeHistory(with: latest.connections)
                reconcileSessionTotals(uploadTotal: latest.uploadTotal,
                                       downloadTotal: latest.downloadTotal)
                persistSession()
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
                    connections: current.connections.filter { $0.id != connection.id })
                mergeSessionStatistics(with: snapshot?.connections ?? [])
                mergeHistory(with: snapshot?.connections ?? [])
                persistSession(force: true)
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
                    uploadTotal: current.uploadTotal)
                mergeSessionStatistics(with: [])
                mergeHistory(with: [])
                persistSession(force: true)
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

    private func mergeHistory(with activeConnections: [ActiveConnection]) {
        let activeIDs = Set(activeConnections.map(\.id))
        let now = Date()

        let activeEntries = activeConnections.map { connection in
            ConnectionHistoryEntry(connection: connection, isActive: true, endedAt: nil)
        }

        // Do not let a long-running VPN session turn the record screen into an
        // unbounded memory cache. History is deliberately session-only and is
        // discarded by reset() when the VPN stops or reconnects.
        let endedEntries = history
            .filter { !activeIDs.contains($0.id) }
            .map {
                ConnectionHistoryEntry(connection: $0.connection,
                                       isActive: false,
                                       endedAt: $0.endedAt ?? now)
            }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
            .prefix(Self.maximumEndedHistory)

        history = (activeEntries + Array(endedEntries)).sorted { left, right in
            let leftDate = left.connection.startDate ?? left.endedAt ?? .distantPast
            let rightDate = right.connection.startDate ?? right.endedAt ?? .distantPast
            return leftDate > rightDate
        }
    }

    /// 用每个活动连接的增量更新会话统计，避免把最近 120 条详情缓存误当作总流量。
    private func mergeSessionStatistics(with activeConnections: [ActiveConnection]) {
        var updatedSummary = sessionSummary
        var nextSamples: [String: ActiveConnectionSample] = [:]
        nextSamples.reserveCapacity(activeConnections.count)

        for connection in activeConnections {
            let strategyName = connection.strategyName
            let hostName = connection.destinationTitle.isEmpty ? "未知" : connection.destinationTitle
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

    private func restorePersistedSession() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistenceKey),
              let persisted = try? JSONDecoder().decode(PersistedSession.self, from: data),
              persisted.version == 1 else {
            return
        }

        sessionSummary = persisted.summary
        history = Array(persisted.history.prefix(Self.maximumEndedHistory))
        activeSamples = persisted.activeSamples
        rememberedConnectionOrder = Array(
            persisted.rememberedConnectionOrder.suffix(Self.maximumRememberedConnectionIDs))
        rememberedConnectionIDs = Set(rememberedConnectionOrder)
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
            history: history,
            activeSamples: activeSamples,
            rememberedConnectionOrder: rememberedConnectionOrder,
            savedAt: now)
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistenceKey)
        lastPersistenceDate = now
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
