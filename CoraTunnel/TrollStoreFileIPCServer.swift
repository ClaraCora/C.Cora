import Foundation
import Darwin

/// Watches the TrollStore shared directory and forwards each request to the
/// Packet Tunnel's existing command handler. Atomic rename claims each request,
/// so a filesystem event can never execute the same command twice.
final class TrollStoreFileIPCServer {
    typealias Handler = (Data, @escaping (Data?) -> Void) -> Void

    private let handler: Handler
    private let queue = DispatchQueue(label: "com.cora.tunnel.file-ipc",
                                      qos: .userInitiated)
    private var source: DispatchSourceFileSystemObject?
    private var pendingRequests = 0
    private var generation: UInt64 = 0
    private var timeouts: [UUID: DispatchSourceTimer] = [:]

    private static let oversizedRequestResponse = Data(
        #"{"ok":false,"error":"TrollStore IPC 请求过大"}"#.utf8)
    private static let busyResponse = Data(
        #"{"ok":false,"error":"TrollStore IPC 请求过多，请稍后重试"}"#.utf8)
    private static let invalidRequestResponse = Data(
        #"{"ok":false,"error":"TrollStore IPC 请求无效"}"#.utf8)
    private static let timeoutResponse = Data(
        #"{"ok":false,"error":"TrollStore IPC 请求超时"}"#.utf8)
    init(handler: @escaping Handler) {
        self.handler = handler
    }

    @discardableResult
    func start() -> Bool {
        guard TrollStoreIPC.isEnabled,
              let directory = TrollStoreIPC.directoryURL else { return false }

        var started = false
        queue.sync {
            guard source == nil else {
                started = true
                return
            }
            // Requests belong to one provider process. Never replay commands
            // left by an extension that was killed or updated.
            TrollStoreIPC.removeAllFiles()
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { return }

            let watcher = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename],
                queue: queue)
            watcher.setEventHandler { [weak self] in
                self?.drainRequests()
            }
            watcher.setCancelHandler {
                close(descriptor)
            }
            generation &+= 1
            source = watcher
            watcher.resume()
            // start() may be called while the provider's lifecycle queue is
            // held. Handlers can need that queue, so never invoke one from
            // this synchronous setup block.
            queue.async { [weak self] in self?.drainRequests() }
            started = true
        }
        return started
    }

    func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            generation &+= 1
            for timer in timeouts.values { timer.setEventHandler {}; timer.cancel() }
            timeouts.removeAll()
            pendingRequests = 0
        }
    }

    private func drainRequests() {
        guard source != nil else { return }
        guard let directory = TrollStoreIPC.directoryURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { return }

        for requestURL in files {
            guard let id = TrollStoreIPC.requestID(from: requestURL),
                  let processingURL = TrollStoreIPC.processingURL(for: id),
                  let responseURL = TrollStoreIPC.responseURL(for: id) else { continue }
            do {
                try FileManager.default.moveItem(at: requestURL, to: processingURL)
                // Reject before touching the file payload when all control
                // slots are occupied; this keeps a burst of requests from
                // creating avoidable Data allocations in the NE.
                guard TrollStoreIPCRequestPolicy.acceptsPendingRequestCount(pendingRequests) else {
                    try? FileManager.default.removeItem(at: processingURL)
                    writeResponse(Self.busyResponse, to: responseURL)
                    continue
                }
                let request: Data
                do {
                    request = try readBoundedRequest(at: processingURL)
                } catch RequestReadError.oversized {
                    try? FileManager.default.removeItem(at: processingURL)
                    writeResponse(Self.oversizedRequestResponse, to: responseURL)
                    continue
                } catch {
                    try? FileManager.default.removeItem(at: processingURL)
                    writeResponse(Self.invalidRequestResponse, to: responseURL)
                    continue
                }
                try? FileManager.default.removeItem(at: processingURL)
                pendingRequests += 1
                let gate = ReplyGate()
                let requestGeneration = generation
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + TrollStoreIPCRequestPolicy.maximumRequestLifetime)
                timer.setEventHandler { [weak self] in
                    self?.finishRequest(id: id, generation: requestGeneration, gate: gate,
                                        responseURL: responseURL, response: Self.timeoutResponse)
                }
                timeouts[id] = timer
                timer.resume()
                handler(request) { [weak self] response in
                    self?.finishRequest(id: id, generation: requestGeneration, gate: gate,
                                        responseURL: responseURL, response: response ?? Data())
                }

            } catch {
                // Another directory event may observe a request already claimed
                // by this queue. Only log errors while the source file still exists.
                if FileManager.default.fileExists(atPath: requestURL.path) {
                    FileLog.write("TrollStore 文件 IPC 读请求失败：\(error.localizedDescription)")
                    try? FileManager.default.removeItem(at: requestURL)
                }
            }
        }
    }

    private enum RequestReadError: Error {
        case oversized
    }

    private func readBoundedRequest(at url: URL) throws -> Data {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { try? handle.close() }
        let limit = TrollStoreIPCRequestPolicy.maximumRequestBytes
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        if data.count > limit {
            throw RequestReadError.oversized
        }
        return data
    }

    private func writeResponse(_ response: Data, to url: URL) {
        do {
            try response.write(to: url, options: .atomic)
        } catch {
            FileLog.write("TrollStore 文件 IPC 写响应失败：\(error.localizedDescription)")
        }
    }

    private func finishRequest(id: UUID, generation expectedGeneration: UInt64,
                               gate: ReplyGate, responseURL: URL, response: Data) {
        queue.async {
            guard gate.claim() else { return }
            guard self.source != nil, expectedGeneration == self.generation else { return }
            if let timer = self.timeouts.removeValue(forKey: id) {
                timer.setEventHandler {}
                timer.cancel()
            }
            self.pendingRequests = max(0, self.pendingRequests - 1)
            self.writeResponse(response, to: responseURL)
            // A request may have arrived while the previous command was
            // running. Re-scan after freeing its slot because a filesystem
            // event is not guaranteed for an already observed snapshot.
            self.drainRequests()
        }
    }

    private final class ReplyGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
