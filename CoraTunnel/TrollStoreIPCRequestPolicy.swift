import Foundation

/// Bounds applied before a TrollStore file IPC request is loaded into memory.
/// The control protocol normally uses only a few kilobytes; the larger limit
/// leaves room for a 256-target delay request with long node names while still
/// preventing an unbounded file from becoming an NE allocation.
enum TrollStoreIPCRequestPolicy {
    static let maximumRequestBytes = 256 * 1_024
    // Include both eight executing jobs and the scheduler's 24 waiting jobs.
    static let maximumPendingRequests = 32
    // Batch delay tests can run for three minutes and Provider IPC allows
    // 120 seconds. Transport cleanup must not truncate those existing calls.
    static let maximumRequestLifetime: TimeInterval = 240

    static func acceptsRequestSize(_ byteCount: Int64) -> Bool {
        byteCount >= 0 && byteCount <= Int64(maximumRequestBytes)
    }

    static func acceptsPendingRequestCount(_ pending: Int) -> Bool {
        pending >= 0 && pending < maximumPendingRequests
    }
}
