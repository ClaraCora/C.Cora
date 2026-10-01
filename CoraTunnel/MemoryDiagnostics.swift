import Foundation
import Darwin
import Mihomo
import os

/// Low-overhead OOM evidence captured inside the Network Extension process.
/// Samples bypass the UI log buffers and are persisted as bounded NDJSON files.
final class MemoryDiagnostics: @unchecked Sendable {
    /// Small counters supplied by the packet tunnel without retaining any
    /// payload. They are sampled only while developer mode is enabled.
    struct SupplementalStats {
        let ipcResponseCount: Int
        let ipcResponseBytes: UInt64
        let ipcResponseMemoryBytes: UInt64
        let ipcResponseFileBytes: UInt64
        let logBufferedLines: Int
        let logBufferedBytes: UInt64
        let logPersistedBytes: UInt64

        static let empty = SupplementalStats(ipcResponseCount: 0,
                                             ipcResponseBytes: 0,
                                             ipcResponseMemoryBytes: 0,
                                             ipcResponseFileBytes: 0,
                                             logBufferedLines: 0,
                                             logBufferedBytes: 0,
                                             logPersistedBytes: 0)
    }

    /// `task_vm_info` values provide the small amount of VM accounting that
    /// phys_footprint alone cannot explain (resident, compressed, and internal
    /// pages). The fields are counters, not retained memory.
    struct VirtualMemoryStats {
        let virtualSize: UInt64
        let residentSize: UInt64
        let residentSizePeak: UInt64
        let internalSize: UInt64
        let compressedSize: UInt64
        let compressedSizePeak: UInt64
        let reusableSize: UInt64
        let physFootprint: UInt64

        static let zero = VirtualMemoryStats(virtualSize: 0,
                                             residentSize: 0,
                                             residentSizePeak: 0,
                                             internalSize: 0,
                                             compressedSize: 0,
                                             compressedSizePeak: 0,
                                             reusableSize: 0,
                                             physFootprint: 0)
    }

    private struct MetricSummary: Codable {
        var first: UInt64?
        var latest: UInt64?
        var minimum: UInt64?
        var peak: UInt64?
        var firstAt: Int64?
        var latestAt: Int64?
        var peakAt: Int64?

        mutating func update(_ value: UInt64, at timestamp: Int64) {
            if first == nil {
                first = value
                firstAt = timestamp
            }
            latest = value
            latestAt = timestamp
            if minimum == nil || value < (minimum ?? value) {
                minimum = value
            }
            if peak == nil || value > (peak ?? value) {
                peak = value
                peakAt = timestamp
            }
        }
    }

    private struct ReleaseComparison: Codable {
        let event: String
        let t: Int64
        let before: [String: UInt64]
        let after: [String: UInt64]
    }

    private struct SessionSummary: Codable {
        let v: Int
        let kind: String
        let session: String
        let startedAtMs: Int64
        var updatedAtMs: Int64
        var sampleCount: UInt64
        var metrics: [String: MetricSummary]
        var lastRelease: ReleaseComparison?
    }

    private static let maxFileBytes: UInt64 = 256 * 1024
    private static let maxSummaryBytes: UInt64 = 24 * 1024
    // 诊断只在用户主动开启开发者模式时运行；5 秒间隔足以看出趋势，
    // 同时避免采样和磁盘同步本身给 NE 增加持续负担。
    private static let sampleInterval = DispatchTimeInterval.seconds(5)
    private static let goStatsInterval: TimeInterval = 5
    // DispatchSourceMemoryPressure may deliver a burst of warning/critical
    // events while one allocation storm is still in progress. Treat that
    // burst as one diagnostic action; repeated synchronous stats/GC calls can
    // otherwise create a GC storm and increase phys_footprint themselves.
    private static let pressureCooldown: TimeInterval = 20

    private let queue = DispatchQueue(label: "com.cora.tunnel.memory-diagnostics",
                                      qos: .utility)
    private let supplementalStatsProvider: () -> SupplementalStats
    private var timer: (any DispatchSourceTimer)?
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private var fileHandle: FileHandle?
    private var currentURL: URL?
    private var previousURL: URL?
    private var summaryURL: URL?
    private var previousSummaryURL: URL?
    private var bytesWritten: UInt64 = 0
    private var sessionID = ""
    private var lastGoStats = "{}"
    private var lastGoStatsUptime: TimeInterval?
    private var lastPressureUptime: TimeInterval = -.infinity
    private var sampleCount: UInt64 = 0
    private var pressureEventCount: UInt64 = 0
    private var pressureSuppressedCount: UInt64 = 0
    private var lastSampleDurationMs: Int64 = 0
    private var didReportFileError = false
    private var summaryStartedAtMs: Int64 = 0
    private var summaryUpdatedAtMs: Int64 = 0
    private var summaryMetrics: [String: MetricSummary] = [:]
    private var lastSummaryWriteUptime: TimeInterval?
    private var summaryWritable = true
    private var sessionPhysFootprintPeak: UInt64 = 0
    private var lastRelease: ReleaseComparison?

    init(supplementalStatsProvider: @escaping () -> SupplementalStats = { .empty }) {
        self.supplementalStatsProvider = supplementalStatsProvider
    }

    func start(directoryPath: String) {
        queue.sync {
            stopLocked(event: "restart")

            let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
            currentURL = directory.appendingPathComponent("memory-diagnostic.ndjson")
            previousURL = directory.appendingPathComponent("memory-diagnostic.previous.ndjson")
            summaryURL = directory.appendingPathComponent("memory-diagnostic.summary.json")
            previousSummaryURL = directory.appendingPathComponent(
                "memory-diagnostic.summary.previous.json")
            sessionID = UUID().uuidString
            lastGoStats = "{}"
            lastGoStatsUptime = nil
            lastPressureUptime = -.infinity
            sampleCount = 0
            pressureEventCount = 0
            pressureSuppressedCount = 0
            lastSampleDurationMs = 0
            didReportFileError = false
            summaryStartedAtMs = 0
            summaryUpdatedAtMs = 0
            summaryMetrics.removeAll(keepingCapacity: true)
            lastSummaryWriteUptime = nil
            summaryWritable = true
            sessionPhysFootprintPeak = 0
            lastRelease = nil
            prepareFilesForNewSessionLocked()
            prepareSummaryFilesForNewSessionLocked()
            guard fileHandle != nil else { return }
            writeSampleLocked(event: "start", synchronize: true)

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.sampleInterval,
                           repeating: Self.sampleInterval,
                           leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                self?.writeSampleLocked(event: "sample", synchronize: false)
            }
            self.timer = timer
            timer.resume()

            let pressure = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical], queue: queue)
            pressure.setEventHandler { [weak self] in
                self?.handlePressureLocked()
            }
            pressureSource = pressure
            pressure.resume()
        }
    }

    func record(event: String) {
        queue.sync {
            guard fileHandle != nil else { return }
            writeSampleLocked(event: event, synchronize: true)
        }
    }

    /// Serialize the entire action with periodic samples and pressure events.
    /// Both samples refresh Go counters; the last pair also survives ring rotation.
    func releaseMemory() -> (before: UInt64, after: UInt64) {
        queue.sync { releaseMemoryLocked(event: "manualMemoryRelease") }
    }

    private func releaseMemoryLocked(event: String) -> (before: UInt64, after: UInt64) {
        writeSampleLocked(event: event == "memoryPressure" ? event : event + "Start",
                          synchronize: true)
        let before = Self.physicalFootprint()
        let beforeStats = releaseSnapshotLocked(footprint: before)
        MihomoForceGC()
        let after = Self.physicalFootprint()
        writeSampleLocked(event: event + "End", synchronize: true)
        lastRelease = ReleaseComparison(event: event,
                                        t: Int64(Date().timeIntervalSince1970 * 1_000),
                                        before: beforeStats,
                                        after: releaseSnapshotLocked(footprint: after))
        persistSummaryLocked()
        return (before, after)
    }

    private func releaseSnapshotLocked(footprint: UInt64) -> [String: UInt64] {
        var metrics = ["physFootprint": footprint]
        if let data = lastGoStats.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["heapAlloc", "heapInuse", "heapReleased", "bufferPoolRetainedBytes",
                        "bufferPoolLastTrimBytes", "numForcedGC", "forceGCSuppressed"] {
                if let value = object[key] as? NSNumber, value.int64Value >= 0 {
                    metrics[key] = value.uint64Value
                }
            }
        }
        return metrics
    }

    func stop(event: String) {
        queue.sync { stopLocked(event: event) }
    }

    static func virtualMemoryStats() -> VirtualMemoryStats {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .zero }
        return VirtualMemoryStats(
            virtualSize: UInt64(info.virtual_size),
            residentSize: UInt64(info.resident_size),
            residentSizePeak: UInt64(info.resident_size_peak),
            internalSize: UInt64(info.`internal`),
            compressedSize: UInt64(info.compressed),
            compressedSizePeak: UInt64(info.compressed_peak),
            reusableSize: UInt64(info.reusable),
            physFootprint: UInt64(info.phys_footprint))
    }

    static func physicalFootprint() -> UInt64 {
        virtualMemoryStats().physFootprint
    }

    private func stopLocked(event: String) {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        pressureSource?.setEventHandler {}
        pressureSource?.cancel()
        pressureSource = nil

        if fileHandle != nil {
            writeSampleLocked(event: event, synchronize: true)
            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    private func writeSampleLocked(event: String, synchronize: Bool) {
        autoreleasepool {
            guard fileHandle != nil else { return }
            sampleCount &+= 1
            let sampleStarted = ProcessInfo.processInfo.systemUptime
            let timestampMs = Int64(Date().timeIntervalSince1970 * 1_000)
            let uptime = ProcessInfo.processInfo.systemUptime
            let uptimeMs = Int64(uptime * 1_000)
            let vm = Self.virtualMemoryStats()
            let footprint = vm.physFootprint
            sessionPhysFootprintPeak = max(sessionPhysFootprintPeak, footprint)
            let available = UInt64(os_proc_available_memory())
            let shouldRefreshGoStats = synchronize
                || lastGoStatsUptime == nil
                || uptime - (lastGoStatsUptime ?? 0) >= Self.goStatsInterval
            if shouldRefreshGoStats {
                lastGoStats = MihomoRuntimeStats()
                lastGoStatsUptime = uptime
            }
            lastSampleDurationMs = Int64(
                max(0, (ProcessInfo.processInfo.systemUptime - sampleStarted) * 1_000))
            let goStatsUptimeMs = Int64((lastGoStatsUptime ?? uptime) * 1_000)
            let supplemental = supplementalStatsProvider()
            updateSummaryLocked(timestampMs: timestampMs,
                                footprint: footprint,
                                footprintPeak: sessionPhysFootprintPeak,
                                availableMemory: available,
                                vm: vm,
                                supplemental: supplemental,
                                goStats: lastGoStats,
                                uptime: uptime,
                                forcePersist: synchronize)
            let line = "{\"v\":1,\"t\":\(timestampMs),\"uptimeMs\":\(uptimeMs),"
                + "\"session\":\"\(sessionID)\",\"event\":\"\(event)\","
                + "\"physFootprint\":\(footprint),\"availableMemory\":\(available),"
                + "\"physFootprintPeak\":\(sessionPhysFootprintPeak),"
                + "\"sampleCount\":\(sampleCount),\"pressureEvents\":\(pressureEventCount),"
                + "\"pressureSuppressed\":\(pressureSuppressedCount),"
                + "\"sampleDurationMs\":\(lastSampleDurationMs),"
                + "\"goStatsUptimeMs\":\(goStatsUptimeMs),"
                + "\"vm\":{\"virtualSize\":\(vm.virtualSize),"
                + "\"residentSize\":\(vm.residentSize),"
                + "\"residentSizePeak\":\(vm.residentSizePeak),"
                + "\"internalSize\":\(vm.internalSize),"
                + "\"compressedSize\":\(vm.compressedSize),"
                + "\"compressedSizePeak\":\(vm.compressedSizePeak),"
                + "\"reusableSize\":\(vm.reusableSize)},"
                + "\"cora\":{\"ipcResponseCount\":\(supplemental.ipcResponseCount),"
                + "\"ipcResponseBytes\":\(supplemental.ipcResponseBytes),"
                + "\"ipcResponseMemoryBytes\":\(supplemental.ipcResponseMemoryBytes),"
                + "\"ipcResponseFileBytes\":\(supplemental.ipcResponseFileBytes),"
                + "\"logBufferedLines\":\(supplemental.logBufferedLines),"
                + "\"logBufferedBytes\":\(supplemental.logBufferedBytes),"
                + "\"logPersistedBytes\":\(supplemental.logPersistedBytes)},"
                + "\"go\":\(lastGoStats)}\n"
            let data = Data(line.utf8)
            rotateIfNeededLocked(incomingBytes: UInt64(data.count))
            guard let fileHandle else { return }
            do {
                try fileHandle.write(contentsOf: data)
                bytesWritten += UInt64(data.count)
                if synchronize {
                    try fileHandle.synchronize()
                }
            } catch {
                reportFileErrorLocked("write failed: \(error.localizedDescription)")
                try? fileHandle.close()
                self.fileHandle = nil
            }
        }
    }

    /// Retain only numeric first/latest/min/peak values for the entire
    /// developer-mode session. This makes an eight-hour trend available even
    /// after the detailed NDJSON ring has rotated, without retaining payloads.
    private func updateSummaryLocked(timestampMs: Int64,
                                     footprint: UInt64,
                                     footprintPeak: UInt64,
                                     availableMemory: UInt64,
                                     vm: VirtualMemoryStats,
                                     supplemental: SupplementalStats,
                                     goStats: String,
                                     uptime: TimeInterval,
                                     forcePersist: Bool) {
        if summaryStartedAtMs == 0 {
            summaryStartedAtMs = timestampMs
        }
        summaryUpdatedAtMs = timestampMs
        updateMetricLocked("physFootprint", value: footprint, timestampMs: timestampMs)
        updateMetricLocked("physFootprintPeak", value: footprintPeak, timestampMs: timestampMs)
        updateMetricLocked("availableMemory", value: availableMemory, timestampMs: timestampMs)
        updateMetricLocked("virtualSize", value: vm.virtualSize, timestampMs: timestampMs)
        updateMetricLocked("residentSize", value: vm.residentSize, timestampMs: timestampMs)
        updateMetricLocked("residentSizePeak", value: vm.residentSizePeak, timestampMs: timestampMs)
        updateMetricLocked("internalSize", value: vm.internalSize, timestampMs: timestampMs)
        updateMetricLocked("compressedSize", value: vm.compressedSize, timestampMs: timestampMs)
        updateMetricLocked("compressedSizePeak", value: vm.compressedSizePeak, timestampMs: timestampMs)
        updateMetricLocked("reusableSize", value: vm.reusableSize, timestampMs: timestampMs)
        updateMetricLocked("ipcResponseCount", value: UInt64(max(0, supplemental.ipcResponseCount)),
                           timestampMs: timestampMs)
        updateMetricLocked("ipcResponseBytes", value: supplemental.ipcResponseBytes,
                           timestampMs: timestampMs)
        updateMetricLocked("ipcResponseMemoryBytes", value: supplemental.ipcResponseMemoryBytes,
                           timestampMs: timestampMs)
        updateMetricLocked("ipcResponseFileBytes", value: supplemental.ipcResponseFileBytes,
                           timestampMs: timestampMs)
        updateMetricLocked("logBufferedLines", value: UInt64(max(0, supplemental.logBufferedLines)),
                           timestampMs: timestampMs)
        updateMetricLocked("logBufferedBytes", value: supplemental.logBufferedBytes,
                           timestampMs: timestampMs)
        updateMetricLocked("logPersistedBytes", value: supplemental.logPersistedBytes,
                           timestampMs: timestampMs)

        // RuntimeStats is already a compact JSON object produced by Go. Parse
        // only these counters for the long-lived summary; the full object is
        // still kept in each detailed sample for short-window inspection.
        if let data = goStats.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (family, key) in [("fakeIP4", "fakeIP4Entries"), ("fakeIP6", "fakeIP6Entries")] {
                if let cache = object[family] as? [String: Any],
                   let entries = cache["entries"] as? NSNumber, entries.int64Value >= 0 {
                    updateMetricLocked(key, value: entries.uint64Value, timestampMs: timestampMs)
                } else {
                    clearLatestMetricLocked(key, timestampMs: timestampMs)
                }
            }
            for key in Self.summaryGoMetricKeys {
                guard let number = object[key] as? NSNumber,
                      number.int64Value >= 0 else {
                    clearLatestMetricLocked(key, timestampMs: timestampMs)
                    continue
                }
                updateMetricLocked(key, value: number.uint64Value, timestampMs: timestampMs)
            }
        }

        let shouldPersist = forcePersist
            || lastSummaryWriteUptime == nil
            || uptime - (lastSummaryWriteUptime ?? 0) >= 60
        if shouldPersist {
            persistSummaryLocked(uptime: uptime)
        }
    }

    private static let summaryGoMetricKeys = [
        "heapAlloc", "heapObjects", "heapInuse", "heapIdle", "heapReleased", "heapSys",
        "stackInuse", "stackSys", "mspanInuse", "mcacheInuse", "buckHashSys", "gcSys",
        "otherSys", "sys", "totalAlloc", "mallocs", "frees", "nextGC", "lastGC",
        "numGC", "numForcedGC", "pauseTotalNs", "lastPauseNs", "goMemoryLimit",
        "goGCPercent", "goroutines", "connections", "tcpConnections", "udpConnections",
        "proxyProviders", "ruleProviders", "proxyGroups", "delaySlotsInUse",
        "delaySlotLimit", "activeDelayBatches", "connectionSnapshotBytes",
        "closedSnapshotBytes", "closedQueuePending", "mihomoBufferPoolBuffers",
        "mihomoBufferPoolBytes", "mihomoBufferPoolMaxBytes", "singBufferPoolBuffers",
        "singBufferPoolBytes", "singBufferPoolMaxBytes", "bufferPoolRetainedBytes",
        "bufferPoolLastTrimBytes", "bufferPoolTrimmedBytes", "forceGCSuppressed",
        "proxyCount", "policyGroupCount", "proxyProviderNodes", "ruleProviderRules",
        "dnsCacheEntries", "dnsCacheCount", "dnsMappingEntries",
        "tunRXQueuedPackets", "tunRXQueuedBytes", "tunTXQueuedPackets", "tunTXQueuedBytes",
        "geoIPFileBytes", "geoSiteFileBytes", "mmdbFileBytes", "asnFileBytes",
    ]

    private func clearLatestMetricLocked(_ key: String, timestampMs: Int64) {
        guard var metric = summaryMetrics[key] else { return }
        // Preserve historical first/peak for trend analysis; latest is unknown
        // after a config/stack/storage transition stops exposing the metric.
        metric.latest = nil
        metric.latestAt = timestampMs
        summaryMetrics[key] = metric
    }

    private func updateMetricLocked(_ key: String, value: UInt64, timestampMs: Int64) {
        var metric = summaryMetrics[key] ?? MetricSummary(first: nil,
                                                           latest: nil,
                                                           minimum: nil,
                                                           peak: nil,
                                                           firstAt: nil,
                                                           latestAt: nil,
                                                           peakAt: nil)
        metric.update(value, at: timestampMs)
        summaryMetrics[key] = metric
    }

    private func persistSummaryLocked(uptime: TimeInterval? = nil) {
        guard summaryWritable, let summaryURL, summaryStartedAtMs > 0 else { return }
        let summary = SessionSummary(v: 1,
                                     kind: "summary",
                                     session: sessionID,
                                     startedAtMs: summaryStartedAtMs,
                                     updatedAtMs: summaryUpdatedAtMs,
                                     sampleCount: sampleCount,
                                     metrics: summaryMetrics,
                                     lastRelease: lastRelease)
        guard let data = try? JSONEncoder().encode(summary),
              UInt64(data.count) <= Self.maxSummaryBytes else {
            summaryWritable = false
            reportFileErrorLocked("summary exceeds bounded size or could not be encoded")
            return
        }
        do {
            try data.write(to: summaryURL, options: .atomic)
            lastSummaryWriteUptime = uptime ?? ProcessInfo.processInfo.systemUptime
        } catch {
            // Avoid retrying an unavailable filesystem on every five-second
            // sample; detailed sampling remains available in the bounded ring.
            summaryWritable = false
            reportFileErrorLocked("summary write failed: \(error.localizedDescription)")
        }
    }

    private func prepareSummaryFilesForNewSessionLocked() {
        guard let summaryURL, let previousSummaryURL else { return }
        let manager = FileManager.default
        summaryWritable = true
        let hasCurrent = manager.fileExists(atPath: summaryURL.path)
            && ((try? summaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        if hasCurrent {
            let stagedURL = previousSummaryURL.appendingPathExtension("tmp")
            do {
                // Keep the old current summary intact until the copy and the
                // replacement both succeed. A failed rotation must never
                // truncate the only complete session summary.
                try? manager.removeItem(at: stagedURL)
                try manager.copyItem(at: summaryURL, to: stagedURL)
                if manager.fileExists(atPath: previousSummaryURL.path) {
                    _ = try manager.replaceItemAt(previousSummaryURL,
                                                  withItemAt: stagedURL)
                } else {
                    try manager.moveItem(at: stagedURL, to: previousSummaryURL)
                }
                try Data().write(to: summaryURL, options: .atomic)
            } catch {
                try? manager.removeItem(at: stagedURL)
                summaryWritable = false
                reportFileErrorLocked("summary rotation failed: \(error.localizedDescription)")
                return
            }
        } else if !manager.fileExists(atPath: summaryURL.path) {
            manager.createFile(atPath: summaryURL.path, contents: nil)
        }

        guard manager.fileExists(atPath: summaryURL.path) else {
            summaryWritable = false
            reportFileErrorLocked("summary open failed: file was not created")
            return
        }
    }

    private func handlePressureLocked() {
        pressureEventCount &+= 1
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastPressureUptime >= Self.pressureCooldown else {
            pressureSuppressedCount &+= 1
            return
        }
        lastPressureUptime = uptime
        // The handler already owns the diagnostics queue; do not queue.sync.
        _ = releaseMemoryLocked(event: "memoryPressure")
    }

    private func rotateIfNeededLocked(incomingBytes: UInt64) {
        guard bytesWritten > 0,
              bytesWritten + incomingBytes > Self.maxFileBytes else { return }
        rotateCurrentToPreviousLocked()
    }

    /// A new session always starts with an empty current file. The prior
    /// session remains intact in previous even when the process died by jetsam.
    private func prepareFilesForNewSessionLocked() {
        guard let currentURL else { return }
        let manager = FileManager.default
        guard manager.fileExists(atPath: currentURL.path) else {
            openCurrentFileLocked()
            return
        }
        let size = try? currentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if size != 0 {
            rotateCurrentToPreviousLocked()
        } else {
            openCurrentFileLocked()
        }
    }

    /// Shared by session boundaries and the in-session 256 KiB size limit.
    private func rotateCurrentToPreviousLocked() {
        guard let currentURL, let previousURL else { return }

        try? fileHandle?.close()
        fileHandle = nil
        let manager = FileManager.default
        let stagedURL = previousURL.appendingPathExtension("tmp")
        do {
            try? manager.removeItem(at: stagedURL)
            try manager.copyItem(at: currentURL, to: stagedURL)
            do {
                let stagedHandle = try FileHandle(forWritingTo: stagedURL)
                defer { try? stagedHandle.close() }
                try stagedHandle.synchronize()
            }
            if manager.fileExists(atPath: previousURL.path) {
                _ = try manager.replaceItemAt(previousURL, withItemAt: stagedURL)
            } else {
                try manager.moveItem(at: stagedURL, to: previousURL)
            }
            let currentHandle = try FileHandle(forWritingTo: currentURL)
            try currentHandle.truncate(atOffset: 0)
            try currentHandle.close()
        } catch {
            // Keep current intact when rotation fails; it is the only copy that
            // is guaranteed to contain the latest pre-jetsam samples. Stop
            // sampling instead of repeatedly copying or growing the file.
            try? manager.removeItem(at: stagedURL)
            reportFileErrorLocked("rotation failed; current preserved: \(error.localizedDescription)")
            return
        }
        openCurrentFileLocked()
    }

    private func openCurrentFileLocked() {
        guard let currentURL else { return }
        do {
            let manager = FileManager.default
            if !manager.fileExists(atPath: currentURL.path),
               !manager.createFile(atPath: currentURL.path, contents: nil) {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: currentURL)
            bytesWritten = try handle.seekToEnd()
            fileHandle = handle
        } catch {
            bytesWritten = 0
            fileHandle = nil
            reportFileErrorLocked("open failed: \(error.localizedDescription)")
        }
    }

    private func reportFileErrorLocked(_ message: String) {
        guard !didReportFileError else { return }
        didReportFileError = true
        FileLog.write("Memory diagnostics \(message)")
    }

}
