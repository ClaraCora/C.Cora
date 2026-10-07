import Foundation

// Test-only paths let the real server exercise its filesystem watcher without
// requiring a TrollStore-signed App Group container on the macOS CI runner.
enum TrollStoreIPC {
    static let isEnabled = true
    static var directoryURL: URL?
    static var afterCleanup: (() -> Void)?

    static func requestURL(for id: UUID) -> URL? {
        directoryURL?.appendingPathComponent("\(id.uuidString).request")
    }
    static func processingURL(for id: UUID) -> URL? {
        directoryURL?.appendingPathComponent("\(id.uuidString).processing")
    }
    static func responseURL(for id: UUID) -> URL? {
        directoryURL?.appendingPathComponent("\(id.uuidString).response")
    }
    static func requestID(from url: URL) -> UUID? {
        guard url.pathExtension == "request" else { return nil }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }
    static func removeAllFiles() {
        guard let directoryURL else { return }
        for file in (try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
        afterCleanup?()
    }
}

enum FileLog {
    static func write(_ message: String) { print(message) }
}

private func expect(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

private func waitFor(_ semaphore: DispatchSemaphore, _ message: String) {
    expect(semaphore.wait(timeout: .now() + 3) == .success, message)
}

private func waitForFile(_ url: URL) -> Data? {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        if let data = try? Data(contentsOf: url) { return data }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return nil
}

@main
struct TrollStoreFileIPCServerTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cora-file-ipc-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        TrollStoreIPC.directoryURL = directory
        defer { try? FileManager.default.removeItem(at: directory) }
        try startupDoesNotCallHandlerSynchronously()
        try stoppedServerDiscardsLateReply()
        print("TrollStore file IPC lifecycle tests passed")
    }

    static func startupDoesNotCallHandlerSynchronously() throws {
        let lifecycleQueue = DispatchQueue(label: "test.tunnel.lifecycle")
        let id = UUID()
        let request = Data(#"{"v":1,"cmd":"hello"}"#.utf8)
        let started = DispatchSemaphore(value: 0)
        let handled = DispatchSemaphore(value: 0)
        let response = Data(#"{"ok":true}"#.utf8)
        let server = TrollStoreFileIPCServer { payload, reply in
            lifecycleQueue.sync {
                expect(payload == request, "request bytes changed")
                handled.signal()
                reply(response)
            }
        }
        // A request arriving during watcher setup exposes a synchronous
        // drainRequests -> handler -> lifecycleQueue.sync lock inversion.
        TrollStoreIPC.afterCleanup = {
            try! request.write(to: TrollStoreIPC.requestURL(for: id)!, options: .atomic)
        }
        lifecycleQueue.async {
            expect(server.start(), "watcher failed to start")
            started.signal()
        }
        waitFor(started, "server.start deadlocked the lifecycle queue")
        waitFor(handled, "initial request was not handled")
        expect(waitForFile(TrollStoreIPC.responseURL(for: id)!) == response,
               "initial response was lost")
        server.stop()
        TrollStoreIPC.afterCleanup = nil
    }

    static func stoppedServerDiscardsLateReply() throws {
        let id = UUID()
        let handled = DispatchSemaphore(value: 0)
        let replies = DispatchQueue(label: "test.file-ipc.replies")
        var lateReply: ((Data?) -> Void)?
        let server = TrollStoreFileIPCServer { _, reply in
            replies.sync { lateReply = reply }
            handled.signal()
        }
        expect(server.start(), "second watcher failed to start")
        try Data(#"{"v":1,"cmd":"runtime"}"#.utf8)
            .write(to: TrollStoreIPC.requestURL(for: id)!, options: .atomic)
        waitFor(handled, "filesystem request was not handled")
        server.stop()
        replies.sync { lateReply?(Data(#"{"ok":true}"#.utf8)); lateReply = nil }
        // stop's second barrier drains finishRequest, which is queued by reply.
        server.stop()
        expect(!FileManager.default.fileExists(atPath: TrollStoreIPC.responseURL(for: id)!.path),
               "old server wrote a response after its session ended")
    }
}
