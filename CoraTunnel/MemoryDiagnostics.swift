import Foundation
import Darwin
import os
import MeowCore

/// Bounded Rust-engine diagnostics. The payload deliberately contains only
/// phys_footprint, resident bytes, active TCP flows, counters and uptime.
final class MemoryDiagnostics: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.cora.tunnel.memory-diagnostics", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var file: FileHandle?
    private var url: URL?
    private var count: UInt64 = 0
    private var session = UUID().uuidString
    private static let maxBytes: UInt64 = 256 * 1024

    static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    func start(directoryPath: String) {
        queue.sync {
            stopLocked()
            let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("memory-diagnostic.ndjson")
            if let url, FileManager.default.fileExists(atPath: url.path) {
                let previous = directory.appendingPathComponent("memory-diagnostic.previous.ndjson")
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.moveItem(at: url, to: previous)
            }
            session = UUID().uuidString
            file = try? FileHandle(forWritingTo: url!)
            if file == nil { FileManager.default.createFile(atPath: url!.path, contents: nil); file = try? FileHandle(forWritingTo: url!) }
            _ = try? file?.seekToEnd()
            count = 0
            writeLocked(event: "start")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5), leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.writeLocked(event: "sample") }
            self.timer = timer; timer.resume()
        }
    }

    func record(event: String) { queue.sync { writeLocked(event: event) } }
    func stop(event: String = "stop") { queue.sync { if file != nil { writeLocked(event: event) }; stopLocked() } }

    private func stopLocked() {
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        try? file?.synchronize(); try? file?.close(); file = nil
    }

    private func writeLocked(event: String) {
        guard let file else { return }
        let object = CoraNativeCore.dictionary(String(decoding: CoraNativeCore.request("runtime"), as: UTF8.self))
        count &+= 1
        var sample: [String: Any] = object
        sample["v"] = 2; sample["kind"] = "rust"; sample["event"] = event
        sample["session"] = session
        sample["t"] = Int64(Date().timeIntervalSince1970 * 1_000)
        sample["sampleCount"] = count
        let footprint = Self.physicalFootprint()
        if footprint > 0 { sample["physFootprint"] = footprint }
        sample["running"] = meow_engine_is_running() == 1
        var traffic = MeowInterfaceTraffic()
        meow_engine_interface_traffic(&traffic)
        sample["interfaceTraffic"] = ["wifiUpload": traffic.wifi_ethernet_upload,
            "wifiDownload": traffic.wifi_ethernet_download, "cellularUpload": traffic.cellular_upload,
            "cellularDownload": traffic.cellular_download, "otherUpload": traffic.other_upload,
            "otherDownload": traffic.other_download]
        guard let data = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]) else { return }
        if let size = try? file.seekToEnd(), UInt64(size) + UInt64(data.count) > Self.maxBytes {
            guard let url else { return }
            try? file.synchronize(); try? file.close()
            let previous = url.deletingLastPathComponent().appendingPathComponent("memory-diagnostic.previous.ndjson")
            try? FileManager.default.removeItem(at: previous)
            do { try FileManager.default.moveItem(at: url, to: previous) }
            catch { self.file = nil; return }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.file = try? FileHandle(forWritingTo: url)
        }
        try? self.file?.seekToEnd(); try? self.file?.write(contentsOf: data)
        try? self.file?.write(contentsOf: Data("\n".utf8)); try? self.file?.synchronize()
    }
}
