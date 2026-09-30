import Foundation

enum TunnelManager {
    enum IPCResult { case ok(Data), failure(String) }
}

@MainActor
final class CoreStateManager {
    enum Status { case connected, disconnected }
    static let shared = CoreStateManager()
    var status = Status.connected
    var replies: [String: TunnelManager.IPCResult] = [:]
    var commands: [String] = []
    var suspendCommand: String?
    var pending: CheckedContinuation<TunnelManager.IPCResult, Never>?
    var beforeReply: (() -> Void)?

    func sendMessage(_ message: [String: Any]) async -> TunnelManager.IPCResult {
        let command = message["cmd"] as? String ?? ""
        commands.append(command)
        beforeReply?()
        if command == suspendCommand {
            return await withCheckedContinuation { pending = $0 }
        }
        return replies[command] ?? .failure("test IPC failure")
    }

    func resume(_ result: TunnelManager.IPCResult) {
        let continuation = pending
        pending = nil
        suspendCommand = nil
        continuation?.resume(returning: result)
    }
}

@main
struct KernelControllerMemoryTests {
    @MainActor
    static func main() async {
        let core = CoreStateManager.shared
        let controller = KernelController()
        let success = TunnelManager.IPCResult.ok(Data(#"{"ok":true,"before":40000000,"physFootprint":30000000}"#.utf8))
        core.replies["releaseMemory"] = success
        let result = await controller.releaseMemory()
        precondition(result == .released(before: 40_000_000, after: 30_000_000))
        precondition(controller.memoryFootprint == 30_000_000 && !controller.isReleasingMemory)
        precondition(core.commands == ["releaseMemory"], "manual release added unrelated commands")

        core.replies["releaseMemory"] = .ok(Data(#"{"ok":false,"error":"刚刚已释放，请稍后再试"}"#.utf8))
        let cooldown = await controller.releaseMemory()
        precondition(cooldown == .failure("刚刚已释放，请稍后再试"))
        precondition(controller.memoryFootprint == 30_000_000, "failure overwrote displayed memory")
        core.replies["releaseMemory"] = .failure("IPC 超时")
        let timeout = await controller.releaseMemory()
        precondition(timeout == .failure("IPC 超时") && !controller.isReleasingMemory)
        core.replies["releaseMemory"] = .ok(Data("invalid JSON".utf8))
        if case .failure = await controller.releaseMemory() {} else { preconditionFailure("accepted malformed JSON") }

        core.status = .disconnected
        let count = core.commands.count
        if case .failure = await controller.releaseMemory() {} else { preconditionFailure("accepted disconnected action") }
        precondition(core.commands.count == count)
        core.status = .connected
        core.suspendCommand = "releaseMemory"
        let first = Task { await controller.releaseMemory() }
        await waitForPending()
        precondition(controller.isReleasingMemory)
        let duplicated = await controller.releaseMemory()
        precondition(duplicated == .failure("正在释放，请稍候"), "duplicate action was not blocked")
        controller.stop()
        core.resume(success)
        let stale = await first.value
        precondition(stale == .superseded && controller.memoryFootprint == nil, "old session GC response leaked")

        // A delayed ordinary poll must not undo the freshly collected value.
        core.suspendCommand = "memory"
        let oldPoll = Task { await controller.refreshMemory() }
        await waitForPending()
        core.replies["releaseMemory"] = success
        let released = await controller.releaseMemory()
        precondition(released == .released(before: 40_000_000, after: 30_000_000))
        core.resume(.ok(Data(#"{"physFootprint":42000000}"#.utf8)))
        _ = await oldPoll.value
        precondition(controller.memoryFootprint == 30_000_000, "stale poll overwrote GC result")
        controller.stop()
        print("Kernel memory release tests passed")
    }

    @MainActor
    private static func waitForPending() async {
        for _ in 0..<100 {
            if CoreStateManager.shared.pending != nil { return }
            await Task.yield()
        }
        preconditionFailure("mock request did not suspend")
    }
}
