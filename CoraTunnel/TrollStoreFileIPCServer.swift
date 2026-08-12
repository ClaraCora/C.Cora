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
            source = watcher
            watcher.resume()
            drainRequests()
            started = true
        }
        return started
    }

    func stop() {
        queue.sync {
            source?.cancel()
            source = nil
        }
    }

    private func drainRequests() {
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
                let request = try Data(contentsOf: processingURL)
                try? FileManager.default.removeItem(at: processingURL)
                handler(request) { response in
                    self.queue.async {
                        do {
                            try (response ?? Data()).write(to: responseURL, options: .atomic)
                        } catch {
                            FileLog.write("TrollStore 文件 IPC 写响应失败：\(error.localizedDescription)")
                        }
                    }
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
}
