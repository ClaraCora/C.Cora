import Foundation

enum AppGroup { static var containerURL: URL? }

@main
struct ProxyChainConfigurationTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "ProxyChainTests", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("cora-chain-tests-\(UUID())")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        AppGroup.containerURL = directory
        defer { try? manager.removeItem(at: directory) }

        let inline = ProxyChainReference(source: "", name: "B")
        let provider = ProxyChainReference(source: "P", name: "B")
        try expect(inline != provider && inline.id != provider.id, "same-name sources collapsed")
        try expect(ProxyChainReference(source: "a", name: "bc").id != ProxyChainReference(source: "ab", name: "c").id,
                   "reference IDs collide")
        var chain = ProxyChainConfiguration()
        try expect(!chain.enabled && chain.targets.isEmpty, "legacy default is enabled")
        chain.enabled = true
        chain.upstream = .init(source: "Q", name: "Front")
        chain.targets = [inline, provider]
        let decoded = try JSONDecoder().decode(ProxyChainConfiguration.self, from: Data(chain.json.utf8))
        try expect(decoded == chain, "settings did not survive serialization")
        try expect(ProxyChainConfiguration.fromSettings("{\"logLevel\":\"info\"}") == .init(), "old settings failed migration")
        try expect(ProxyChainConfiguration.fromSettings("{\"proxyChain\":{}}") == .init(), "partial settings did not retain disabled defaults")
        try expect(ProxyChainConfiguration.fromSettings("{\"proxyChain\":{\"enabled\":false,\"targets\":null}}") == .init(), "null optional settings failed migration")
        let settingsData = try JSONSerialization.data(withJSONObject: ["proxyChain": chain.dictionary])
        let settings = String(decoding: settingsData, as: UTF8.self)
        try expect(ProxyChainConfiguration.fromSettings(settings) == chain, "settings envelope lost selection")
        try expect(!ProxyChainConfiguration().requiresApply(settingsJSON: nil, subscriptionID: nil),
                   "empty configuration falsely requires applying")
        try expect(!ProxyChainConfiguration().requiresApply(settingsJSON: "{\"subscriptionID\":\"\"}", subscriptionID: nil),
                   "empty subscription ID falsely requires applying")
        let subscriptionID = UUID()
        let appliedSettings = String(decoding: try JSONSerialization.data(withJSONObject: [
            "subscriptionID": subscriptionID.uuidString.lowercased(), "proxyChain": chain.dictionary
        ]), as: UTF8.self)
        try expect(!chain.requiresApply(settingsJSON: appliedSettings, subscriptionID: subscriptionID),
                   "applied settings or UUID casing falsely require applying")
        try expect(chain.requiresApply(settingsJSON: appliedSettings, subscriptionID: UUID()),
                   "configuration switch lost pending state")
        var changedChain = chain
        changedChain.targets = [provider]
        try expect(changedChain.requiresApply(settingsJSON: appliedSettings, subscriptionID: subscriptionID),
                   "changed selection lost pending state")

        let first = RuntimeConfigurationSnapshot(configYAML: "# original bytes\r\nproxies: []\r\n", settingsJSON: settings)
        try RuntimeConfigurationSnapshotStorage.save(first, in: directory)
        try expect(RuntimeConfigurationSnapshotStorage.load(in: directory) == first, "snapshot changed raw YAML")
        let root = directory.appendingPathComponent("RuntimeConfiguration")
        let firstFiles = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for file in firstFiles where UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            let attributes = try manager.attributesOfItem(atPath: file.path)
            try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "credential snapshot is not private")
        }

        // Simulate a failed start that staged files but never committed its
        // manifest. A system reconnect must still read the successful pair.
        let uncommitted = UUID().uuidString
        try "bad YAML".write(to: root.appendingPathComponent("\(uncommitted).yaml"), atomically: true, encoding: .utf8)
        try "bad settings".write(to: root.appendingPathComponent("\(uncommitted).json"), atomically: true, encoding: .utf8)
        try expect(RuntimeConfigurationSnapshotStorage.load(in: directory) == first, "uncommitted start poisoned reconnect")

        var nextChain = chain
        nextChain.targets = [provider]
        let secondSettings = String(decoding: try JSONSerialization.data(withJSONObject: ["proxyChain": nextChain.dictionary]), as: UTF8.self)
        let second = RuntimeConfigurationSnapshot(configYAML: "# second\nproxies: []\n", settingsJSON: secondSettings)
        try RuntimeConfigurationSnapshotStorage.save(second, in: directory)
        try expect(RuntimeConfigurationSnapshotStorage.load(in: directory) == second, "new pair not committed together")
        try expect(ProxyChainConfiguration.fromSettings(RuntimeConfigurationSnapshotStorage.settings(in: directory)) == nextChain,
                   "reconnect loaded a different selection")
        try expect(!manager.fileExists(atPath: root.appendingPathComponent("\(uncommitted).yaml").path), "orphaned staging retained")

        try RuntimeConfigurationSnapshotStorage.save(first, in: directory)
        try expect(RuntimeConfigurationSnapshotStorage.load(in: directory) == first, "rollback did not restore both YAML and settings")
        try expect(nextChain != ProxyChainConfiguration.fromSettings(RuntimeConfigurationSnapshotStorage.settings(in: directory)),
                   "rollback cleared the desired settings' pending state")

        // Permission failures must leave the last successful manifest intact.
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        var rejected = false
        do { try RuntimeConfigurationSnapshotStorage.save(second, in: directory) } catch { rejected = true }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try expect(rejected, "read-only snapshot directory accepted a write")
        try expect(RuntimeConfigurationSnapshotStorage.load(in: directory) == first, "failed write replaced successful pair")
        print("Proxy chain configuration and reconnect snapshot tests passed")
    }
}
