import SwiftUI

/// 根视图：原生 TabView 五页（连接 / 配置 / 节点 / 日志 / 设置）。
///
/// 底栏用**原生 TabView**——用 iOS 26 SDK 编译时，系统底栏自动是「悬浮 + 液态玻璃」，
/// 折射/定位/内容穿过全由系统处理（与 Everywhere 一致），不用自己画 glassEffect、也不用各页预留高度。
/// 在这里（始终存在的容器）按连接状态驱动内核速率与日志流的启停，切走再回来数据不清零。
struct RootView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var kernel: KernelController
    @EnvironmentObject private var logs: LogStreamController

    var body: some View {
        TabView {
            ConnectView()
                .tabItem { Label("连接", systemImage: "power") }
            SubscriptionsView()
                .tabItem { Label("配置", systemImage: "doc.text") }
            ProxiesView()
                .tabItem { Label("节点", systemImage: "point.3.connected.trianglepath.dotted") }
            LogsView()
                .tabItem { Label("日志", systemImage: "list.bullet.rectangle") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .onChange(of: core.isActive) { _, active in
            syncStreams(active)
        }
        .onAppear { syncStreams(core.isActive) }
    }

    private func syncStreams(_ active: Bool) {
        if active {
            kernel.start()
            logs.start()
        } else {
            kernel.stop()
            logs.stop()
        }
    }
}
