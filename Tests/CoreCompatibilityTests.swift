import Foundation

struct LogLine {
    let time: Date
    let type: String
    let payload: String
}

@main
struct CoreCompatibilityTests {
    static func main() throws {
        let hello = CoreIPCCompatibility.hello(version: "test")
        precondition(hello["protocolVersion"] as? Int == 1)
        precondition(hello["coreVersion"] as? String == "test")
        precondition(hello["udpConnectionDetails"] as? Bool == false)
        _ = try JSONSerialization.data(withJSONObject: hello)
        let chunk = CoreIPCCompatibility.logLines(Data("半行\n完整的一行\n未完".utf8), startsInsideLine: true, capacity: 100)
        precondition(chunk.text == "完整的一行\n")
        precondition(chunk.consumed == Data("半行\n完整的一行\n".utf8).count)
        let partial = CoreIPCCompatibility.logLines(Data("waiting".utf8), startsInsideLine: false, capacity: 100)
        precondition(partial.text.isEmpty && partial.consumed == 0)
        let bounded = CoreIPCCompatibility.logLines(Data(repeating: 65, count: 100), startsInsideLine: false, capacity: 100)
        precondition(bounded.consumed == 100)
        precondition(CoreIPCCompatibility.resourceTimestamp("2026-10-28T01:02:03.123456Z") == "2026-10-28T01:02:03Z")
        precondition(CoreIPCCompatibility.resourceTimestamp("invalid") == nil)
        let refresh = CoreIPCCompatibility.providerUpdate(updated: ["one"], failures: ["two": "download failed"])
        precondition(refresh["ok"] as? Bool == false)
        precondition((refresh["failures"] as? [String: String])?["two"] == "download failed")
        precondition(refresh["updated"] as? [String] == ["one"])
        _ = try JSONSerialization.data(withJSONObject: refresh)
        let rule = CoreIPCCompatibility.ruleContent(["ok": true, "content": "DOMAIN,a.example", "updatedAtUnix": 0])
        precondition(rule["updatedAt"] as? String == "1970-01-01T00:00:00Z")
        let tracing = LogFileTailer.parseLine("2026-10-28T01:02:03.123456Z  WARN meow::dns: failed")
        precondition(tracing.type == "warning" && tracing.payload == "meow::dns: failed")
        let legacy = LogFileTailer.parseLine("2026-10-28T01:02:03.123Z [info] legacy")
        precondition(legacy.type == "info" && legacy.payload == "legacy")
        print("Core compatibility tests passed")
    }
}
