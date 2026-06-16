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
    private static var buffer: [String] = []

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 清空（每次 startTunnel 调用）。
    static func reset() {
        queue.sync { buffer.removeAll() }
    }

    /// 追加一行（带时间戳）。
    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) [NE] \(message)"
        queue.sync { buffer.append(line) }

        // best-effort：App Group 可用时也落一份文件，便于将来排查
        if let url = AppGroup.containerURL?.appendingPathComponent("ne.log") {
            let data = (line + "\n").data(using: .utf8) ?? Data()
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                h.seekToEndOfFile()
                h.write(data)
            } else {
                try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// 导出当前缓冲全部内容（供 handleAppMessage 回传主 App）。
    static func dump() -> String {
        queue.sync { buffer.joined(separator: "\n") }
    }
}
