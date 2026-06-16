import SwiftUI

/// App 入口。SwiftUI App 生命周期（无 Storyboard）。
/// 全局状态机 CoreStateManager 以 @StateObject 注入环境，供所有视图单向绑定。
@main
struct MiClashApp: App {
    /// 全局单例状态机：Phase 0 只负责 VPN 启停与状态；后续接入 mihomo API。
    @StateObject private var core = CoreStateManager.shared

    var body: some Scene {
        WindowGroup {
            ConnectView()
                .environmentObject(core)
        }
    }
}
