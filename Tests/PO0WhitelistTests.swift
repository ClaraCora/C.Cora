import Foundation

enum AppGroup { static var containerURL: URL? }
enum TunnelManager { enum IPCResult { case ok(Data), failure(String) } }

@MainActor
final class CoreStateManager {
    static let shared = CoreStateManager()
    var isActive = true
    var failTransport = false
    var applied = PO0WhitelistConfiguration()
    var applyCount = 0
    var commands: [String] = []
    var rejectRead = false
    var pauseNextStatus = false
    var pausedStatusReply: CheckedContinuation<Void, Never>?
    var simulateReadProgress = false
    var snapshotRefreshing = false
    var refreshedAt: Double = 0

    func sendMessage(_ message: [String: Any]) async -> TunnelManager.IPCResult {
        commands.append(message["cmd"] as? String ?? "")
        if failTransport { return .failure("test transport failure") }
        if rejectRead, message["cmd"] as? String == "refreshPO0Whitelist" {
            return .ok(Data(#"{"error":"设置尚未同步"}"#.utf8))
        }
        if message["cmd"] as? String == "setPO0Whitelist",
           let json = message["configuration"] as? String {
            applied = try! JSONDecoder().decode(PO0WhitelistConfiguration.self, from: Data(json.utf8))
            applyCount += 1
        }
        if simulateReadProgress, message["cmd"] as? String == "refreshPO0Whitelist" {
            snapshotRefreshing = true
        }
        var snapshot = PO0WhitelistSnapshot(
            configurationID: applied.id, enabled: applied.enabled, checking: false, pending: false,
            lastCheckedAt: 0, nextCheckAt: 0, results: [])
        snapshot.refreshing = snapshotRefreshing
        snapshot.lastRefreshedAt = refreshedAt
        let data = try! JSONEncoder().encode(snapshot)
        if pauseNextStatus, message["cmd"] as? String == "po0WhitelistStatus" {
            pauseNextStatus = false
            // Freeze the pre-refresh reply, then deliver it after the read ACK.
            await withCheckedContinuation { pausedStatusReply = $0 }
        }
        return .ok(data)
    }
}

@main
@MainActor
struct PO0WhitelistTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cora-po0-tests-\(UUID())")
        AppGroup.containerURL = directory
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = PO0WhitelistStorage.load()
        try expect(!initial.enabled && initial.intervalMinutes == 5, "default must not send requests")

        var value = initial
        value.enabled = true
        value.tokens = "pgnfw_one@0；pgnfw_two\npgnfw_three"
        value = try value.validated()
        try expect(value.tokens == "pgnfw_one@0,pgnfw_two,pgnfw_three", "token separators not normalized")
        for bad in ["", "wrong", "pgnfw_one@-1", "pgnfw_one@00", "pgnfw_one@65536",
                    "pgnfw_one@a", "pgnfw_one,pgnfw_one@1", "pgnfw_one/path"] {
            var invalid = value
            invalid.tokens = bad
            try expect((try? invalid.validated()) == nil, "invalid token accepted")
        }
        try PO0WhitelistStorage.save(value)
        try expect(PO0WhitelistStorage.load() == value, "configuration did not survive reload")
        let file = directory.appendingPathComponent("PO0/configuration.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "credential file not private")

        let store = PO0WhitelistStore()
        try expect(await store.save(value), "valid settings were not saved")
        try expect(store.configuration.id != "unconfigured", "revision not assigned")
        try expect(store.snapshot?.configurationID == store.configuration.id, "runtime not synchronized")
        let previous = store.configuration
        var invalid = previous
        invalid.tokens = ""
        try expect(!(await store.save(invalid)), "invalid setting accepted")
        try expect(store.configuration == previous && PO0WhitelistStorage.load() == previous,
                   "failed validation overwrote saved settings")
        await store.refresh(force: true)
        try expect(store.validationMessage != nil, "polling cleared the form validation error")
        store.clearValidationMessage()

        CoreStateManager.shared.failTransport = true
        var changed = previous
        changed.intervalMinutes = 10
        try expect(await store.save(changed), "transport failure lost local settings")
        try expect(store.message != nil, "failed sync was silent")
        CoreStateManager.shared.failTransport = false
        await store.refresh(force: true)
        try expect(store.snapshot?.configurationID == store.configuration.id && store.message == nil,
                   "retry did not synchronize the latest revision")

        let wire = Data(#"{"configurationID":"test","enabled":true,"checking":false,"pending":false,"lastCheckedAt":1780000000,"nextCheckAt":1780000300,"results":[{"index":1,"slot":0,"enabled":true,"applied":true,"currentIp":"1.2.3.0/24","whitelist":[{"ip":"1.2.3.0/24","slot":0}],"limit":5,"truncated":false}]}"#.utf8)
        let snapshot = try JSONDecoder().decode(PO0WhitelistSnapshot.self, from: wire)
        try expect(snapshot.successfulCount == 1 && snapshot.results[0].title == "当前出口已在白名单", "Go status contract mismatch")
        let result = snapshot.results[0]
        try expect(result.isCurrentExit(.init(ip: "1.2.3.99", slot: nil)), "current /24 did not match exact entry")
        try expect(result.isCurrentExit(.init(ip: "1.2.3.0/24", slot: 0)), "current subnet not marked")
        try expect(!result.isCurrentExit(.init(ip: "1.2.4.0/24", slot: nil)), "wrong network marked current")
        try expect(!result.isCurrentExit(.init(ip: "999.2.3.4", slot: nil)), "invalid address marked current")
        let exact = try JSONDecoder().decode(PO0WhitelistResult.self, from: Data(#"{"index":1,"enabled":true,"applied":false,"currentIp":"1.2.3.4","whitelist":[],"limit":5,"truncated":false,"readOnly":true}"#.utf8))
        try expect(!exact.isCurrentExit(.init(ip: "1.2.3.5", slot: nil)), "two exact IPs matched by subnet")
        try expect(exact.isCurrentExit(.init(ip: "1.2.3.0/24", slot: nil)), "entry /24 did not match current IP")
        try expect(exact.title == "当前出口未在白名单", "read-only miss described as failed addition")
        var off = store.configuration
        off.enabled = false
        try expect(await store.save(off), "disable failed")
        try expect(store.snapshot?.enabled == false && store.summary == "未开启", "disabled state incorrect")
        let applyCount = CoreStateManager.shared.applyCount
        CoreStateManager.shared.commands = []
        await store.refreshReadOnly()
        try expect(CoreStateManager.shared.commands == ["refreshPO0Whitelist"], "read-only request used a mutation command")
        try expect(CoreStateManager.shared.applyCount == applyCount, "read-only request reconfigured automation")
        CoreStateManager.shared.rejectRead = true
        CoreStateManager.shared.commands = []
        await store.refreshReadOnly()
        try expect(CoreStateManager.shared.commands == ["refreshPO0Whitelist"] && store.readOnlyMessage != nil,
                   "rejected query fell back to adding or failed silently")
        CoreStateManager.shared.rejectRead = false
        CoreStateManager.shared.pauseNextStatus = true
        let delayedPoll = Task { await store.refresh(force: true) }
        for _ in 0..<200 {
            if CoreStateManager.shared.pausedStatusReply != nil { break }
            await Task.yield()
        }
        try expect(CoreStateManager.shared.pausedStatusReply != nil, "status poll did not pause")
        CoreStateManager.shared.simulateReadProgress = true
        await store.refreshReadOnly()
        try expect(store.snapshot?.refreshing == true, "read acknowledgement not shown")
        CoreStateManager.shared.pausedStatusReply?.resume()
        CoreStateManager.shared.pausedStatusReply = nil
        await delayedPoll.value
        try expect(store.snapshot?.refreshing == true, "older poll overwrote new read progress")
        CoreStateManager.shared.snapshotRefreshing = false
        CoreStateManager.shared.refreshedAt = 123
        await store.refresh(force: true)
        try expect(store.snapshot?.lastRefreshedAt == 123 && store.snapshot?.refreshing == false,
                   "read completion was not published with automation disabled")
        print("PO0 settings: validation, protected persistence, IPC sync/retry and status decoding passed")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw PO0SettingsError.invalid(message) }
    }
}
