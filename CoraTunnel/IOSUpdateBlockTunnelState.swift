import Foundation

/// Immutable effective route information published only after successful
/// startup. It describes NE's current settings, not the App's pending edits.
final class IOSUpdateBlockTunnelState {
    private let lock = NSLock()
    private var coverage: IOSUpdateBlockCoverage?

    func activate(_ coverage: IOSUpdateBlockCoverage) {
        lock.lock()
        self.coverage = coverage
        lock.unlock()
    }

    func reset() {
        lock.lock()
        coverage = nil
        lock.unlock()
    }

    func response(_ coreData: Data?) -> Data {
        lock.lock()
        let current = coverage
        lock.unlock()
        guard let current else { return Data(#"{"error":"VPN 尚未连接，请稍后重试"}"#.utf8) }
        guard let coreData else { return Data(#"{"error":"内核未返回拦截状态"}"#.utf8) }
        guard var snapshot = try? JSONDecoder().decode(IOSUpdateBlockSnapshot.self, from: coreData) else {
            return coreData // Preserve structured Go errors.
        }
        snapshot.coverage = current
        return (try? JSONEncoder().encode(snapshot)) ?? Data(#"{"error":"拦截状态编码失败"}"#.utf8)
    }
}
