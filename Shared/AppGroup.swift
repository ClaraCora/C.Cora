import Foundation
import Security

/// 动态解析「当前二进制实际被授予的 App Group」，主 App 与 NE 共用同一套逻辑。
///
/// 为什么不直接用硬编码的 "group.com.miclash.app"：
/// 用户在 Windows 用重签工具（Sideloadly / 在线签名等）自签，这类工具常把
/// bundle id / app group 改写成带团队前缀或随机后缀的新值。若代码仍按硬编码字符串
/// 取容器，`containerURL(forSecurityApplicationGroupIdentifier:)` 会因「该 group
/// 未被授权」而返回 nil → 共享容器失效（日志全空、VPN 数据共享废掉）。
///
/// 解法（依据 Security 框架公开 API）：
///   SecTaskCreateFromSelf + SecTaskCopyValueForEntitlement
///   读取本进程 entitlements 里真正生效的 `com.apple.security.application-groups`，取第一个。
/// 只要重签工具对主 App 和 NE 两端改写一致，两边解析出的就是同一个 group，
/// 共享容器即可打通——与具体字符串无关。若 entitlements 里压根没有 app group
/// （签名时没启用该能力），则回退到 fallback，并在诊断里暴露出来。
enum AppGroup {

    /// 兜底值：与源码 entitlements 一致。签名未被改写时即用它。
    static let fallback = "group.com.miclash.app"

    /// 本进程实际被授予的所有 App Group（来自运行期 entitlements）。
    static let granted: [String] = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.security.application-groups" as CFString, nil),
              let groups = value as? [String] else {
            return []
        }
        return groups
    }()

    /// 选用的 App Group identifier：优先用实际被授予的第一个，否则回退 fallback。
    static var identifier: String { granted.first ?? fallback }

    /// 共享容器 URL（解析失败 / 未授权时为 nil）。
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
