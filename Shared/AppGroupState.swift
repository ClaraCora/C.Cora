import Foundation

/// 跨进程共享的轻量状态：主 App / NE 写，控制中心磁贴读，走 App Group 的 UserDefaults。
///
/// App Group 不可用（未授权）时 `UserDefaults(suiteName:)` 为 nil，读返回默认值、写静默失败——
/// 优雅降级，不影响主流程；授权后磁贴即可读到准确的连接状态。
enum AppGroupState {
    private static let defaults = UserDefaults(suiteName: AppGroup.identifier)

    private enum Key {
        static let vpnConnected = "vpnConnected"
    }

    /// VPN 是否处于连接（含连接中）状态。NE 启停时写入最准；主 App 状态变化时也同步。
    static var vpnConnected: Bool {
        get { defaults?.bool(forKey: Key.vpnConnected) ?? false }
        set { defaults?.set(newValue, forKey: Key.vpnConnected) }
    }
}
