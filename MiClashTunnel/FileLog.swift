import Foundation

/// NE 扩展的运行日志。
///
/// 用户证书来自他人、无法控制开发者账号 → 注册不了 App Group。因此日志**不依赖
/// App Group 共享文件**，改为：进程内内存缓冲 + 经 `sendProviderMessage`/`handleAppMessage`
/// 官方 IPC 回传给主 App（见 PacketTunnelProvider.handleAppMessage）。
/// 这条通道不需要任何共享容器，只要 NE 在运行即可读取。
///
/// 若 App Group 恰好可用，也会顺带写一份 ne.log 文件（best-effort），但不作为主路径。
enum FileLog {

    private static let queue = DispatchQueue(label: "com.miclash.tunnel.filelog")
    private static let maxBufferedLines = 512
    private static let trimBufferedLinesAt = 640
    private static let maxFileBytes: UInt64 = 512 * 1024
    private static var buffer: [String] = []
    private static var persistedBytes: UInt64 = 0

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 清空（每次 startTunnel 调用）。
    static func reset() {
        queue.sync {
            buffer.removeAll()
            persistedBytes = 0
            if let url = AppGroup.containerURL?.appendingPathComponent("ne.log") {
                try? Data().write(to: url, options: .atomic)
            }
        }
    }

    /// 追加一行（带时间戳）。
    static func write(_ message: String) {
        queue.sync {
            let line = "\(formatter.string(from: Date())) [NE] \(message)"
            buffer.append(line)
            if buffer.count >= trimBufferedLinesAt {
                buffer.removeFirst(buffer.count - maxBufferedLines)
            }
            // best-effort：App Group 可用时也落一份有界文件，便于将来排查。
            if let url = AppGroup.containerURL?.appendingPathComponent("ne.log") {
                let data = Data((line + "\n").utf8.prefix(64 * 1024))
                if persistedBytes + UInt64(data.count) > maxFileBytes {
                    try? Data().write(to: url, options: .atomic)
                    persistedBytes = 0
                }
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    persistedBytes = (try? handle.seekToEnd()) ?? persistedBytes
                    try? handle.write(contentsOf: data)
                    persistedBytes += UInt64(data.count)
                } else if (try? data.write(to: url, options: .atomic)) != nil {
                    persistedBytes = UInt64(data.count)
                }
            }
        }
    }

    /// 导出当前缓冲全部内容（供 handleAppMessage 回传主 App）。
    static func dump() -> String {
        queue.sync { buffer.joined(separator: "\n") }
    }
}
