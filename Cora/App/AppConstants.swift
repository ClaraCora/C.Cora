import Foundation

/// 全局常量：Bundle 标识与 App Group。
/// 这些值必须与 entitlements、project.yml、NE 扩展三处保持一致。
enum AppConstants {
    /// NE 扩展的 Bundle Identifier，主 App 装 VPN 描述文件时要指向它
    static let tunnelBundleID = "com.cora.app.tunnel"

    /// App Group：主 App 与 NE 共享配置、日志、状态文件的容器
    static let appGroupID = "group.com.cora.app"

    /// 系统设置里展示的 VPN 配置名
    static let vpnProfileName = "Cora"
}
