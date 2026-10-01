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
        let ipcResponseMemoryBytes: UInt64?
        let ipcResponseFileBytes: UInt64?
        let logBufferedLines: Int?
        let logBufferedBytes: UInt64?
        let logPersistedBytes: UInt64?
    }

    struct FakeIPDiagnostic: Decodable {
        let storage: String?
        let entries: Int?
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
        let mihomoBufferPoolBuffers: Int?
        let mihomoBufferPoolBytes: UInt64?
        let mihomoBufferPoolMaxBytes: UInt64?
        let singBufferPoolBuffers: Int?
        let singBufferPoolBytes: UInt64?
        let singBufferPoolMaxBytes: UInt64?
        let bufferPoolRetainedBytes: UInt64?
        let bufferPoolLastTrimBytes: UInt64?
        let bufferPoolTrimmedBytes: UInt64?
        let proxyCount: Int?
        let policyGroupCount: Int?
        let proxyProviderNodes: Int?
        let ruleProviderRules: Int?
        let dnsCacheEntries: Int?
        let dnsCacheCount: Int?
        let dnsMappingEntries: Int?
        let fakeIP4: FakeIPDiagnostic?
        let fakeIP6: FakeIPDiagnostic?
        let tunRXQueuedPackets: Int?
        let tunRXQueuedBytes: UInt64?
        let tunTXQueuedPackets: Int?
        let tunTXQueuedBytes: UInt64?
        let geoMode: String?
        let geoLoader: String?
        let geoSiteMatcher: String?
        let geoIPFileBytes: UInt64?
        let geoSiteFileBytes: UInt64?
        let mmdbFileBytes: UInt64?
        let asnFileBytes: UInt64?
        let forceGCSuppressed: UInt64?
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
    let lastRelease: ReleaseComparison?

    struct ReleaseComparison: Decodable {
        let event: String?
        let t: Int64?
        let before: [String: UInt64]?
        let after: [String: UInt64]?
    }

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
        let sampleCount = max(summary?.sampleCount ?? 0,
                              last?.sampleCount ?? UInt64(samplesForAnalysis.count))
        let duration = durationText(
            from: summary?.startedAtMs ?? first?.t,
            to: [summary?.updatedAtMs, last?.t].compactMap { $0 }.max())

        let footprint = latest("physFootprint", summary: summary, fallback: last?.physFootprint, sampleTime: last?.t)
        let footprintDelta = delta("physFootprint", summary: summary,
                                   start: first?.physFootprint, end: last?.physFootprint, endTime: last?.t)
        let footprintPeak = peak("physFootprintPeak", summary: summary,
                                 fallback: samplesForAnalysis.compactMap { $0.physFootprintPeak }.max()
                                     ?? samplesForAnalysis.compactMap(\.physFootprint).max())
        let available = latest("availableMemory", summary: summary,
                               fallback: last?.availableMemory, sampleTime: last?.t)

        let heapAlloc = latest("heapAlloc", summary: summary, fallback: last?.go?.heapAlloc, sampleTime: last?.t)
        let heapAllocDelta = delta("heapAlloc", summary: summary,
                                   start: first?.go?.heapAlloc, end: last?.go?.heapAlloc, endTime: last?.t)
        let heapAllocPeak = peak("heapAlloc", summary: summary,
                                 fallback: samplesForAnalysis.compactMap { $0.go?.heapAlloc }.max())
        let heapInuse = latest("heapInuse", summary: summary, fallback: last?.go?.heapInuse, sampleTime: last?.t)
        let heapInuseDelta = delta("heapInuse", summary: summary,
                                   start: first?.go?.heapInuse, end: last?.go?.heapInuse, endTime: last?.t)
        let heapSys = latest("heapSys", summary: summary, fallback: last?.go?.heapSys, sampleTime: last?.t)
        let heapIdle = latest("heapIdle", summary: summary, fallback: last?.go?.heapIdle, sampleTime: last?.t)
        let heapReleased = latest("heapReleased", summary: summary,
                                  fallback: last?.go?.heapReleased, sampleTime: last?.t)
        let heapObjects = latest("heapObjects", summary: summary,
                                 fallback: last?.go?.heapObjects, sampleTime: last?.t)
        let heapObjectsDelta = delta("heapObjects", summary: summary,
                                     start: first?.go?.heapObjects, end: last?.go?.heapObjects, endTime: last?.t)
        let stackInuse = latest("stackInuse", summary: summary, fallback: last?.go?.stackInuse, sampleTime: last?.t)
        let stackSys = latest("stackSys", summary: summary, fallback: last?.go?.stackSys, sampleTime: last?.t)
        let gcSys = latest("gcSys", summary: summary, fallback: last?.go?.gcSys, sampleTime: last?.t)
        let sys = latest("sys", summary: summary, fallback: last?.go?.sys, sampleTime: last?.t)
        let totalAlloc = latest("totalAlloc", summary: summary, fallback: last?.go?.totalAlloc, sampleTime: last?.t)
        let mallocs = latest("mallocs", summary: summary, fallback: last?.go?.mallocs, sampleTime: last?.t)
        let frees = latest("frees", summary: summary, fallback: last?.go?.frees, sampleTime: last?.t)
        let numGC = latest("numGC", summary: summary, fallback: last?.go?.numGC, sampleTime: last?.t)
        let forcedGC = latest("numForcedGC", summary: summary, fallback: last?.go?.numForcedGC, sampleTime: last?.t)

        let resident = latest("residentSize", summary: summary, fallback: last?.vm?.residentSize, sampleTime: last?.t)
        let residentPeak = latest("residentSizePeak", summary: summary,
                                  fallback: last?.vm?.residentSizePeak, sampleTime: last?.t)
        let internalSize = latest("internalSize", summary: summary,
                                  fallback: last?.vm?.internalSize, sampleTime: last?.t)
        let compressed = latest("compressedSize", summary: summary,
                                fallback: last?.vm?.compressedSize, sampleTime: last?.t)
        let compressedPeak = latest("compressedSizePeak", summary: summary,
                                    fallback: last?.vm?.compressedSizePeak, sampleTime: last?.t)
        let reusable = latest("reusableSize", summary: summary, fallback: last?.vm?.reusableSize, sampleTime: last?.t)
        let virtual = latest("virtualSize", summary: summary, fallback: last?.vm?.virtualSize, sampleTime: last?.t)

        let connections = latestInt("connections", summary: summary, fallback: last?.go?.connections, sampleTime: last?.t)
        let tcp = latestInt("tcpConnections", summary: summary, fallback: last?.go?.tcpConnections, sampleTime: last?.t)
        let udp = latestInt("udpConnections", summary: summary, fallback: last?.go?.udpConnections, sampleTime: last?.t)
        let goroutines = latestInt("goroutines", summary: summary, fallback: last?.go?.goroutines, sampleTime: last?.t)
        let proxyProviders = latestInt("proxyProviders", summary: summary,
                                      fallback: last?.go?.proxyProviders, sampleTime: last?.t)
        let ruleProviders = latestInt("ruleProviders", summary: summary,
                                     fallback: last?.go?.ruleProviders, sampleTime: last?.t)
        // Older NE used proxyGroups for all proxies; do not call that a
        // measured policy-group count when the new accurate field is absent.
        let policyGroups = latestInt("policyGroupCount", summary: summary,
                                     fallback: last?.go?.policyGroupCount, sampleTime: last?.t)
        let proxies = latestInt("proxyCount", summary: summary,
                                fallback: last?.go?.proxyCount ?? last?.go?.proxyGroups, sampleTime: last?.t)
        let providerNodes = latestInt("proxyProviderNodes", summary: summary,
                                      fallback: last?.go?.proxyProviderNodes, sampleTime: last?.t)
        let providerRules = latestInt("ruleProviderRules", summary: summary,
                                      fallback: last?.go?.ruleProviderRules, sampleTime: last?.t)
        let dnsEntries = latestInt("dnsCacheEntries", summary: summary,
                                   fallback: last?.go?.dnsCacheEntries, sampleTime: last?.t)
        let dnsCaches = latestInt("dnsCacheCount", summary: summary,
                                  fallback: last?.go?.dnsCacheCount, sampleTime: last?.t)
        let mappingEntries = latestInt("dnsMappingEntries", summary: summary,
                                       fallback: last?.go?.dnsMappingEntries, sampleTime: last?.t)
        let rxPackets = latestInt("tunRXQueuedPackets", summary: summary,
                                  fallback: last?.go?.tunRXQueuedPackets, sampleTime: last?.t)
        let rxBytes = latest("tunRXQueuedBytes", summary: summary,
                             fallback: last?.go?.tunRXQueuedBytes, sampleTime: last?.t)
        let txPackets = latestInt("tunTXQueuedPackets", summary: summary,
                                  fallback: last?.go?.tunTXQueuedPackets, sampleTime: last?.t)
        let txBytes = latest("tunTXQueuedBytes", summary: summary,
                             fallback: last?.go?.tunTXQueuedBytes, sampleTime: last?.t)
        let delaySlots = latestInt("delaySlotsInUse", summary: summary,
                                   fallback: last?.go?.delaySlotsInUse, sampleTime: last?.t)
        let delaySlotLimit = latestInt("delaySlotLimit", summary: summary,
                                       fallback: last?.go?.delaySlotLimit, sampleTime: last?.t)
        let delayBatches = latestInt("activeDelayBatches", summary: summary,
                                     fallback: last?.go?.activeDelayBatches, sampleTime: last?.t)
        let snapshotBytes = latestSigned("connectionSnapshotBytes", summary: summary,
                                         fallback: last?.go?.connectionSnapshotBytes, sampleTime: last?.t)
        let closedSnapshotBytes = latestSigned("closedSnapshotBytes", summary: summary,
                                               fallback: last?.go?.closedSnapshotBytes, sampleTime: last?.t)
        let closedQueuePending = latestInt("closedQueuePending", summary: summary,
                                           fallback: last?.go?.closedQueuePending, sampleTime: last?.t)
        let mihomoPoolBuffers = latestInt("mihomoBufferPoolBuffers", summary: summary,
                                          fallback: last?.go?.mihomoBufferPoolBuffers, sampleTime: last?.t)
        let mihomoPoolBytes = latest("mihomoBufferPoolBytes", summary: summary,
                                     fallback: last?.go?.mihomoBufferPoolBytes, sampleTime: last?.t)
        let mihomoPoolMaxBytes = latest("mihomoBufferPoolMaxBytes", summary: summary,
                                        fallback: last?.go?.mihomoBufferPoolMaxBytes, sampleTime: last?.t)
        let singPoolBuffers = latestInt("singBufferPoolBuffers", summary: summary,
                                        fallback: last?.go?.singBufferPoolBuffers, sampleTime: last?.t)
        let singPoolBytes = latest("singBufferPoolBytes", summary: summary,
                                   fallback: last?.go?.singBufferPoolBytes, sampleTime: last?.t)
        let singPoolMaxBytes = latest("singBufferPoolMaxBytes", summary: summary,
                                      fallback: last?.go?.singBufferPoolMaxBytes, sampleTime: last?.t)
        let poolRetainedBytes = latest("bufferPoolRetainedBytes", summary: summary,
                                       fallback: last?.go?.bufferPoolRetainedBytes, sampleTime: last?.t)
        let poolLastTrimBytes = latest("bufferPoolLastTrimBytes", summary: summary,
                                       fallback: last?.go?.bufferPoolLastTrimBytes, sampleTime: last?.t)
        let poolTrimmedBytes = latest("bufferPoolTrimmedBytes", summary: summary,
                                      fallback: last?.go?.bufferPoolTrimmedBytes, sampleTime: last?.t)

        let ipcBytes = latest("ipcResponseBytes", summary: summary,
                              fallback: last?.cora?.ipcResponseBytes, sampleTime: last?.t)
        let ipcMemoryBytes = latest("ipcResponseMemoryBytes", summary: summary,
                                    fallback: last?.cora?.ipcResponseMemoryBytes, sampleTime: last?.t) ?? ipcBytes
        let ipcFileBytes = latest("ipcResponseFileBytes", summary: summary,
                                  fallback: last?.cora?.ipcResponseFileBytes, sampleTime: last?.t)
        let ipcCount = latestInt("ipcResponseCount", summary: summary,
                                 fallback: last?.cora?.ipcResponseCount, sampleTime: last?.t)
        let logBufferedBytes = latest("logBufferedBytes", summary: summary,
                                      fallback: last?.cora?.logBufferedBytes, sampleTime: last?.t)
        let logBufferedLines = latestInt("logBufferedLines", summary: summary,
                                         fallback: last?.cora?.logBufferedLines, sampleTime: last?.t)
        let logPersistedBytes = latest("logPersistedBytes", summary: summary,
                                       fallback: last?.cora?.logPersistedBytes, sampleTime: last?.t)
        let gcFraction = last?.go?.gcCPUFraction
        let fallbackMemoryLimit: UInt64? = {
            guard let value = last?.go?.goMemoryLimit, value >= 0 else { return nil }
            return UInt64(value)
        }()
        let memoryLimitValue = latest(
            "goMemoryLimit",
            summary: summary,
            fallback: fallbackMemoryLimit, sampleTime: last?.t)
        let memoryLimit = formatBytes(memoryLimitValue)
        let gcPercentValue = latestInt("goGCPercent", summary: summary,
                                       fallback: last?.go?.goGCPercent, sampleTime: last?.t)
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
            findings.append("物理内存增加但 Go 堆变化较小，需结合 Go 空闲页、栈、VM 和 IPC 缓存进一步归因；gVisor/sing 的 Go 缓冲也包含在 Go 堆内。")
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
        if let ipcBytes = ipcMemoryBytes, ipcBytes > 512 * 1024 {
            findings.append("IPC 分块响应缓存仍有 \(formatBytes(ipcBytes))，检查大响应是否按时消费或过期。")
        }
        if let poolRetainedBytes, poolRetainedBytes > 512 * 1024 {
            findings.append("Mihomo/sing 大块缓冲池保留 \(formatBytes(poolRetainedBytes))；可在内存压力或手动释放后观察是否回落。")
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
            "internal \(formatBytes(internalSize))",
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
            "GC 元数据 \(formatBytes(gcSys))",
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
            "IPC \(formatCount(ipcCount)) / \(formatBytes(ipcBytes))（内存 \(formatBytes(ipcMemoryBytes))，临时文件 \(formatBytes(ipcFileBytes))）",
            "日志缓冲 \(formatCount(logBufferedLines)) 行 / \(formatBytes(logBufferedBytes))",
            "持久化日志 \(formatBytes(logPersistedBytes))",
        ].joined(separator: "；")
        let bufferPoolLine = [
            "Mihomo \(formatCount(mihomoPoolBuffers)) / \(formatBytes(mihomoPoolBytes))（最大闲置块 \(formatBytes(mihomoPoolMaxBytes))）",
            "sing \(formatCount(singPoolBuffers)) / \(formatBytes(singPoolBytes))（最大闲置块 \(formatBytes(singPoolMaxBytes))）",
            "保留 \(formatBytes(poolRetainedBytes))",
            "最近释放 \(formatBytes(poolLastTrimBytes))",
            "累计释放 \(formatBytes(poolTrimmedBytes))",
        ].joined(separator: "；")

        let fake4 = fakeIPText(last?.go?.fakeIP4,
                               entries: latestInt("fakeIP4Entries", summary: summary,
                                                  fallback: last?.go?.fakeIP4?.entries, sampleTime: last?.t))
        let fake6 = fakeIPText(last?.go?.fakeIP6,
                               entries: latestInt("fakeIP6Entries", summary: summary,
                                                  fallback: last?.go?.fakeIP6?.entries, sampleTime: last?.t))
        let geoFiles = [
            "GeoIP \(formatBytes(latest("geoIPFileBytes", summary: summary, fallback: last?.go?.geoIPFileBytes, sampleTime: last?.t)))",
            "GeoSite \(formatBytes(latest("geoSiteFileBytes", summary: summary, fallback: last?.go?.geoSiteFileBytes, sampleTime: last?.t)))",
            "MMDB \(formatBytes(latest("mmdbFileBytes", summary: summary, fallback: last?.go?.mmdbFileBytes, sampleTime: last?.t)))",
            "ASN \(formatBytes(latest("asnFileBytes", summary: summary, fallback: last?.go?.asnFileBytes, sampleTime: last?.t)))",
        ].joined(separator: " / ")
        let releaseLine = releaseComparisonText(summary: summary, samples: samplesForAnalysis)

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
            "Provider：节点 \(formatCount(proxyProviders)) 个 / 条目合计 \(formatCount(providerNodes))，规则 \(formatCount(ruleProviders)) 个 / 规则合计 \(formatCount(providerRules))",
            "代理目录：\(formatCount(proxies)) 项，策略组 \(formatCount(policyGroups)) 个（Provider 条目可能重复）",
            "DNS：\(formatCount(dnsEntries)) 条 / \(formatCount(dnsCaches)) 份独立缓存，域名映射 \(formatCount(mappingEntries)) 条；Fake-IP v4 \(fake4) / v6 \(fake6)",
            "TUN 等待队列：接收 \(formatCount(rxPackets)) 包 / \(formatBytes(rxBytes))，发送 \(formatCount(txPackets)) 包 / \(formatBytes(txBytes))（包长度，不含处理中的批次）",
            "GEO：\(last?.go?.geoMode ?? "未知") / \(last?.go?.geoLoader ?? "未知") / \(last?.go?.geoSiteMatcher ?? "未知")；磁盘资产 \(geoFiles)",
            "测速资源：并发槽位 \(formatCount(delaySlots))/\(formatCount(delaySlotLimit))，活动批次 \(formatCount(delayBatches))",
            "连接快照：活动 \(formatSignedBytes(snapshotBytes))，关闭队列 \(formatSignedBytes(closedSnapshotBytes))，待释放 \(formatCount(closedQueuePending)) 条",
            "大块缓冲池：\(bufferPoolLine)",
            "IPC/日志缓存：\(coraLine)",
            "来源说明：缓冲池/队列与 Go 堆重叠；DNS、Fake-IP、Provider 是条目数，GEO 是磁盘大小，不能相加为物理内存。",
            releaseLine,
            "诊断压力事件：\(pressure)（冷却合并 \(pressureSuppressed)），最近采样耗时 \(sampleDuration)",
            "",
            "判断：",
            findings.map { "• \($0)" }.joined(separator: "\n"),
        ].joined(separator: "\n")
    }

    private static func fakeIPText(_ cache: MemoryDiagnosticSample.FakeIPDiagnostic?,
                                   entries: Int?) -> String {
        if cache?.storage == "persistent" { return "持久化（未扫描条目）" }
        guard let entries else { return "未采集" }
        return "\(entries) 条（内存映射）"
    }

    private static func releaseComparisonText(summary: MemoryDiagnosticSummary?,
                                              samples: [MemoryDiagnosticSample]) -> String {
        var before = summary?.lastRelease?.before
        var after = summary?.lastRelease?.after
        var event = summary?.lastRelease?.event
        var pairTime = summary?.lastRelease?.t ?? summary?.updatedAtMs ?? Int64.min
        do {
            // Prefer a newer complete detailed pair if summary persistence failed.
            // Do not pair across sessions or across unrelated release events.
            var pending: MemoryDiagnosticSample?
            for sample in samples {
                switch sample.event {
                case "manualMemoryReleaseStart", "memoryPressure": pending = sample
                case "manualMemoryReleaseEnd", "memoryPressureEnd":
                    let expected = sample.event == "memoryPressureEnd" ? "memoryPressure" : "manualMemoryReleaseStart"
                    if let start = pending, start.event == expected, start.session == sample.session,
                       before == nil || after == nil || (sample.t ?? Int64.min) >= pairTime {
                        pairTime = sample.t ?? Int64.min
                        before = releaseMetrics(start)
                        after = releaseMetrics(sample)
                        event = sample.event == "memoryPressureEnd" ? "memoryPressure" : "manualMemoryRelease"
                    }
                    pending = nil
                default: break
                }
            }
        }
        guard let before, let after else { return "最近释放对比：暂无完整的前后采样。" }
        let label = event == "memoryPressure" ? "内存压力" : "手动释放"
        let parts = [("物理", "physFootprint"), ("Go Alloc", "heapAlloc"),
                     ("Go Inuse", "heapInuse"), ("Go 已归还", "heapReleased"),
                     ("闲置大缓冲", "bufferPoolRetainedBytes")].map { label, key in
            guard let start = before[key], let end = after[key] else { return "\(label) 未采集" }
            return "\(label) \(formatBytes(start)) → \(formatBytes(end))（\(signedSize(signedDelta(end, start)))）"
        }
        let cooldown = signedDelta(after["forceGCSuppressed"], before["forceGCSuppressed"]) > 0
            ? "；本次处于统一冷却窗口，未重复执行 GC"
            : ""
        return "最近释放对比（\(label)）：" + parts.joined(separator: "；") + cooldown
    }

    private static func releaseMetrics(_ sample: MemoryDiagnosticSample) -> [String: UInt64] {
        var metrics: [String: UInt64] = [:]
        for (key, value) in [("physFootprint", sample.physFootprint),
                             ("heapAlloc", sample.go?.heapAlloc), ("heapInuse", sample.go?.heapInuse),
                             ("heapReleased", sample.go?.heapReleased),
                             ("bufferPoolRetainedBytes", sample.go?.bufferPoolRetainedBytes),
                             ("forceGCSuppressed", sample.go?.forceGCSuppressed)] {
            if let value { metrics[key] = value }
        }
        return metrics
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
                               fallback: UInt64?, sampleTime: Int64? = nil) -> UInt64? {
        let value = metric(key, summary: summary)
        // An omitted optional field in a newer sample means unmeasured, not
        // the last non-zero value retained earlier in the session summary.
        if let sampleTime, sampleTime >= (value?.latestAt ?? summary?.updatedAtMs ?? Int64.min) {
            return fallback
        }
        if let value { return value.latest }
        return fallback
    }

    private static func peak(_ key: String,
                             summary: MemoryDiagnosticSummary?,
                             fallback: UInt64?) -> UInt64? {
        [metric(key, summary: summary)?.peak, fallback].compactMap { $0 }.max()
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
                                  fallback: Int?, sampleTime: Int64? = nil) -> Int? {
        if let sampleTime, sampleTime >= (metric(key, summary: summary)?.latestAt ?? summary?.updatedAtMs ?? Int64.min) {
            return fallback
        }
        if let metric = metric(key, summary: summary) {
            return metric.latest.map { Int(min($0, UInt64(Int.max))) }
        }
        return fallback
    }

    private static func latestSigned(_ key: String,
                                     summary: MemoryDiagnosticSummary?,
                                     fallback: Int64?, sampleTime: Int64? = nil) -> Int64? {
        if let sampleTime, sampleTime >= (metric(key, summary: summary)?.latestAt ?? summary?.updatedAtMs ?? Int64.min) {
            return fallback
        }
        if let metric = metric(key, summary: summary) {
            return metric.latest.map { Int64(min($0, UInt64(Int64.max))) }
        }
        return fallback
    }

    private static func delta(_ key: String,
                              summary: MemoryDiagnosticSummary?,
                              start: UInt64?,
                              end: UInt64?, endTime: Int64? = nil) -> Int64 {
        if let value = metric(key, summary: summary), let first = value.first {
            if let endTime, endTime >= (value.latestAt ?? summary?.updatedAtMs ?? Int64.min) {
                return signedDelta(end, first)
            }
            return signedDelta(value.latest, first)
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
