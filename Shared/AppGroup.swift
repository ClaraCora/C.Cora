import Foundation

/// App Group 容器访问，主 App 与 NE 共用。
///
/// 说明：用户证书来自他人、无法控制开发者账号 → 注册不了 App Group，容器多半取不到。
/// 因此 App Group **不是关键路径**：
///   - 日志走官方 `sendProviderMessage`/`handleAppMessage` IPC（不需共享容器）；
///   - mihomo 工作目录在容器不可用时回退到 NE 自己的沙盒目录。
/// 这里只做最简封装：容器可用就用（顺带 best-effort 落日志文件），不可用返回 nil 由调用方回退。
///
/// 注：iOS SDK 不公开 SecTask 系列 API（那是 macOS 的），无法在运行时读 entitlements
/// 动态解析被授予的 group，故直接用约定的固定标识。
enum AppGroup {
    static let identifier = "group.com.miclash.app"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
