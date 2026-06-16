import Foundation

/// 从 App Group 共享容器读取 NE / mihomo 的落盘日志。
///
/// `ne.log`：NE 扩展的启动步骤（Swift 侧，见 MiClashTunnel/FileLog.swift）。
/// `run.log`：mihomo 内核日志 + 封装层标记（Go 侧，见 MobileCore/mihomo.go）。
/// 两者都在 App Group 容器内，主 App 有权限直接读，用于无 Mac 环境下排查 tun 启动失败。
enum SharedLogReader {

    private static var containerURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)
    }

    private static func read(_ name: String) -> String {
        guard let url = containerURL?.appendingPathComponent(name),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "(\(name) 暂无内容)"
        }
        return text.isEmpty ? "(\(name) 为空)" : text
    }

    /// 合并两份日志，便于一屏查看。
    static func combined() -> String {
        """
        ===== ne.log（NE 启动步骤）=====
        \(read("ne.log"))

        ===== run.log（mihomo 内核）=====
        \(read("run.log"))
        """
    }
}
