import Foundation

/// NE 侧的单条内存诊断采样。所有字段可选，兼容旧版本或截断的诊断行。
struct MemoryDiagnosticSample: Decodable {
    let v: Int?
    let kind: String?
    let t: Int64?
    let uptimeMs: Int64?
    let session: String?
    let event: String?
    let physFootprint: UInt64?
    let physFootprintPeak: UInt64?
    let availableMemory: UInt64?
    let sampleCount: UInt64?
    let pressureEvents: UInt64?
    let pressureSuppressed: UInt64?
    let sampleDurationMs: Int64?
    let vm: VirtualMemoryDiagnostic?
    let cora: CoraDiagnostic?
    let go: GoRuntimeDiagnostic?

    struct VirtualMemoryDiagnostic: Decodable {
        let virtualSize: UInt64?
        let residentSize: UInt64?
        let residentSizePeak: UInt64?
        let internalSize: UInt64?
        let compressedSize: UInt64?
        let compressedSizePeak: UInt64?
        let reusableSize: UInt64?
        let physFootprintPeak: UInt64?
    }

    struct CoraDiagnostic: Decodable {
        let ipcResponseCount: Int?
        let ipcResponseBytes: UInt64?
        let logBufferedLines: Int?
        let logBufferedBytes: UInt64?
        let logPersistedBytes: UInt64?
    }

    struct GoRuntimeDiagnostic: Decodable {
        let heapAlloc: UInt64?
        let heapObjects: UInt64?
        let heapInuse: UInt64?
        let heapIdle: UInt64?
        let heapReleased: UInt64?
        let heapSys: UInt64?
        let stackInuse: UInt64?
        let stackSys: UInt64?
        let mspanInuse: UInt64?
        let mcacheInuse: UInt64?
        let buckHashSys: UInt64?
        let gcSys: UInt64?
        let otherSys: UInt64?
        let sys: UInt64?
        let totalAlloc: UInt64?
        let mallocs: UInt64?
        let frees: UInt64?
        let nextGC: UInt64?
        let lastGC: UInt64?
        let numGC: UInt64?
        let numForcedGC: UInt64?
        let pauseTotalNs: UInt64?
        let lastPauseNs: UInt64?
        let gcCPUFraction: Double?
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

/// A summary has only numeric first/latest/min/peak values. It remains useful
/// after the detailed NDJSON ring has rotated, while retaining no payloads.
private struct MemoryDiagnosticSummary: Decodable {
    let v: Int?
    let kind: String?
    let session: String?
    let startedAtMs: Int64?
    let updatedAtMs: Int64?
    let sampleCount: UInt64?
    let metrics: [String: Metric]?

    struct Metric: Decodable {
        let first: UInt64?
        let latest: UInt64?
        let minimum: UInt64?
        let peak: UInt64?
        let firstAt: Int64?
        let latestAt: Int64?
        let peakAt: Int64?
    }
}

/// App 侧轻量分析器。它只保留最近 512 条已经解码的数字，避免诊断页面本身
/// 因为处理文件而制造新的内存峰值。
enum MemoryDiagnosticAnalyzer {
    private static let maxSamples = 512

    static func analyze(_ text: String) -> String {
        let decoder = JSONDecoder()
        var samples: [MemoryDiagnosticSample] = []
        var summaries: [MemoryDiagnosticSummary] = []

        // The response contains section headers and may contain a partial first
        // line because the NE returns a bounded UTF-8 tail. Decode each line
        // independently so one truncated line cannot hide the remaining data.
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.first == "{" else { continue }
            let data = Data(line.utf8)
            if let summary = try? decoder.decode(MemoryDiagnosticSummary.self, from: data),
               summary.kind == "summary" {
                summaries.append(summary)
                continue
            }
            guard let sample = try? decoder.decode(MemoryDiagnosticSample.self, from: data),
                  sample.kind != "summary" else { continue }
            samples.append(sample)
            if samples.count > maxSamples {
                samples.removeFirst(samples.count - maxSamples)
            }
        }

        guard !samples.isEmpty || !summaries.isEmpty else {
            return "暂无可分析的采样。请开启开发者模式并保持 VPN 运行一段时间后重试。"
        }

        // Detailed files can contain the previous and current session. Keep
        // deltas within the newest session so a restart is not reported as a
        // leak or an artificial memory drop.
        let samplesForAnalysis: [MemoryDiagnosticSample] = {
            guard let session = samples.last?.session else { return samples }
            let matching = samples.filter { $0.session == session }
            return matching.isEmpty ? samples : matching
        }()
        let first = samplesForAnalysis.first
        let last = samplesForAnalysis.last
        // A response may contain the previous session's summary together with
        // current detailed samples. Prefer a summary from the same session;
        // otherwise do not let stale metrics overwrite the current sample
        // window when the current summary could not be persisted.
        let summary: MemoryDiagnosticSummary? = {
            guard !summaries.isEmpty else { return nil }
            if let session = last?.session {
                return summaries
                    .filter { $0.session == session }
                    .max { summaryTimestamp($0) < summaryTimestamp($1) }
            }
            return summaries.max { summaryTimestamp($0) < summaryTimestamp($1) }
        }()
        let sampleCount = summary?.sampleCount ?? UInt64(samplesForAnalysis.count)
        let duration = durationText(
            from: summary?.startedAtMs ?? first?.t,
            to: summary?.updatedAtMs ?? last?.t)

        let footprint = latest("physFootprint", summary: summary, fallback: last?.physFootprint)
        let footprintDelta = delta("physFootprint", summary: summary,
                                   start: first?.physFootprint, end: last?.physFootprint)
        let footprintPeak = peak("physFootprintPeak", summary: summary,
                                 fallback: samplesForAnalysis.compactMap { $0.physFootprintPeak }.max()
                                     ?? samplesForAnalysis.compactMap(\.physFootprint).max())
        let available = latest("availableMemory", summary: summary,
                               fallback: last?.availableMemory)

        let heapAlloc = latest("heapAlloc", summary: summary, fallback: last?.go?.heapAlloc)
        let heapAllocDelta = delta("heapAlloc", summary: summary,
                                   start: first?.go?.heapAlloc, end: last?.go?.heapAlloc)
        let heapAllocPeak = peak("heapAlloc", summary: summary,
                                 fallback: samplesForAnalysis.compactMap { $0.go?.heapAlloc }.max())
        let heapInuse = latest("heapInuse", summary: summary, fallback: last?.go?.heapInuse)
        let heapInuseDelta = delta("heapInuse", summary: summary,
                                   start: first?.go?.heapInuse, end: last?.go?.heapInuse)
        let heapSys = latest("heapSys", summary: summary, fallback: last?.go?.heapSys)
        let heapIdle = latest("heapIdle", summary: summary, fallback: last?.go?.heapIdle)
        let heapReleased = latest("heapReleased", summary: summary,
                                  fallback: last?.go?.heapReleased)
        let heapObjects = latest("heapObjects", summary: summary,
                                 fallback: last?.go?.heapObjects)
        let heapObjectsDelta = delta("heapObjects", summary: summary,
                                     start: first?.go?.heapObjects, end: last?.go?.heapObjects)
        let stackInuse = latest("stackInuse", summary: summary, fallback: last?.go?.stackInuse)
        let stackSys = latest("stackSys", summary: summary, fallback: last?.go?.stackSys)
        let sys = latest("sys", summary: summary, fallback: last?.go?.sys)
        let totalAlloc = latest("totalAlloc", summary: summary, fallback: last?.go?.totalAlloc)
        let mallocs = latest("mallocs", summary: summary, fallback: last?.go?.mallocs)
        let frees = latest("frees", summary: summary, fallback: last?.go?.frees)
        let numGC = latest("numGC", summary: summary, fallback: last?.go?.numGC)
        let forcedGC = latest("numForcedGC", summary: summary, fallback: last?.go?.numForcedGC)

        let resident = latest("residentSize", summary: summary, fallback: last?.vm?.residentSize)
        let residentPeak = latest("residentSizePeak", summary: summary,
                                  fallback: last?.vm?.residentSizePeak)
        let internal = latest("internalSize", summary: summary, fallback: last?.vm?.internalSize)
        let compressed = latest("compressedSize", summary: summary,
                                fallback: last?.vm?.compressedSize)
        let compressedPeak = latest("compressedSizePeak", summary: summary,
                                    fallback: last?.vm?.compressedSizePeak)
        let reusable = latest("reusableSize", summary: summary, fallback: last?.vm?.reusableSize)
        let virtual = latest("virtualSize", summary: summary, fallback: last?.vm?.virtualSize)

        let connections = latestInt("connections", summary: summary, fallback: last?.go?.connections)
        let tcp = latestInt("tcpConnections", summary: summary, fallback: last?.go?.tcpConnections)
        let udp = latestInt("udpConnections", summary: summary, fallback: last?.go?.udpConnections)
        let goroutines = latestInt("goroutines", summary: summary, fallback: last?.go?.goroutines)
        let proxyProviders = latestInt("proxyProviders", summary: summary,
                                      fallback: last?.go?.proxyProviders)
        let ruleProviders = latestInt("ruleProviders", summary: summary,
                                     fallback: last?.go?.ruleProviders)
        let proxyGroups = latestInt("proxyGroups", summary: summary,
                                    fallback: last?.go?.proxyGroups)
        let delaySlots = latestInt("delaySlotsInUse", summary: summary,
                                   fallback: last?.go?.delaySlotsInUse)
        let delaySlotLimit = latestInt("delaySlotLimit", summary: summary,
                                       fallback: last?.go?.delaySlotLimit)
        let delayBatches = latestInt("activeDelayBatches", summary: summary,
                                     fallback: last?.go?.activeDelayBatches)
        let snapshotBytes = latestSigned("connectionSnapshotBytes", summary: summary,
                                         fallback: last?.go?.connectionSnapshotBytes)
        let closedSnapshotBytes = latestSigned("closedSnapshotBytes", summary: summary,
                                               fallback: last?.go?.closedSnapshotBytes)
        let closedQueuePending = latestInt("closedQueuePending", summary: summary,
                                           fallback: last?.go?.closedQueuePending)

        let ipcBytes = latest("ipcResponseBytes", summary: summary,
                              fallback: last?.cora?.ipcResponseBytes)
        let ipcCount = latestInt("ipcResponseCount", summary: summary,
                                 fallback: last?.cora?.ipcResponseCount)
        let logBufferedBytes = latest("logBufferedBytes", summary: summary,
                                      fallback: last?.cora?.logBufferedBytes)
        let logBufferedLines = latestInt("logBufferedLines", summary: summary,
                                         fallback: last?.cora?.logBufferedLines)
        let logPersistedBytes = latest("logPersistedBytes", summary: summary,
                                       fallback: last?.cora?.logPersistedBytes)
        let gcFraction = last?.go?.gcCPUFraction
        let fallbackMemoryLimit: UInt64? = {
            guard let value = last?.go?.goMemoryLimit, value >= 0 else { return nil }
            return UInt64(value)
        }()
        let memoryLimitValue = latest(
            "goMemoryLimit",
            summary: summary,
            fallback: fallbackMemoryLimit)
        let memoryLimit = formatBytes(memoryLimitValue)
        let gcPercentValue = latestInt("goGCPercent", summary: summary,
                                       fallback: last?.go?.goGCPercent)
        let gcPercent = formatCount(gcPercentValue)
        let pressure = last?.pressureEvents.map { String($0) } ?? "未知"
        let pressureSuppressed = last?.pressureSuppressed.map { String($0) } ?? "未知"
        let lastEvent = last?.event ?? "摘要"
        let sampleDuration = last?.sampleDurationMs.map { "\($0)ms" } ?? "未知"

        var findings: [String] = []
        if let value = connections, value > 0,
           let initial = firstValue("connections", summary: summary,
                                   fallback: first?.go?.connections),
           value >= initial + 8 {
            findings.append("连接数量持续偏高，优先检查连接残留或连接池未及时回收。")
        }
        if heapAllocDelta >= 8 * 1024 * 1024 || heapInuseDelta >= 8 * 1024 * 1024 {
            findings.append("Go 堆活跃对象明显增加，重点排查 GEO/ASN、DNS 缓存、Provider 或规则结构。")
        }
        if heapObjectsDelta >= 10_000 {
            findings.append("Go 堆对象数量持续增加，即使字节数变化不大，也要排查对象/任务是否没有回收。")
        }
        if footprintDelta >= 8 * 1024 * 1024 && heapAllocDelta < 3 * 1024 * 1024 {
            findings.append("物理内存增加但 Go 堆变化较小，更像 gVisor/sing 缓冲池、线程栈或其他原生内存高水位。")
        }
        if let heapSys, let heapAlloc, heapSys > heapAlloc + 16 * 1024 * 1024,
           let released = heapReleased, released < heapSys / 4 {
            findings.append("Go heapSys 明显高于当前 Alloc 且归还比例较低，符合 Go arena/分配器高水位。")
        }
        if let value = goroutines,
           let initial = firstValue("goroutines", summary: summary,
                                   fallback: first?.go?.goroutines),
           value >= initial + 10 {
            findings.append("goroutine 数量持续增加，存在后台任务未退出的风险。")
        }
        if let providers = proxyProviders,
           let initial = firstValue("proxyProviders", summary: summary,
                                   fallback: first?.go?.proxyProviders),
           providers > initial {
            findings.append("节点 Provider 数量在采样期间增加，Provider 内容可能推动 Go 堆增长。")
        }
        if let providers = ruleProviders,
           let initial = firstValue("ruleProviders", summary: summary,
                                   fallback: first?.go?.ruleProviders),
           providers > initial {
            findings.append("规则 Provider 数量在采样期间增加，规则数据加载可能推动 Go 堆增长。")
        }
        if let ipcBytes, ipcBytes > 512 * 1024 {
            findings.append("IPC 分块响应缓存仍有 \(formatBytes(ipcBytes))，检查大响应是否按时消费或过期。")
        }
        if let logBufferedBytes, logBufferedBytes > 64 * 1024 {
            findings.append("NE 日志内存缓冲达到 \(formatBytes(logBufferedBytes))，可能抬高短时内存峰值。")
        }
        if let peak = footprintPeak, let current = footprint,
           peak >= current + 8 * 1024 * 1024 {
            findings.append("物理内存曾达到 \(formatBytes(peak))，当前已回落；更像活动结束后的高水位，不等同于持续泄漏。")
        }
        if findings.isEmpty {
            findings.append("当前采样没有显示单一类别持续增长；请在测速前后各保持几分钟再分析。")
        }

        let vmLine = [
            "常驻 \(formatBytes(resident))",
            "峰值 \(formatBytes(residentPeak))",
            "internal \(formatBytes(internal))",
            "compressed \(formatBytes(compressed))",
            "compressed 峰值 \(formatBytes(compressedPeak))",
            "reusable \(formatBytes(reusable))",
            "virtual \(formatBytes(virtual))",
        ].joined(separator: " / ")
        let goLine = [
            "Alloc \(formatBytes(heapAlloc))",
            "Inuse \(formatBytes(heapInuse))",
            "Sys \(formatBytes(heapSys))",
            "Idle \(formatBytes(heapIdle))",
            "已归还 \(formatBytes(heapReleased))",
        ].joined(separator: " / ")
        let objectLine = [
            "对象 \(formatCount(heapObjects))",
            "栈 Inuse \(formatBytes(stackInuse))",
            "栈 Sys \(formatBytes(stackSys))",
            "Sys 总计 \(formatBytes(sys))",
        ].joined(separator: " / ")
        let allocationLine = [
            "累计分配 \(formatBytes(totalAlloc))",
            "Mallocs \(formatCount(mallocs))",
            "Frees \(formatCount(frees))",
            "GC \(formatCount(numGC))",
            "强制 GC \(formatCount(forcedGC))",
        ].joined(separator: " / ")
        let coraLine = [
            "IPC \(formatCount(ipcCount)) / \(formatBytes(ipcBytes))",
            "日志缓冲 \(formatCount(logBufferedLines)) 行 / \(formatBytes(logBufferedBytes))",
            "持久化日志 \(formatBytes(logPersistedBytes))",
        ].joined(separator: "；")

        return [
            "采样 \(sampleCount) 条 · \(duration)",
            "最新事件：\(lastEvent)",
            "物理内存：\(formatBytes(footprint))（变化 \(signedSize(footprintDelta))，峰值 \(formatBytes(footprintPeak))）",
            "可用内存：\(formatBytes(available))",
            "VM：\(vmLine)",
            "Go 堆：\(goLine)",
            "Go 堆变化：Alloc \(signedSize(heapAllocDelta))，Inuse \(signedSize(heapInuseDelta))，Alloc 峰值 \(formatBytes(heapAllocPeak))",
            "Go 细项：\(objectLine)",
            "分配与 GC：\(allocationLine)",
            "GC 目标：\(memoryLimit)，GOGC=\(gcPercent)，CPU \(formatFraction(gcFraction))",
            "连接：\(formatCount(connections))（TCP \(formatCount(tcp)) / UDP \(formatCount(udp))），goroutine \(formatCount(goroutines))",
            "Provider：节点 \(formatCount(proxyProviders)) / 规则 \(formatCount(ruleProviders))，策略组 \(formatCount(proxyGroups))",
            "测速资源：并发槽位 \(formatCount(delaySlots))/\(formatCount(delaySlotLimit))，活动批次 \(formatCount(delayBatches))",
            "连接快照：活动 \(formatSignedBytes(snapshotBytes))，关闭队列 \(formatSignedBytes(closedSnapshotBytes))，待释放 \(formatCount(closedQueuePending)) 条",
            "IPC/日志缓存：\(coraLine)",
            "诊断压力事件：\(pressure)（冷却合并 \(pressureSuppressed)），最近采样耗时 \(sampleDuration)",
            "",
            "判断：",
            findings.map { "• \($0)" }.joined(separator: "\n"),
        ].joined(separator: "\n")
    }

    private static func summaryTimestamp(_ summary: MemoryDiagnosticSummary) -> Int64 {
        summary.updatedAtMs ?? summary.startedAtMs ?? Int64.min
    }

    private static func metric(_ key: String,
                               summary: MemoryDiagnosticSummary?) -> MemoryDiagnosticSummary.Metric? {
        summary?.metrics?[key]
    }

    private static func latest(_ key: String,
                               summary: MemoryDiagnosticSummary?,
                               fallback: UInt64?) -> UInt64? {
        metric(key, summary: summary)?.latest ?? fallback
    }

    private static func peak(_ key: String,
                             summary: MemoryDiagnosticSummary?,
                             fallback: UInt64?) -> UInt64? {
        metric(key, summary: summary)?.peak ?? fallback
    }

    private static func firstValue(_ key: String,
                                   summary: MemoryDiagnosticSummary?,
                                   fallback: Int?) -> Int? {
        if let value = metric(key, summary: summary)?.first {
            return Int(min(value, UInt64(Int.max)))
        }
        return fallback
    }

    private static func latestInt(_ key: String,
                                  summary: MemoryDiagnosticSummary?,
                                  fallback: Int?) -> Int? {
        if let value = metric(key, summary: summary)?.latest {
            return Int(min(value, UInt64(Int.max)))
        }
        return fallback
    }

    private static func latestSigned(_ key: String,
                                     summary: MemoryDiagnosticSummary?,
                                     fallback: Int64?) -> Int64? {
        if let value = metric(key, summary: summary)?.latest {
            return Int64(min(value, UInt64(Int64.max)))
        }
        return fallback
    }

    private static func delta(_ key: String,
                              summary: MemoryDiagnosticSummary?,
                              start: UInt64?,
                              end: UInt64?) -> Int64 {
        if let value = metric(key, summary: summary),
           let first = value.first, let latest = value.latest {
            return signedDelta(latest, first)
        }
        return signedDelta(end, start)
    }

    private static func signedDelta(_ end: UInt64?, _ start: UInt64?) -> Int64 {
        guard let end, let start else { return 0 }
        if end >= start { return Int64(min(end - start, UInt64(Int64.max))) }
        return -Int64(min(start - end, UInt64(Int64.max)))
    }

    private static func signedSize(_ value: Int64) -> String {
        let prefix = value >= 0 ? "+" : "-"
        let magnitude = value == Int64.min ? Int64.max : abs(value)
        return prefix + formatBytes(UInt64(magnitude))
    }

    private static func formatSignedBytes(_ value: Int64?) -> String {
        guard let value else { return "未知" }
        if value < 0 {
            let magnitude = value == Int64.min ? Int64.max : abs(value)
            return "-" + formatBytes(UInt64(magnitude))
        }
        return formatBytes(UInt64(value))
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteFormat.size(Int64(min(bytes, UInt64(Int64.max))))
    }

    private static func formatBytes(_ bytes: UInt64?) -> String {
        bytes.map { formatBytes($0) } ?? "未知"
    }

    private static func formatCount(_ value: Int?) -> String {
        value.map { String($0) } ?? "未知"
    }

    private static func formatCount(_ value: UInt64?) -> String {
        value.map { String($0) } ?? "未知"
    }

    private static func formatFraction(_ value: Double?) -> String {
        guard let value else { return "未知" }
        return String(format: "%.2f%%", max(0, value) * 100)
    }

    private static func durationText(from start: Int64?, to end: Int64?) -> String {
        guard let start, let end, end >= start else { return "时长未知" }
        let seconds = (end - start) / 1_000
        if seconds < 60 { return "覆盖 \(seconds) 秒" }
        if seconds < 3_600 { return "覆盖 \(seconds / 60) 分钟" }
        return "覆盖 \(seconds / 3_600) 小时 \(seconds % 3_600 / 60) 分钟"
    }
}
