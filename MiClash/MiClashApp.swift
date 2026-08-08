import SwiftUI

/// App 入口。SwiftUI App 生命周期（无 Storyboard）。
/// 全局状态机 CoreStateManager 以 @StateObject 注入环境，供所有视图单向绑定。
@main
struct MiClashApp: App {
    /// 全局单例状态机：VPN 启停/状态、与 NE 的 IPC。
    @StateObject private var core = CoreStateManager.shared
    /// 订阅 Store：存取/拉取订阅，连接时提供当前配置。
    @StateObject private var subscriptions = SubscriptionStore.shared
    /// 设置 Store：内核栈/日志/IPv6/geo。
    @StateObject private var settings = SettingsStore.shared
    /// 固定的可视化配置覆写；具体配置文件只保存是否启用。
    @StateObject private var configOverrides = ConfigOverrideStore.shared
    /// GEO 数据由主 App 下载到 App Group，NE 只负责读取。
    @StateObject private var geoDatabase = GeoDatabaseManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(core)
                .environmentObject(subscriptions)
                .environmentObject(settings)
                .environmentObject(configOverrides)
                .environmentObject(geoDatabase)
                // 两者都是全局单例；直接注入可避免高频发布让 App 根视图整体失效。
                .environmentObject(KernelController.shared)
                .environmentObject(LogStreamController.shared)
                .task { await geoDatabase.updateOnLaunch() }
        }
    }
}
