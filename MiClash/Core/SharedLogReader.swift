import Foundation

/// 从 App Group 共享容器读取 NE / mihomo 的落盘日志，并做容器可用性诊断。
///
/// `ne.log`：NE 扩展的启动步骤（Swift 侧，见 MiClashTunnel/FileLog.swift）。
/// `run.log`：mihomo 内核日志 + 封装层标记（Go 侧，见 MobileCore/mihomo.go）。
///
/// 两份日志都在 App Group 容器里。如果容器本身拿不到（自签未带 App Group 能力、
/// 或描述文件没注册该 group），日志必然全空——所以先诊断容器，再读日志，避免误判。
enum SharedLogReader {

    /// 诊断 + 日志合并报告，一屏看清问题。
    static func combined() -> String {
        var out = "===== App Group 诊断 =====\n"
        out += "源码 fallback: \(AppGroup.fallback)\n"
        out += "实际被授予: \(AppGroup.granted.isEmpty ? "(无 —— 签名未启用 App Groups 能力)" : AppGroup.granted.joined(separator: ", "))\n"
        out += "选用 id: \(AppGroup.identifier)\n"

        guard let dir = AppGroup.containerURL else {
            // 容器为 nil = 主 App 这侧没拿到共享容器。
            out += "❌ 容器为 nil —— App Group 未生效！\n"
            if AppGroup.granted.isEmpty {
                out += "   原因：签名时未启用 App Groups 能力（entitlements 里没有 application-groups）。\n"
                out += "   修法：重签时勾选/注入 App Groups 能力，主 App 与 NE 用同一个 group。\n"
            } else {
                out += "   entitlements 里有 group 但容器仍取不到，可能是描述文件未真正注册该 group。\n"
            }
            return out
        }
        out += "✅ 容器路径: \(dir.path)\n"

        // 列出容器目录内容，确认 NE 到底写没写文件
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(atPath: dir.path) {
            out += "目录内容: \(items.isEmpty ? "(空)" : items.joined(separator: ", "))\n"
        } else {
            out += "目录内容: (无法列出)\n"
        }

        out += "\n===== ne.log（NE 启动步骤）=====\n" + read("ne.log", in: dir)
        out += "\n\n===== run.log（mihomo 内核）=====\n" + read("run.log", in: dir)
        return out
    }

    private static func read(_ name: String, in dir: URL) -> String {
        let url = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "(\(name) 不存在 —— NE 没走到写这一步，或没启动)"
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "(\(name) 存在但读取失败)"
        }
        return text.isEmpty ? "(\(name) 存在但为空)" : text
    }
}
