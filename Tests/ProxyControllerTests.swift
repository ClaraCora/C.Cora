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

    func sendMessage(_ message: [String: Any]) async -> TunnelManager.IPCResult {
        if message["cmd"] as? String == "queryProxies" {
            return .ok(Data(#"{"mode":"rule","proxies":{"GLOBAL":{"type":"Selector","all":["Group"]},"Group":{"type":"Selector","all":["Alias"],"now":"Alias"},"Alias":{"type":"Selector","all":["node"],"now":"node"}}}"#.utf8))
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
    var selected: Subscription? { nil }
    var selectedID: UUID? { nil }
    func providerPayloadsJSON(for id: UUID) -> String { "{}" }
    func selectProxyOffline(subscriptionID: UUID, group: String, name: String) {}
}

enum MihomoCore {
    static func offlineProxySnapshot(configYAML: String, providerPayloadsJSON: String,
                                     selectionsJSON: String) -> Data { Data() }
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

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure.failed(message) }
    }
}
