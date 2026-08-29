import Foundation

/// NE 侧的单条内存诊断采样。所有字段可选，兼容旧版本或截断的诊断行。
struct MemoryDiagnosticSample: Decodable {
    let t: Int64?
    let event: String?
    let physFootprint: UInt64?
    let sampleCount: UInt64?
    let pressureEvents: UInt64?
    let pressureSuppressed: UInt64?
    let sampleDurationMs: Int64?
    let go: GoRuntimeDiagnostic?

    struct GoRuntimeDiagnostic: Decodable {
        let heapAlloc: UInt64?
        let heapInuse: UInt64?
        let heapReleased: UInt64?
        let heapSys: UInt64?
        let goMemoryLimit: Int64?
        let goGCPercent: Int?
        let goroutines: Int?
        let connections: Int?
        let tcpConnections: Int?
        let udpConnections: Int?
        let proxyProviders: Int?
        let ruleProviders: Int?
        let proxyGroups: Int?
        let delaySlotsInUse: Int?
        let delaySlotLimit: Int?
        let activeDelayBatches: Int?
        let connectionSnapshotBytes: Int64?
        let closedSnapshotBytes: Int64?
        let closedQueuePending: Int?
        let upTotal: Int64?
        let downTotal: Int64?
    }
}

/// App 侧轻量分析器。它只保留最近 512 条已经解码的数字，避免诊断页面本身
/// 因为处理文件而制造新的内存峰值。
enum MemoryDiagnosticAnalyzer {
    private static let maxSamples = 512

    static func analyze(_ text: String) -> String {
        let samples = text.split(whereSeparator: \.isNewline)
            .suffix(maxSamples)
            .compactMap { line -> MemoryDiagnosticSample? in
                guard line.hasPrefix("{") else { return nil }
                return try? JSONDecoder().decode(MemoryDiagnosticSample.self,
                                                  from: Data(line.utf8))
            }
        guard !samples.isEmpty else {
            return "暂无可分析的采样。请开启开发者模式并保持 VPN 运行一段时间后重试。"
        }

        let first = samples.first!
        let last = samples.last!
        let footprintDelta = signedDelta(last.physFootprint, first.physFootprint)
        let heapDelta = signedDelta(last.go?.heapAlloc, first.go?.heapAlloc)
        let inuseDelta = signedDelta(last.go?.heapInuse, first.go?.heapInuse)
        let released = last.go?.heapReleased.map { formatBytes($0) } ?? "未知"
        let memoryLimit = last.go?.goMemoryLimit.map { formatBytes(UInt64(max(0, $0))) } ?? "未知"
        let gcPercent = last.go?.goGCPercent.map { String($0) } ?? "未知"
        let connections = last.go?.connections.map { String($0) } ?? "未知"
        let goroutines = last.go?.goroutines.map { String($0) } ?? "未知"
        let tcp = last.go?.tcpConnections.map { String($0) } ?? "未知"
        let udp = last.go?.udpConnections.map { String($0) } ?? "未知"
        let proxyProviders = last.go?.proxyProviders.map { String($0) } ?? "未知"
        let ruleProviders = last.go?.ruleProviders.map { String($0) } ?? "未知"
        let proxyGroups = last.go?.proxyGroups.map { String($0) } ?? "未知"
        let delaySlots = last.go?.delaySlotsInUse.map { String($0) } ?? "未知"
        let delaySlotLimit = last.go?.delaySlotLimit.map { String($0) } ?? "未知"
        let delayBatches = last.go?.activeDelayBatches.map { String($0) } ?? "未知"
        let snapshotBytes = last.go?.connectionSnapshotBytes.map { formatBytes(UInt64(max(0, $0))) } ?? "未知"
        let closedSnapshotBytes = last.go?.closedSnapshotBytes.map { formatBytes(UInt64(max(0, $0))) } ?? "未知"
        let closedQueuePending = last.go?.closedQueuePending.map { String($0) } ?? "未知"
        let lastEvent = last.event ?? "未知"
        let duration = durationText(from: first.t, to: last.t)
        let pressure = last.pressureEvents.map { String($0) } ?? "未知"
        let pressureSuppressed = last.pressureSuppressed.map { String($0) } ?? "未知"
        let sampleDuration = last.sampleDurationMs.map { "\($0)ms" } ?? "未知"

        var findings: [String] = []
        if let value = last.go?.connections, value > 0,
           let initial = first.go?.connections, value >= initial + 8 {
            findings.append("连接数量持续偏高，优先检查连接残留或连接池未及时回收。")
        }
        if heapDelta >= 8 * 1024 * 1024 || inuseDelta >= 8 * 1024 * 1024 {
            findings.append("Go 堆活跃对象明显增加，重点排查 GEO/ASN、DNS 缓存、Provider 或规则结构。")
        }
        if footprintDelta >= 8 * 1024 * 1024 && heapDelta < 3 * 1024 * 1024 {
            findings.append("物理内存增加但 Go 堆变化较小，更像 gVisor/sing 缓冲池或其他原生内存高水位。")
        }
        if let value = last.go?.goroutines, let initial = first.go?.goroutines,
           value >= initial + 10 {
            findings.append("goroutine 数量持续增加，存在后台任务未退出的风险。")
        }
        if let providers = last.go?.proxyProviders, providers > 0,
           let initial = first.go?.proxyProviders, providers > initial {
            findings.append("节点 Provider 数量在采样期间增加，Provider 内容可能推动 Go 堆增长。")
        }
        if let providers = last.go?.ruleProviders, providers > 0,
           let initial = first.go?.ruleProviders, providers > initial {
            findings.append("规则 Provider 数量在采样期间增加，规则数据加载可能推动 Go 堆增长。")
        }
        if let pressureSuppressed = last.pressureSuppressed, pressureSuppressed > 0 {
            findings.append("检测到重复内存压力事件；其中 \(pressureSuppressed) 次按冷却策略合并处理，避免诊断触发 GC 风暴。")
        }
        if findings.isEmpty {
            findings.append("当前采样没有显示单一类别持续增长；请在测速前后各保持几分钟再分析。")
        }

        return [
            "采样 \(samples.count) 条 · \(duration)",
            "最新事件：\(lastEvent)",
            "物理内存：\(formatBytes(last.physFootprint ?? 0))（变化 \(signedSize(footprintDelta))）",
            "Go 堆 Alloc：\(formatBytes(last.go?.heapAlloc ?? 0))（变化 \(signedSize(heapDelta))）",
            "Go 堆 Inuse：\(formatBytes(last.go?.heapInuse ?? 0))（变化 \(signedSize(inuseDelta))）",
            "Go 已归还：\(released)",
            "Go GC 目标：\(memoryLimit)，GOGC=\(gcPercent)%",
            "连接：\(connections)（TCP \(tcp) / UDP \(udp)）",
            "Provider：节点 \(proxyProviders) / 规则 \(ruleProviders)，策略组 \(proxyGroups)",
            "测速资源：并发槽位 \(delaySlots)/\(delaySlotLimit)，活动批次 \(delayBatches)",
            "连接快照：活动 \(snapshotBytes)，关闭队列 \(closedSnapshotBytes)，待释放 \(closedQueuePending) 条",
            "goroutine：\(goroutines)",
            "诊断压力事件：\(pressure)（冷却合并 \(pressureSuppressed)），最近采样耗时：\(sampleDuration)",
            "",
            "判断：",
            findings.map { "• \($0)" }.joined(separator: "\n")
        ].joined(separator: "\n")
    }

    private static func signedDelta(_ end: UInt64?, _ start: UInt64?) -> Int64 {
        guard let end = end, let start = start else { return 0 }
        if end >= start { return Int64(min(end - start, UInt64(Int64.max))) }
        return -Int64(min(start - end, UInt64(Int64.max)))
    }

    private static func signedSize(_ value: Int64) -> String {
        let prefix = value >= 0 ? "+" : "-"
        let magnitude = value == Int64.min ? Int64.max : abs(value)
        return prefix + formatBytes(UInt64(magnitude))
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteFormat.size(Int64(min(bytes, UInt64(Int64.max))))
    }

    private static func durationText(from start: Int64?, to end: Int64?) -> String {
        guard let start = start, let end = end, end >= start else { return "时长未知" }
        let seconds = (end - start) / 1_000
        if seconds < 60 { return "覆盖 \(seconds) 秒" }
        return "覆盖 \(seconds / 60) 分钟"
    }
}
