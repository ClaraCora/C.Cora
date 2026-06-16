import SwiftUI

/// 根视图：连接 / 订阅 / 节点 / 日志 / 设置。
/// 在这里（始终存在的容器）按连接状态驱动内核速率与日志流的启停，
/// 使其不随某个 tab 的出现/消失而中断——切走再回来数据不清零。
struct RootView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var kernel: KernelController
    @EnvironmentObject private var logs: LogStreamController

    var body: some View {
        TabView {
            ConnectView()
                .tabItem { Label("连接", systemImage: "power") }

            SubscriptionsView()
                .tabItem { Label("订阅", systemImage: "doc.text") }

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
