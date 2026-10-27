import Foundation

/// A single atomic commit prevents a crash from pairing one successful source
/// with another generation's settings. It is never a subscription source file.
struct CoreSessionSnapshot: Codable {
    let version: Int
    let source: String
    let settings: String
    let runtime: String

    static func load(home: URL) throws -> CoreSessionSnapshot? {
        let url = home.appendingPathComponent("meow-last-success.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw CoraNativeCore.failure("不支持的成功配置快照版本") }
        return value
    }

    func commit(home: URL) throws {
        try JSONEncoder().encode(self).write(to: home.appendingPathComponent("meow-last-success.json"), options: .atomic)
    }
}
