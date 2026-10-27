import Foundation

/// Rust has no Go garbage collector. Memory pressure is recorded by the
/// bounded diagnostic stream; no fake collection result is reported.
final class MemoryPressureGuard: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.cora.tunnel.memory-pressure", qos: .utility)
    private var source: (any DispatchSourceMemoryPressure)?
    private weak var diagnostics: MemoryDiagnostics?
    init(diagnostics: MemoryDiagnostics? = nil) { self.diagnostics = diagnostics }
    func start() {
        queue.sync {
            guard source == nil else { return }
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
            source.setEventHandler { [weak self] in
                self?.diagnostics?.record(event: "memoryPressure")
                FileLog.write("系统内存压力：已记录 Rust 运行态，不执行伪 GC")
            }
            self.source = source; source.resume()
        }
    }
    func stop() {
        queue.sync { source?.setEventHandler {}; source?.cancel(); source = nil }
    }
}
