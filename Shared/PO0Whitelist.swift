import Foundation

struct PO0WhitelistConfiguration: Codable, Equatable {
    static let intervals = [1, 3, 5, 10, 15, 30, 60]
    var id = "unconfigured"
    var enabled = false
    var tokens = ""
    var intervalMinutes = 5

    func validated() throws -> Self {
        guard Self.intervals.contains(intervalMinutes), !id.isEmpty, id.utf8.count <= 64,
              tokens.utf8.count <= 3000 else {
            throw PO0SettingsError.invalid("PO0 设置格式不正确")
        }
        let parts = tokens.components(separatedBy: CharacterSet(charactersIn: ",|;、； \t\r\n"))
            .filter { !$0.isEmpty }
        guard parts.count <= 8 else { throw PO0SettingsError.invalid("最多配置 8 个 Token") }
        guard !enabled || !parts.isEmpty else { throw PO0SettingsError.invalid("请先填写 PO0 Token") }
        var seen = Set<String>()
        for part in parts {
            let pair = part.components(separatedBy: "@")
            guard pair.count <= 2,
                  pair[0].range(of: "^pgnfw_[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else {
                throw PO0SettingsError.invalid("Token 应以 pgnfw_ 开头，可在末尾添加 @槽位")
            }
            if pair.count == 2 {
                guard let slot = Int(pair[1]), (0...65535).contains(slot), String(slot) == pair[1] else {
                    throw PO0SettingsError.invalid("槽位应为 0 至 65535 的整数")
                }
            }
            guard seen.insert(pair[0]).inserted else {
                throw PO0SettingsError.invalid("同一个 Token 只能配置一次")
            }
        }
        var result = self
        result.tokens = parts.joined(separator: ",")
        return result
    }

    func json() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

enum PO0SettingsError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

/// Kept separate from subscription exports, logs and general UserDefaults.
/// The shared file supports system/Control Center starts; options + IPC also
/// deliver it to NE's own protected cache when App Group signing is unavailable.
enum PO0WhitelistStorage {
    private static var fileURL: URL {
        let base = AppGroup.containerURL ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                                    in: .userDomainMask)[0]
            .appendingPathComponent("Cora", isDirectory: true)
        return base.appendingPathComponent("PO0", isDirectory: true).appendingPathComponent("configuration.json")
    }

    static func load() -> PO0WhitelistConfiguration {
        let url = fileURL
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096,
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(PO0WhitelistConfiguration.self, from: data),
              let validated = try? value.validated() else { return PO0WhitelistConfiguration() }
        return validated
    }

    static func save(_ configuration: PO0WhitelistConfiguration) throws {
        let configuration = try configuration.validated()
        let url = fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(configuration)
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
}

struct PO0WhitelistSnapshot: Codable {
    let configurationID: String
    let enabled: Bool
    let checking: Bool
    let pending: Bool
    let lastCheckedAt: Double
    let nextCheckAt: Double
    let results: [PO0WhitelistResult]

    var isWorking: Bool { checking || pending }
    var successfulCount: Int { results.filter(\.applied).count }
}

struct PO0WhitelistResult: Codable, Identifiable {
    let index: Int
    let slot: Int?
    let enabled: Bool
    let applied: Bool
    let currentIp: String
    let whitelist: [Entry]
    let limit: Int
    let truncated: Bool
    let error: String?
    var id: Int { index }

    struct Entry: Codable {
        let ip: String
        let slot: Int?
    }

    var title: String {
        if let error, !error.isEmpty { return "检测失败" }
        if !enabled { return "防火墙未启用" }
        return applied ? "已加入白名单" : "加白未生效"
    }
}
