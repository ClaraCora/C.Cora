import Foundation

enum AppGroup { static var containerURL: URL? }
enum TunnelManager { enum IPCResult { case ok(Data), failure(String) } }
enum TestVPNStatus { case connected, reasserting, disconnected, connecting }

@MainActor
final class CoreStateManager {
    static let shared = CoreStateManager()
    var status = TestVPNStatus.disconnected
    var connectionEpoch: UInt64 = 1
    var configuration = IOSUpdateBlockConfiguration()
    var session: UInt64 = 1_800_000_000_000_000_123
    var revision: UInt64 = 1
    var hits: UInt64 = 0
    var failTransport = false
    var commands: [String] = []
    var pauseNextRead = false
    var paused: CheckedContinuation<Void, Never>?

    func sendMessage(_ command: [String: Any]) async -> TunnelManager.IPCResult {
        let name = command["cmd"] as? String ?? ""
        commands.append(name)
        if failTransport { return .failure("test failure") }
        if name == "configureIOSUpdateBlock", let json = command["configuration"] as? String {
            configuration = try! JSONDecoder().decode(IOSUpdateBlockConfiguration.self, from: Data(json.utf8))
            revision += 1
        }
        if name == "resetIOSUpdateBlockStats" { hits = 0; revision += 1 }
        let snapshot = IOSUpdateBlockSnapshot(session: session, configurationID: configuration.id,
            configurationGeneration: revision, revision: revision, active: true, enabled: configuration.enabled,
            domains: [.init(domain: "mesu.apple.com", dnsRefused: hits, connectionsRejected: 0, lastHitAt: hits == 0 ? 0 : 1234)], coverage: nil)
        let data = try! JSONEncoder().encode(snapshot)
        if name == "iosUpdateBlockStatus", pauseNextRead {
            pauseNextRead = false
            await withCheckedContinuation { paused = $0 }
        }
        return .ok(data)
    }
}

@main
@MainActor
struct IOSUpdateBlockTests {
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "IOSUpdateBlockTests", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cora-update-tests-\(UUID())")
        AppGroup.containerURL = directory
        defer { try? FileManager.default.removeItem(at: directory) }
        try expect(!IOSUpdateBlockStorage.load().enabled, "must default off")
        let saved = IOSUpdateBlockConfiguration(id: "persistence", enabled: true)
        try IOSUpdateBlockStorage.save(saved)
        try expect(IOSUpdateBlockStorage.load() == saved, "settings did not persist")
        let settings = try IOSUpdateBlockStorage.injecting(saved, into: #"{"ipv6":true,"iosUpdateBlock":{"id":"old","enabled":false}}"#)
        let object = try JSONSerialization.jsonObject(with: Data(settings.utf8)) as! [String: Any]
        try expect(object["ipv6"] as? Bool == true && (object["iosUpdateBlock"] as? [String: Any])?["id"] as? String == "persistence", "startup changed routing or reused stale settings")
        for id in ["", "bad/domain", "测试", String(repeating: "a", count: 65)] {
            try expect((try? IOSUpdateBlockConfiguration(id: id, enabled: true).validated()) == nil, "accepted bad id")
        }

        let store = IOSUpdateBlockStore()
        let core = CoreStateManager.shared
        await store.setEnabled(true)
        try expect(core.commands.isEmpty && store.summary == "等待 VPN", "offline save performed IPC or claimed enabled")
        core.status = .connected
        await store.refresh()
        try expect(!store.isSynchronized && store.message != nil, "unapplied setting claimed enabled")
        await store.retry()
        try expect(store.isSynchronized && store.summary == "已启用", "acknowledged setting did not sync")
        let configurationID = store.configuration.id
        let count = core.commands.count
        core.hits = 5
        core.revision += 1
        await store.refresh()
        try expect(core.commands.count == count + 1 && core.commands.last == "iosUpdateBlockStatus" &&
                   core.configuration.id == configurationID && store.snapshot?.hasHits == true, "refresh mutated settings or probed the network")
        await store.resetStats()
        try expect(store.configuration.enabled && store.snapshot?.hasHits == false, "reset disabled feature or retained counts")

        core.pauseNextRead = true
        let oldRead = Task { await store.refresh() }
        while core.paused == nil { await Task.yield() }
        await store.setEnabled(false)
        core.paused?.resume(); core.paused = nil
        await oldRead.value
        try expect(!store.configuration.enabled && store.snapshot?.enabled == false && store.isSynchronized, "stale pre-toggle poll overwrote acknowledgement")

        core.failTransport = true
        await store.setEnabled(true)
        try expect(IOSUpdateBlockStorage.load().enabled && store.summary == "同步失败" && store.message != nil, "transport failure claimed applied or lost saved choice")
        core.failTransport = false
        await store.retry()
        try expect(store.isSynchronized, "retry failed to reconcile")

        core.pauseNextRead = true
        let oldSession = Task { await store.refresh() }
        while core.paused == nil { await Task.yield() }
        core.status = .disconnected; core.connectionEpoch += 1
        store.connectionChanged()
        core.session = 200; core.status = .connected
        core.paused?.resume(); core.paused = nil
        await oldSession.value
        try expect(store.snapshot == nil, "old tunnel reply survived session change")
        await store.refresh()
        try expect(store.snapshot?.session == 200, "new tunnel session was not accepted")

        core.status = .connecting; core.connectionEpoch += 1
        await store.setEnabled(false)
        let pendingID = store.configuration.id
        core.status = .connected
        await store.applyAfterConnectionIfNeeded()
        try expect(store.isSynchronized && core.configuration.id == pendingID && !core.configuration.enabled,
                   "save made during startup was not applied on connection")
        let reconciledCount = core.commands.count
        await store.applyAfterConnectionIfNeeded()
        try expect(core.commands.count == reconciledCount, "connection callback reconfigured an acknowledged save")

        let ne = IOSUpdateBlockTunnelState()
        let coreData = try JSONEncoder().encode(store.snapshot!)
        try expect((try? JSONDecoder().decode(IOSUpdateBlockSnapshot.self, from: ne.response(coreData))) == nil, "unstarted NE reported active")
        let coverage = IOSUpdateBlockCoverage(includeAllNetworks: false, enforceRoutes: true,
            excludeCellularServices: true, excludeAPNs: true, excludeDeviceCommunication: false, ipv6: true)
        ne.activate(coverage)
        let response = try JSONDecoder().decode(IOSUpdateBlockSnapshot.self, from: ne.response(coreData))
        try expect(response.coverage == coverage && response.session == 200, "actual coverage not attached")
        ne.reset()
        try expect((try? JSONDecoder().decode(IOSUpdateBlockSnapshot.self, from: ne.response(coreData))) == nil, "stopped NE retained effective coverage")
        print("iOS update block persistence, synchronization, session and coverage tests passed")
    }
}
