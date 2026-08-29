import Foundation
import Mihomo

/// A tiny always-on safety net for the memory-constrained Packet Tunnel.
/// Detailed sampling remains opt-in through developer mode; this listener only
/// reacts to system pressure and never retains diagnostic history.
final class MemoryPressureGuard: @unchecked Sendable {
    private static let minimumActionInterval: TimeInterval = 20

    private let queue = DispatchQueue(label: "com.cora.tunnel.memory-pressure",
                                       qos: .utility)
    private var source: (any DispatchSourceMemoryPressure)?
    private var lastActionUptime: TimeInterval = 0

    func start() {
        queue.sync {
            guard source == nil else { return }
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical], queue: queue)
            source.setEventHandler { [weak self] in
                self?.handlePressureLocked()
            }
            self.source = source
            source.resume()
        }
    }

    func stop() {
        queue.sync {
            source?.setEventHandler {}
            source?.cancel()
            source = nil
            lastActionUptime = 0
        }
    }

    private func handlePressureLocked() {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastActionUptime >= Self.minimumActionInterval else { return }
        lastActionUptime = uptime
        FileLog.write("系统内存压力：执行受限 GC，未启用详细诊断")
        MihomoForceGC()
    }
}
