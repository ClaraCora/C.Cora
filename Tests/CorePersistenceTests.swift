import Foundation

// Snapshot tests deliberately do not link an engine or start a VPN.
enum CoraNativeCore {
    static func failure(_ message: String) -> NSError {
        NSError(domain: "CorePersistenceTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@main
struct CorePersistenceTests {
    static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("cora-persistence-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let source = home.appendingPathComponent("original.yaml")
        let original = Data("# preserve comments\nrules: [\"MATCH,DIRECT\"]\n".utf8)
        try original.write(to: source)
        try expect(try CoreSessionSnapshot.load(home: home) == nil)
        let settings = "{\"profileID\":\"test\",\"ipv6\":true}"
        let snapshot = CoreSessionSnapshot(version: 1, source: String(decoding: original, as: UTF8.self),
                                           settings: settings, runtime: "runtime: first")
        try snapshot.commit(home: home)
        let saved = try CoreSessionSnapshot.load(home: home)!
        precondition(saved.source == snapshot.source && saved.settings == settings && saved.runtime == snapshot.runtime)
        let replacement = CoreSessionSnapshot(version: 1, source: saved.source, settings: settings, runtime: "runtime: second")
        try replacement.commit(home: home)
        try expect(try CoreSessionSnapshot.load(home: home)?.runtime == "runtime: second")
        try expect(try Data(contentsOf: source) == original)

        let download = home.appendingPathComponent("download.bin")
        let target = home.appendingPathComponent("GeoSite.dat")
        try Data("known-good".utf8).write(to: target)
        try Data("invalid".utf8).write(to: download)
        do {
            _ = try CoreAtomicFile.stage(download, fileName: "GeoSite.dat", home: home) { _ in
                throw CoraNativeCore.failure("invalid database")
            }
            preconditionFailure("accepted invalid database")
        } catch {}
        try expect(try Data(contentsOf: target) == Data("known-good".utf8))
        try expect(try Data(contentsOf: download) == Data("invalid".utf8))
        try expect(try fm.contentsOfDirectory(atPath: home.path).allSatisfy { !$0.hasSuffix(".download") })

        try Data("new-valid".utf8).write(to: download)
        let staged = try CoreAtomicFile.stage(download, fileName: "GeoSite.dat", home: home) { candidate in
            try expect(try Data(contentsOf: candidate) == Data("new-valid".utf8))
        }
        try expect(try Data(contentsOf: target) == Data("known-good".utf8))
        try CoreAtomicFile.install(staged, at: target)
        try expect(try Data(contentsOf: target) == Data("new-valid".utf8))
        precondition(!fm.fileExists(atPath: staged.path))
        try expect(try Data(contentsOf: source) == original)
        let newTarget = home.appendingPathComponent("ASN.mmdb")
        let newStaged = try CoreAtomicFile.stage(download, fileName: "ASN.mmdb", home: home) { _ in }
        try CoreAtomicFile.install(newStaged, at: newTarget)
        try expect(try Data(contentsOf: newTarget) == Data("new-valid".utf8))
        print("Core snapshot and atomic GEO persistence tests passed")
    }

    static func expect(_ condition: @autoclosure () throws -> Bool) throws {
        let passed = try condition()
        precondition(passed)
    }
}
