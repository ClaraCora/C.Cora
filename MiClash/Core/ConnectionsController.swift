import Foundation

/// mihomo `/connections` 的轻量快照，只保留活动连接页实际使用的字段。
struct ConnectionsSnapshot: Decodable, Sendable {
    let downloadTotal: Int64
    let uploadTotal: Int64
    let connections: [ActiveConnection]

    init(downloadTotal: Int64 = 0,
         uploadTotal: Int64 = 0,
         connections: [ActiveConnection] = []) {
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
        self.connections = connections
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
    }
}

struct ActiveConnection: Decodable, Identifiable, Sendable {
    let id: String
    let metadata: ConnectionMetadata
    let upload: Int64
    let download: Int64
    let start: String
    let chains: [String]
    let rule: String
    let rulePayload: String

    private enum CodingKeys: String, CodingKey {
        case id, metadata, upload, download, start, chains, rule, rulePayload
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.lossyString(forKey: .id)
        metadata = try values.decodeIfPresent(ConnectionMetadata.self, forKey: .metadata)
            ?? ConnectionMetadata()
        upload = values.lossyInt64(forKey: .upload)
        download = values.lossyInt64(forKey: .download)
        start = values.lossyString(forKey: .start)
        chains = try values.decodeIfPresent([String].self, forKey: .chains) ?? []
        rule = values.lossyString(forKey: .rule)
        rulePayload = values.lossyString(forKey: .rulePayload)
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

    var routeText: String {
        chains.isEmpty ? "DIRECT" : chains.joined(separator: " → ")
    }

    var ruleText: String {
        guard !rule.isEmpty else { return "" }
        return rulePayload.isEmpty ? rule : "\(rule) · \(rulePayload)"
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
}

struct ConnectionMetadata: Decodable, Sendable {
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
    @Published private(set) var snapshot: ConnectionsSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var closingIDs: Set<String> = []
    @Published private(set) var isClosingAll = false
    @Published var error: String?
    private var generation = 0

    /// 由页面 `.task` 持有生命周期；离开页面后 SwiftUI 会取消轮询。
    func poll() async {
        reset()
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
        isLoading = false
        closingIDs.removeAll()
        isClosingAll = false
        error = nil
    }

    func refresh(showLoading: Bool = true) async {
        let currentGeneration = generation
        if showLoading { isLoading = true }
        defer { if showLoading { isLoading = false } }

        do {
            let latest = try await MihomoAPI.connectionsSnapshot()
            guard !Task.isCancelled, generation == currentGeneration else { return }
            snapshot = latest
            error = nil
        } catch {
            guard !Task.isCancelled, generation == currentGeneration else { return }
            self.error = error.localizedDescription
        }
    }

    func close(_ connection: ActiveConnection) async {
        guard !closingIDs.contains(connection.id) else { return }
        let currentGeneration = generation
        closingIDs.insert(connection.id)
        defer { closingIDs.remove(connection.id) }

        do {
            try await MihomoAPI.closeConnection(id: connection.id)
            guard generation == currentGeneration else { return }
            if let current = snapshot {
                snapshot = ConnectionsSnapshot(
                    downloadTotal: current.downloadTotal,
                    uploadTotal: current.uploadTotal,
                    connections: current.connections.filter { $0.id != connection.id })
            }
            error = nil
        } catch {
            guard generation == currentGeneration else { return }
            self.error = "关闭连接失败：\(error.localizedDescription)"
        }
    }

    func closeAll() async {
        guard !isClosingAll else { return }
        let currentGeneration = generation
        isClosingAll = true
        defer { isClosingAll = false }

        do {
            try await MihomoAPI.closeAllConnections()
            guard generation == currentGeneration else { return }
            if let current = snapshot {
                snapshot = ConnectionsSnapshot(
                    downloadTotal: current.downloadTotal,
                    uploadTotal: current.uploadTotal)
            }
            error = nil
        } catch {
            guard generation == currentGeneration else { return }
            self.error = "关闭全部连接失败：\(error.localizedDescription)"
        }
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
