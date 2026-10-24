import Foundation

struct ProxyChainReference: Codable, Equatable, Hashable, Identifiable, Sendable {
    var source: String
    var name: String
    var id: String { "\(source.utf8.count):\(source)\(name)" }
    var sourceLabel: String { source.isEmpty ? "配置内节点" : source }
}

struct ProxyChainConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var mode = "existing"
    var upstream: ProxyChainReference?
    var yaml = ""
    var targets: [ProxyChainReference] = []

    private enum CodingKeys: String, CodingKey {
        case enabled, mode, upstream, yaml, targets
    }

    init(enabled: Bool = false,
         mode: String = "existing",
         upstream: ProxyChainReference? = nil,
         yaml: String = "",
         targets: [ProxyChainReference] = []) {
        self.enabled = enabled
        self.mode = mode
        self.upstream = upstream
        self.yaml = yaml
        self.targets = targets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "existing"
        upstream = try container.decodeIfPresent(ProxyChainReference.self, forKey: .upstream)
        yaml = try container.decodeIfPresent(String.self, forKey: .yaml) ?? ""
        targets = try container.decodeIfPresent([ProxyChainReference].self, forKey: .targets) ?? []
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

    var summary: String { enabled ? "已启用 · \(targets.count) 个后置节点" : "未启用" }

    private struct SettingsEnvelope: Decodable {
        let proxyChain: ProxyChainConfiguration?
        let subscriptionID: String?
    }

    static func fromSettings(_ json: String?) -> Self {
        guard let json, let envelope = try? JSONDecoder().decode(SettingsEnvelope.self, from: Data(json.utf8)) else { return .init() }
        return envelope.proxyChain ?? .init()
    }

    func requiresApply(settingsJSON: String?, subscriptionID: UUID?) -> Bool {
        let envelope = settingsJSON.flatMap {
            try? JSONDecoder().decode(SettingsEnvelope.self, from: Data($0.utf8))
        }
        let appliedID = envelope?.subscriptionID.flatMap { UUID(uuidString: $0) }
        return self != (envelope?.proxyChain ?? .init()) || appliedID != subscriptionID
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
    var error: String?
    var warnings: [String]?
}
