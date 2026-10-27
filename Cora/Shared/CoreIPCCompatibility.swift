import Foundation

/// Foundation-only wire helpers shared by App, Tunnel and compatibility tests.
enum CoreIPCCompatibility {
    static func providerUpdate(updated: [String], failures: [String: String]) -> [String: Any] {
        ["ok": failures.isEmpty, "updated": updated, "failures": failures]
    }

    static func ruleContent(_ value: [String: Any]) -> [String: Any] {
        var result = value
        if let seconds = value["updatedAtUnix"] as? NSNumber {
            result["updatedAt"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds.doubleValue))
        }
        return result
    }

    static func hello(version: String) -> [String: Any] {
        ["protocolVersion": 1, "coreVersion": version, "engine": "meow-rs",
         "capabilities": ["connections", "logs", "proxies", "runtime", "memory-diagnostics"],
         "udpConnectionDetails": false]
    }

    /// Consume complete UTF-8 lines only. A tail beginning inside a line drops
    /// that first fragment; an unfinished last line is read again next poll.
    static func logLines(_ data: Data, startsInsideLine: Bool, capacity: Int) -> (text: String, consumed: Int) {
        guard let last = data.lastIndex(of: 0x0A) else {
            // Bound a corrupt/oversized line without an ever-growing buffer.
            return ("", data.count >= capacity ? data.count : 0)
        }
        let end = data.index(after: last)
        let start = startsInsideLine ? data.index(after: data.firstIndex(of: 0x0A)!) : data.startIndex
        return (String(decoding: data[start..<end], as: UTF8.self), data.distance(from: data.startIndex, to: end))
    }

    static func resourceTimestamp(_ value: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: value)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: value) else { return nil }
        return formatter.string(from: date)
    }
}
