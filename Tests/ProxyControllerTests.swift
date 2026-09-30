import Foundation

// The real controller and persistence store are compiled below. These fixtures
// replace only the App/NE boundary so the test never starts a VPN or a request.
enum AppGroup {
    static var containerURL: URL?
}

enum TunnelManager {
    enum IPCResult {
        case ok(Data)
        case failure(String)
    }
}

@MainActor
final class CoreStateManager {
    enum Status { case connected, reasserting, disconnected }
    static let shared = CoreStateManager()
    var status = Status.connected
    var reply = TunnelManager.IPCResult.failure("test failure")
    var beforeReply: (() -> Void)?
    var proxyReply = TunnelManager.IPCResult.ok(Data(#"{"mode":"rule","proxies":{"GLOBAL":{"type":"Selector","all":["Group"]},"Group":{"type":"Selector","all":["Alias"],"now":"Alias"},"Alias":{"type":"Selector","all":["node"],"now":"node"}}}"#.utf8))
    var beforeProxyReply: (() -> Void)?
    var proxyQueryCount = 0

    func sendMessage(_ message: [String: Any]) async -> TunnelManager.IPCResult {
        if message["cmd"] as? String == "queryProxies" {
            proxyQueryCount += 1
            beforeProxyReply?()
            return proxyReply
        }
        beforeReply?()
        return reply
    }
}

@MainActor
final class SubscriptionStore {
    struct Subscription {
        let id: UUID
        let yaml: String
        let proxySelections: [String: String]
    }
    static let shared = SubscriptionStore()
    var selected: Subscription?
    var selectedID: UUID? { selected?.id }
    func providerPayloadsJSON(for id: UUID) -> String { "{}" }
    func selectProxyOffline(subscriptionID: UUID, group: String, name: String) {}
}

enum MihomoCore {
    static var offlineReply = Data()
    static func offlineProxySnapshot(configYAML: String, providerPayloadsJSON: String,
                                     selectionsJSON: String) -> Data { offlineReply }
}

@MainActor
final class SettingsStore {
    static let shared = SettingsStore()
    static let defaultDelayTestURL = "https://example.org"
    static let defaultDirectDelayTestURL = "https://example.org"
    let delayTestURL = SettingsStore.defaultDelayTestURL
    let directDelayTestURL = SettingsStore.defaultDirectDelayTestURL
    let delayTestTimeout = 5
    static func effectiveHTTPURL(_ value: String, fallback: String) -> String { value }
}

private enum TestFailure: Error {
    case failed(String)
}

@main
@MainActor
struct ProxyControllerTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cora-proxy-tests-\(UUID().uuidString)")
        AppGroup.containerURL = directory
        defer { try? FileManager.default.removeItem(at: directory) }
        try await testProtocolLabels()
        ProxyDelayStore.beginSession()
        let controller = ProxyController()
        await controller.load()
        try expect(controller.isRuntimeAvailable, "test runtime unavailable")

        let failures: [TunnelManager.IPCResult] = [
            .failure("connection refused"),
            .ok(Data(#"{"error":"request timeout"}"#.utf8)),
            .ok(Data("not JSON".utf8)),
            .ok(Data("{}".utf8)),
            .ok(Data(#"{"delay":0}"#.utf8)),
            .ok(Data(#"{"delay":-1}"#.utf8)),
        ]
        for failure in failures {
            CoreStateManager.shared.reply = .ok(Data(#"{"delay":42}"#.utf8))
            await controller.testNode("Alias", in: "Group")
            try expect(controller.delays["node"] == 42, "successful retry did not restore delay")
            try expect(controller.nodeTestFailure == nil, "retry kept an old toast")

            CoreStateManager.shared.reply = failure
            await controller.testNode("Alias", in: "Group")
            try expect(controller.error == nil, "single-node failure leaked to the page error")
            try expect(controller.delays["node"] == ProxyNodeTestFailure.delayValue,
                       "node returned to untested state on failure")
            try expect(ProxyDelayResolver.delay(for: "Alias", index: controller.resolutionIndex,
                                                delays: controller.delays) == ProxyNodeTestFailure.delayValue,
                       "alias did not show the failed node")
            try expect(ProxyDelayStore.load()?.delays["node"] == ProxyNodeTestFailure.delayValue,
                       "failure was not persisted in the VPN session")
            try expect(controller.testingNodes.isEmpty, "failed node remained loading")
            try expect(controller.nodeTestFailure?.node == "Alias", "toast lost the tested node")
        }

        let oldID = controller.nodeTestFailure!.id
        await controller.testNode("Alias", in: "Group")
        let newID = controller.nodeTestFailure!.id
        try expect(newID != oldID, "repeated failure reused the toast identity")
        controller.dismissNodeTestFailure(id: oldID)
        try expect(controller.nodeTestFailure?.id == newID, "old dismissal cleared a newer toast")
        try await Task.sleep(nanoseconds: 4_300_000_000)
        try expect(controller.nodeTestFailure == nil, "toast did not expire")
        try expect(controller.delays["node"] == ProxyNodeTestFailure.delayValue,
                   "toast expiry cleared the node result")

        // An outstanding response from a stopped VPN must not resurrect a
        // failed node or a toast in the next session.
        CoreStateManager.shared.beforeReply = { controller.resetSession() }
        await controller.testNode("Alias", in: "Group")
        try expect(controller.nodeTestFailure == nil && controller.delays.isEmpty,
                   "old-session response was accepted")
        try expect(controller.testingNodes.isEmpty, "session reset kept a loading indicator")
        print("Node delay: failures, retries, alias mapping, persistence, toast expiry and session reset passed")
    }

    private static func testProtocolLabels() async throws {
        let core = CoreStateManager.shared
        let originalReply = core.proxyReply
        defer {
            core.proxyReply = originalReply
            core.beforeProxyReply = nil
            core.status = .connected
            SubscriptionStore.shared.selected = nil
            MihomoCore.offlineReply = Data()
        }
        let catalog: [String: Any] = [
            "mode": "rule",
            "proxies": [
                "GLOBAL": ["type": "Selector", "all": ["Group", "Alias"]],
                "Group": ["type": "Selector", "now": "SS Node",
                          "all": ["SS Node", "Snell Node", "VLESS Node", "DIRECT", "REJECT", "Alias", "VLESS-like name"]],
                "Alias": ["type": "Selector", "all": ["VLESS Node"], "now": "VLESS Node"],
            ],
        ]
        func snapshot(_ types: Any? = nil) throws -> Data {
            var result = catalog
            result["nodeTypes"] = types
            return try JSONSerialization.data(withJSONObject: result)
        }
        let rawTypes: [String: Any] = [
            "SS Node": " Shadowsocks ", "Snell Node": "sNeLl", "VLESS Node": "Vless",
            "SSR Node": "ssr", "DIRECT": "Direct", "REJECT": "Reject",
            "Drop": "RejectDrop", "HY": "hy2", "Alias": "Vless",
            "Unknown Node": "Unknown", "Future Node": "new-protocol", "Invalid Node": 42,
        ]
        let expected = [
            "SS Node": "SS", "Snell Node": "SNELL", "VLESS Node": "VLESS", "SSR Node": "SSR",
            "DIRECT": "DIRECT", "REJECT": "REJECT", "Drop": "REJECT-DROP", "HY": "HYSTERIA2",
        ]
        let controller = ProxyController()
        core.proxyReply = .ok(try snapshot(rawTypes))
        let before = core.proxyQueryCount
        await controller.load()
        try expect(controller.nodeTypeLabels == expected, "adapter names were not normalized or groups/unknown types leaked")
        try expect(core.proxyQueryCount == before + 1, "node types added an extra IPC request")
        try expect(controller.nodeTypeLabels["VLESS-like name"] == nil, "protocol was guessed from the node name")

        core.proxyReply = .ok(try snapshot(["SS Node": "trojan"]))
        await controller.load()
        try expect(controller.nodeTypeLabels == ["SS Node": "TROJAN"], "configuration replacement kept old types")
        core.proxyReply = .ok(try snapshot())
        await controller.load()
        try expect(controller.nodeTypeLabels.isEmpty && !controller.groups.isEmpty,
                   "legacy response without nodeTypes failed or kept stale labels")
        core.proxyReply = .ok(try snapshot(["SS Node": 12, "Snell Node": "snell"]))
        await controller.load()
        try expect(controller.nodeTypeLabels == ["Snell Node": "SNELL"], "one malformed type discarded valid labels")
        core.proxyReply = .ok(try snapshot(["not a dictionary"]))
        await controller.load()
        try expect(controller.nodeTypeLabels.isEmpty && !controller.groups.isEmpty, "malformed nodeTypes broke the catalog")

        for failure in [TunnelManager.IPCResult.failure("offline"), .ok(Data("not JSON".utf8)), .ok(Data("{}".utf8))] {
            core.proxyReply = .ok(try snapshot(rawTypes))
            await controller.load()
            core.proxyReply = failure
            await controller.load()
            try expect(controller.nodeTypeLabels.isEmpty, "catalog failure kept labels from the previous configuration")
        }

        core.status = .disconnected
        SubscriptionStore.shared.selected = .init(id: UUID(), yaml: "saved config", proxySelections: [:])
        MihomoCore.offlineReply = try snapshot([
            "SS Node": "ss", "Snell Node": "snell", "VLESS Node": "vless", "SSR Node": "shadowsocksr",
            "DIRECT": "direct", "REJECT": "reject", "Drop": "reject-drop", "HY": "hysteria2",
        ])
        let offlineBefore = core.proxyQueryCount
        await controller.load()
        try expect(!controller.isRuntimeAvailable && controller.nodeTypeLabels == expected,
                   "offline YAML aliases disagree with runtime labels")
        try expect(core.proxyQueryCount == offlineBefore, "offline labels requested the NE")
        controller.resetSession()
        try expect(controller.nodeTypeLabels.isEmpty, "session reset kept protocol labels")

        core.status = .connected
        core.proxyReply = .ok(try snapshot(rawTypes))
        core.beforeProxyReply = { controller.resetSession() }
        await controller.load()
        try expect(controller.nodeTypeLabels.isEmpty && controller.groups.isEmpty, "stale catalog resurrected old labels")
        core.beforeProxyReply = nil
        var directCatalog = catalog
        directCatalog["mode"] = "direct"
        directCatalog["nodeTypes"] = rawTypes
        core.proxyReply = .ok(try JSONSerialization.data(withJSONObject: directCatalog))
        await controller.load()
        try expect(controller.nodeTypeLabels.isEmpty, "direct mode kept protocol labels")
        print("Protocol labels: online/offline aliases, built-ins, groups, legacy responses, invalid types, replacement and reset passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure.failed(message) }
    }
}
