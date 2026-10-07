import Foundation

private func expect(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

@main
struct TrollStoreIPCRequestPolicyTests {
    static func main() {
        expect(TrollStoreIPCRequestPolicy.acceptsRequestSize(0), "empty request should be allowed")
        expect(TrollStoreIPCRequestPolicy.acceptsRequestSize(Int64(TrollStoreIPCRequestPolicy.maximumRequestBytes)),
               "request limit should be inclusive")
        expect(!TrollStoreIPCRequestPolicy.acceptsRequestSize(-1), "negative request size should be rejected")
        expect(!TrollStoreIPCRequestPolicy.acceptsRequestSize(
            Int64(TrollStoreIPCRequestPolicy.maximumRequestBytes) + 1),
               "oversized request should be rejected")
        expect(TrollStoreIPCRequestPolicy.acceptsPendingRequestCount(
            TrollStoreIPCRequestPolicy.maximumPendingRequests - 1),
               "last available pending slot should be accepted")
        expect(!TrollStoreIPCRequestPolicy.acceptsPendingRequestCount(
            TrollStoreIPCRequestPolicy.maximumPendingRequests),
               "pending request limit should be enforced")
        expect(!TrollStoreIPCRequestPolicy.acceptsPendingRequestCount(-1),
               "negative pending count should be rejected")
        expect(TrollStoreIPCRequestPolicy.maximumPendingRequests >= 8 + 24,
               "transport capacity reduced the scheduler queue")
        expect(TrollStoreIPCRequestPolicy.maximumRequestLifetime >= 190,
               "transport lifetime truncated long batch delay requests")
        print("TrollStore IPC request policy tests passed")
    }
}
