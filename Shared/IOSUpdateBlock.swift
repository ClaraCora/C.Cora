import Foundation

struct IOSUpdateBlockConfiguration: Codable, Equatable {
    var id = "default"
    var enabled = false

    func validated() throws -> Self {
        guard !id.isEmpty, id.utf8.count <= 64,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 }) else {
            throw IOSUpdateBlockError.invalidConfiguration
        }
        return self
    }

    func json() throws -> String {
        String(decoding: try JSONEncoder().encode(validated()), as: UTF8.self)
    }

    var dictionary: [String: Any] { ["id": id, "enabled": enabled] }
}

enum IOSUpdateBlockError: LocalizedError {
    case invalidConfiguration
    var errorDescription: String? { "iOS 更新拦截设置格式不正确" }
}

enum IOSUpdateBlockStorage {
    private static var fileURL: URL {
        let base = AppGroup.containerURL ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                                    in: .userDomainMask)[0]
            .appendingPathComponent("Cora", isDirectory: true)
        return base.appendingPathComponent("IOSUpdateBlock", isDirectory: true)
            .appendingPathComponent("configuration.json")
    }

    static func load() -> IOSUpdateBlockConfiguration {
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512,
              let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder().decode(IOSUpdateBlockConfiguration.self, from: data),
              let validated = try? value.validated() else { return IOSUpdateBlockConfiguration() }
        return validated
    }

    static func save(_ configuration: IOSUpdateBlockConfiguration) throws {
        let data = try JSONEncoder().encode(configuration.validated())
        let url = fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var excludedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excludedURL.setResourceValues(values)
    }

    /// Override stale general-settings caches on every start, including system
    /// starts without options. No routing or DNS setting is changed here.
    static func injecting(_ value: IOSUpdateBlockConfiguration, into settings: String) throws -> String {
        var object = ((try? JSONSerialization.jsonObject(with: Data(settings.utf8))) as? [String: Any]) ?? [:]
        object["iosUpdateBlock"] = try value.validated().dictionary
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

struct IOSUpdateBlockSnapshot: Codable, Equatable {
    let session: UInt64
    let configurationID: String
    let configurationGeneration: UInt64
    let revision: UInt64
    let active: Bool
    let enabled: Bool
    let domains: [Domain]
    var coverage: IOSUpdateBlockCoverage?

    struct Domain: Codable, Equatable, Identifiable {
        let domain: String
        let dnsRefused: UInt64
        let connectionsRejected: UInt64
        let lastHitAt: Int64 // Unix milliseconds, shared with the Go snapshot.
        var id: String { domain }
        var lastHit: Date? { lastHitAt > 0 ? Date(timeIntervalSince1970: Double(lastHitAt) / 1000) : nil }
    }

    var hasHits: Bool { domains.contains { $0.dnsRefused > 0 || $0.connectionsRejected > 0 } }
}

struct IOSUpdateBlockCoverage: Codable, Equatable {
    let includeAllNetworks: Bool
    let enforceRoutes: Bool
    let excludeCellularServices: Bool
    let excludeAPNs: Bool
    let excludeDeviceCommunication: Bool
    let ipv6: Bool
}
