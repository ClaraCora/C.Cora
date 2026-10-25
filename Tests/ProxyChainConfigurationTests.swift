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
        try expect(!chain.enabled && chain.groups.isEmpty, "legacy default is enabled")
        chain.enabled = true
        chain.groups = [
            .init(id: ProxyChainGroup.legacyID, name: "分组 1", enabled: true,
                  upstream: .init(source: "Q", name: "Front"), targets: [inline, provider]),
            .init(name: "分组 2", enabled: true, mode: "custom",
                  yaml: "name: Front\ntype: socks5\nserver: 127.0.0.1\nport: 1080\n",
                  targets: [.init(source: "P", name: "C")])
        ]
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
        changedChain.groups[0].targets = [provider]
        try expect(changedChain.requiresApply(settingsJSON: appliedSettings, subscriptionID: subscriptionID),
                   "changed selection lost pending state")

        let legacyJSON = "{\"enabled\":true,\"mode\":\"existing\",\"upstream\":{\"source\":\"Q\",\"name\":\"Front\"},\"targets\":[{\"source\":\"\",\"name\":\"B\"},{\"source\":\"P\",\"name\":\"B\"}]}"
        let migrated = try JSONDecoder().decode(ProxyChainConfiguration.self, from: Data(legacyJSON.utf8))
        try expect(migrated.groups.count == 1 && migrated.groups[0] == chain.groups[0], "legacy group changed on migration")
        let migratedAgain = try JSONDecoder().decode(ProxyChainConfiguration.self, from: Data(legacyJSON.utf8))
        try expect(migrated == migratedAgain, "legacy migration generated random identity")
        let disabledLegacy = try JSONDecoder().decode(ProxyChainConfiguration.self,
            from: Data(legacyJSON.replacingOccurrences(of: "\"enabled\":true", with: "\"enabled\":false").utf8))
        try expect(!disabledLegacy.enabled && disabledLegacy.groups[0].enabled, "legacy off switch or saved content lost")
        try expect(chain.dictionary["version"] as? Int == 2, "new settings did not encode schema version")
        try expect(chain.dictionary["upstream"] == nil, "legacy single group fields encoded in version 2")
        let legacyEnvelope = String(decoding: try JSONSerialization.data(withJSONObject: [
            "proxyChain": try JSONSerialization.jsonObject(with: Data(legacyJSON.utf8)),
            "subscriptionID": subscriptionID.uuidString
        ]), as: UTF8.self)
        try expect(!migrated.requiresApply(settingsJSON: legacyEnvelope, subscriptionID: subscriptionID),
                   "legacy snapshot migration falsely requires reconnect")

        var presentationOnly = chain
        presentationOnly.groups[0].name = "新组名"
        presentationOnly.groups.reverse()
        presentationOnly.groups[1].targets.reverse()
        presentationOnly.groups[1].yaml = "inactive source text"
        presentationOnly.groups.append(.init(name: "关闭的草稿", targets: [inline]))
        try expect(!presentationOnly.requiresApply(settingsJSON: appliedSettings, subscriptionID: subscriptionID),
                   "display name, ordering or disabled draft falsely requires reconnect")
        var disabledGroup = chain
        disabledGroup.groups[1].enabled = false
        try expect(disabledGroup.requiresApply(settingsJSON: appliedSettings, subscriptionID: subscriptionID),
                   "disabling a group did not require applying")
        var allDisabled = chain
        allDisabled.enabled = false
        try expect(allDisabled.requiresApply(settingsJSON: appliedSettings, subscriptionID: subscriptionID),
                   "master switch did not require applying")
        try expect(allDisabled.activeGroups.isEmpty && allDisabled.groups == chain.groups,
                   "master switch destroyed saved groups")
        var empty = chain
        empty.groups.append(.init(name: "空组", enabled: true))
        try expect(!empty.requiresApply(settingsJSON: appliedSettings, subscriptionID: subscriptionID), "empty group created overlay")
        let owners = chain.targetOwners(excluding: chain.groups[1].id)
        try expect(owners[inline] == "分组 1" && owners[provider] == "分组 1", "occupancy lost exact source")
        let upstreamOwners = chain.upstreamOwners(excluding: chain.groups[1].id)
        try expect(upstreamOwners[chain.groups[0].upstream!] == "分组 1", "upstream occupancy missing")
        disabledGroup.groups[0].enabled = false
        try expect(disabledGroup.targetOwners(excluding: chain.groups[1].id).isEmpty, "disabled group still reserves nodes")
        let conflictJSON = "{\"error\":\"conflict\",\"groupID\":\"\(chain.groups[0].id)\",\"conflictingGroupID\":\"\(chain.groups[1].id)\"}"
        let conflict = try JSONDecoder().decode(ProxyChainValidation.self, from: Data(conflictJSON.utf8))
        try expect(conflict.groupID == chain.groups[0].id && conflict.conflictingGroupID == chain.groups[1].id,
                   "validation lost group locations")

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
        nextChain.groups[0].targets = [provider]
        let secondSettings = String(decoding: try JSONSerialization.data(withJSONObject: ["proxyChain": nextChain.dictionary]), as: UTF8.self)
        let second = RuntimeConfigurationSnapshot(configYAML: "# second\nproxies: []\n", settingsJSON: secondSettings)
        try RuntimeConfigurationSnapshotStorage.save(second, in: directory)
        try expect(RuntimeConfigurationSnapshotStorage.load(in: directory) == second, "new pair not committed together")
        try expect(ProxyChainConfiguration.fromSettings(RuntimeConfigurationSnapshotStorage.settings(in: directory)) == nextChain,
                   "reconnect loaded a different selection")
        try expect(!manager.fileExists(atPath: root.appendingPathComponent("\(uncommitted).yaml").path), "orphaned staging retained")

        try RuntimeConfigurationSnapshotStorage.save(first, in: directory)
        try expect(RuntimeConfigurationSnapshotStorage.load(in: directory) == first, "rollback did not restore both YAML and settings")
        try expect(nextChain.requiresApply(settingsJSON: RuntimeConfigurationSnapshotStorage.settings(in: directory), subscriptionID: nil),
                   "rollback cleared the desired settings' pending state")
        let legacySnapshot = RuntimeConfigurationSnapshot(configYAML: first.configYAML, settingsJSON: legacyEnvelope)
        try RuntimeConfigurationSnapshotStorage.save(legacySnapshot, in: directory)
        try expect(RuntimeConfigurationSnapshotStorage.load(in: directory) == legacySnapshot, "legacy snapshot changed raw data")
        try expect(ProxyChainConfiguration.fromSettings(RuntimeConfigurationSnapshotStorage.settings(in: directory)) == migrated,
                   "system reconnect cannot decode old successful settings")
        try RuntimeConfigurationSnapshotStorage.save(first, in: directory)

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
