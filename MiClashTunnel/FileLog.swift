import Foundation

/// NE 扩展的落盘日志。
///
/// 用户在 Windows、无 Mac/Console，看不到 NE 的 os.log。这里把启动各步骤写进
/// App Group 共享容器的 `ne.log`，主 App 直接读该文件显示，使 NE 内部过程可见、可排查。
/// mihomo 内核自身的日志由 Go 侧写到同目录的 `run.log`（见 MobileCore/mihomo.go）。
enum FileLog {
    static let fileName = "ne.log"

    private static var fileURL: URL? {
        AppGroup.containerURL?.appendingPathComponent(fileName)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 清空日志（每次 startTunnel 调用，避免历史残留）。
    static func reset() {
        guard let url = fileURL else { return }
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    /// 追加一行（带时间戳）。
    static func write(_ message: String) {
        guard let url = fileURL else { return }
        let line = "\(formatter.string(from: Date())) [NE] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            // 文件还不存在，直接创建
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
