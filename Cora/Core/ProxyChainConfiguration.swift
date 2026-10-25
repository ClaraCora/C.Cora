import Foundation

struct ProxyChainReference: Codable, Equatable, Hashable, Identifiable, Sendable {
    var source: String
    var name: String
    var id: String { "\(source.utf8.count):\(source)\(name)" }
    var sourceLabel: String { source.isEmpty ? "配置内节点" : source }
}

struct ProxyChainGroup: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var enabled: Bool
    var mode: String
    var upstream: ProxyChainReference?
    var yaml: String
    var targets: [ProxyChainReference]

    static let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    init(id: UUID = UUID(), name: String = "", enabled: Bool = false,
         mode: String = "existing", upstream: ProxyChainReference? = nil,
         yaml: String = "", targets: [ProxyChainReference] = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.mode = mode
        self.upstream = upstream
        self.yaml = yaml
        self.targets = targets
    }

    private enum CodingKeys: String, CodingKey { case id, name, enabled, mode, upstream, yaml, targets }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "existing"
        upstream = try c.decodeIfPresent(ProxyChainReference.self, forKey: .upstream)
        yaml = try c.decodeIfPresent(String.self, forKey: .yaml) ?? ""
        targets = try c.decodeIfPresent([ProxyChainReference].self, forKey: .targets) ?? []
    }

    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名分组" : name }
    var upstreamLabel: String { mode == "custom" ? "单独添加的前置" : upstream?.name ?? "未选择前置" }
}

struct ProxyChainConfiguration: Codable, Equatable, Sendable {
    static let maxGroups = 32
    static let maxTargets = 4096
    static let maxYAMLBytes = 64 * 1024
    var enabled = false
    var groups: [ProxyChainGroup] = []

    init(enabled: Bool = false, groups: [ProxyChainGroup] = []) {
        self.enabled = enabled
        self.groups = groups
    }

    private enum CodingKeys: String, CodingKey { case version, enabled, groups, mode, upstream, yaml, targets }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        guard version == 0 || version == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Unsupported proxy chain version")
        }
        if version == 2 || c.contains(.groups) {
            groups = try c.decodeIfPresent([ProxyChainGroup].self, forKey: .groups) ?? []
        } else {
            let mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "existing"
            let upstream = try c.decodeIfPresent(ProxyChainReference.self, forKey: .upstream)
            let yaml = try c.decodeIfPresent(String.self, forKey: .yaml) ?? ""
            let targets = try c.decodeIfPresent([ProxyChainReference].self, forKey: .targets) ?? []
            if enabled || upstream != nil || !yaml.isEmpty || !targets.isEmpty || mode != "existing" {
                groups = [.init(id: ProxyChainGroup.legacyID, name: "分组 1", enabled: true,
                                mode: mode, upstream: upstream, yaml: yaml, targets: targets)]
            } else { groups = [] }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .version)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(groups, forKey: .groups)
    }

    var dictionary: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    var json: String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
    var activeGroups: [ProxyChainGroup] { enabled ? groups.filter { $0.enabled && !$0.targets.isEmpty } : [] }
    var targetCount: Int { groups.reduce(0) { $0 + $1.targets.count } }
    var summary: String {
        enabled ? "已启用 \(activeGroups.count) 组 · \(activeGroups.reduce(0) { $0 + $1.targets.count }) 个后置节点" : "未启用"
    }

    // Ignore display names, disabled drafts, target ordering, and inactive
    // upstream fields when deciding whether the runtime needs a reconnect.
    private var effectiveGroups: [ProxyChainGroup] {
        activeGroups.map { group in
            var g = group
            g.name = ""
            g.targets = Array(Set(g.targets)).sorted { ($0.source, $0.name) < ($1.source, $1.name) }
            if g.mode == "existing" { g.yaml = "" } else { g.upstream = nil }
            return g
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func targetOwners(excluding id: UUID) -> [ProxyChainReference: String] {
        var owners: [ProxyChainReference: String] = [:]
        for group in groups where group.id != id && group.enabled {
            for ref in group.targets { owners[ref] = group.displayName }
        }
        return owners
    }
    func upstreamOwners(excluding id: UUID) -> [ProxyChainReference: String] {
        var owners: [ProxyChainReference: String] = [:]
        for group in groups where group.id != id && group.enabled && !group.targets.isEmpty && group.mode == "existing" {
            if let ref = group.upstream { owners[ref] = group.displayName }
        }
        return owners
    }

    private struct SettingsEnvelope: Decodable {
        let proxyChain: ProxyChainConfiguration?
        let subscriptionID: String?
    }
    static func fromSettings(_ json: String?) -> Self {
        guard let json, let envelope = try? JSONDecoder().decode(SettingsEnvelope.self, from: Data(json.utf8)) else { return .init() }
        return envelope.proxyChain ?? .init()
    }
    func requiresApply(settingsJSON: String?, subscriptionID: UUID?) -> Bool {
        let envelope = settingsJSON.flatMap { try? JSONDecoder().decode(SettingsEnvelope.self, from: Data($0.utf8)) }
        let appliedID = envelope?.subscriptionID.flatMap { UUID(uuidString: $0) }
        return effectiveGroups != (envelope?.proxyChain ?? .init()).effectiveGroups || appliedID != subscriptionID
    }
}

struct ProxyChainCatalog: Decodable, Sendable {
    var subscriptionID: String?
    struct Node: Decodable, Identifiable, Sendable {
        let source: String
        let name: String
        let type: String
        let issue: String?
        var reference: ProxyChainReference { .init(source: source, name: name) }
        var id: String { reference.id }
    }
    var nodes: [Node]?
    var warnings: [String]?
    var error: String?
}

struct ProxyChainValidation: Decodable, Sendable {
    var groupID: UUID?
    var conflictingGroupID: UUID?
    var error: String?
    var warnings: [String]?
}
