import Foundation

@main
struct MemoryDiagnosticAnalyzerTests {
    static func main() {
        let legacy = #"{"t":1,"session":"old","event":"sample","physFootprint":30000000,"go":{"heapAlloc":10000000,"proxyGroups":20}}"#
        let legacyReport = MemoryDiagnosticAnalyzer.analyze(legacy)
        precondition(legacyReport.contains("策略组 未知"), "legacy all-proxy count mislabeled")
        precondition(legacyReport.contains("最近释放对比：暂无"), "invented a release")
        let start = #"{"t":10,"session":"current","event":"manualMemoryReleaseStart","physFootprint":33554432,"go":{"heapAlloc":12582912,"bufferPoolRetainedBytes":1048832}}"#
        let end = #"{"t":11,"session":"current","event":"manualMemoryReleaseEnd","physFootprint":31457280,"go":{"heapAlloc":10485760,"bufferPoolRetainedBytes":0,"fakeIP4":{"storage":"persistent"},"policyGroupCount":3}}"#
        let paired = MemoryDiagnosticAnalyzer.analyze(start + "\n" + end)
        precondition(paired.contains("32.00 MB → 30.00 MB"), "release not paired")
        precondition(paired.contains("持久化（未扫描条目）"), "persistent database counted as zero")
        precondition(paired.contains("缓冲池/队列与 Go 堆重叠"), "missing overlap explanation")
        let rotatedSummary = #"{"kind":"summary","session":"current","updatedAtMs":99,"metrics":{},"lastRelease":{"event":"memoryPressure","before":{"physFootprint":33554432,"forceGCSuppressed":0},"after":{"physFootprint":31457280,"forceGCSuppressed":1}}}"#
        let summaryOnly = MemoryDiagnosticAnalyzer.analyze(rotatedSummary)
        precondition(summaryOnly.contains("32.00 MB → 30.00 MB") && summaryOnly.contains("未重复执行 GC"), "summary lost release/cooldown")
        let newSession = end.replacingOccurrences(of: "current", with: "new")
        let restarted = MemoryDiagnosticAnalyzer.analyze(start + "\n" + newSession + "\n" + rotatedSummary)
        precondition(restarted.contains("最近释放对比：暂无"), "paired release across VPN sessions")
        let broken = MemoryDiagnosticAnalyzer.analyze("{bad json\n" + end)
        precondition(broken.contains("策略组 3"), "truncated line hid compatible fields")
        let staleSummary = #"{"kind":"summary","session":"current","updatedAtMs":9,"metrics":{"physFootprint":{"first":33554432,"latest":32505856,"latestAt":9},"tunRXQueuedPackets":{"latest":50,"latestAt":9}},"lastRelease":{"event":"manualMemoryRelease","t":9,"before":{"physFootprint":33554432},"after":{"physFootprint":32505856}}}"#
        let fresher = MemoryDiagnosticAnalyzer.analyze(start + "\n" + end + "\n" + staleSummary)
        precondition(fresher.contains("32.00 MB → 30.00 MB"), "stale summary hid newer release")
        precondition(fresher.contains("物理内存：30.00 MB（变化 -2.00 MB"), "latest and delta disagree")
        precondition(fresher.contains("接收 未知 包"), "unsupported queue revived old count")
        let oldQueue = end.replacingOccurrences(of: #""policyGroupCount":3"#, with: #""policyGroupCount":3,"tunRXQueuedPackets":4"#)
        let cleared = #"{"kind":"summary","session":"current","updatedAtMs":15,"metrics":{"tunRXQueuedPackets":{"first":4,"peak":4,"latestAt":15}}}"#
        let transitioned = MemoryDiagnosticAnalyzer.analyze(oldQueue + "\n" + cleared)
        precondition(transitioned.contains("接收 未知 包"), "cleared latest revived old sample")
        print("MemoryDiagnosticAnalyzerTests passed")
    }
}
