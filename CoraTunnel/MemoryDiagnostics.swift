import Foundation
import Darwin
import Mihomo
import os

/// Low-overhead OOM evidence captured inside the Network Extension process.
/// Samples bypass the UI log buffers and are persisted as bounded NDJSON files.
final class MemoryDiagnostics: @unchecked Sendable {
    private static let maxFileBytes: UInt64 = 256 * 1024
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
    private var timer: (any DispatchSourceTimer)?
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private var fileHandle: FileHandle?
    private var currentURL: URL?
    private var previousURL: URL?
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

    func start(directoryPath: String) {
        queue.sync {
            stopLocked(event: "restart")

            let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
            currentURL = directory.appendingPathComponent("memory-diagnostic.ndjson")
            previousURL = directory.appendingPathComponent("memory-diagnostic.previous.ndjson")
            sessionID = UUID().uuidString
            lastGoStats = "{}"
            lastGoStatsUptime = nil
            lastPressureUptime = -.infinity
            sampleCount = 0
            pressureEventCount = 0
            pressureSuppressedCount = 0
            lastSampleDurationMs = 0
            didReportFileError = false
            prepareFilesForNewSessionLocked()
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

    func stop(event: String) {
        queue.sync { stopLocked(event: event) }
    }

    static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
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
            let footprint = Self.physicalFootprint()
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
            let line = "{\"v\":1,\"t\":\(timestampMs),\"uptimeMs\":\(uptimeMs),"
                + "\"session\":\"\(sessionID)\",\"event\":\"\(event)\","
                + "\"physFootprint\":\(footprint),\"availableMemory\":\(available),"
                + "\"sampleCount\":\(sampleCount),\"pressureEvents\":\(pressureEventCount),"
                + "\"pressureSuppressed\":\(pressureSuppressedCount),"
                + "\"sampleDurationMs\":\(lastSampleDurationMs),"
                + "\"goStatsUptimeMs\":\(goStatsUptimeMs),\"go\":\(lastGoStats)}\n"
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

    private func handlePressureLocked() {
        pressureEventCount &+= 1
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastPressureUptime >= Self.pressureCooldown else {
            pressureSuppressedCount &+= 1
            return
        }
        lastPressureUptime = uptime
        writeSampleLocked(event: "memoryPressure", synchronize: true)
        // The handler runs on a utility queue. Keep one bounded recovery action
        // for the pressure window; the cooldown above prevents re-entry bursts.
        MihomoForceGC()
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
