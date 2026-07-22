import SwiftUI

/// 根视图：原生 TabView 五页（连接 / 配置 / 节点 / 日志 / 设置）。
/// iOS 26 由系统提供悬浮液态玻璃外观，并在向下滚动时自动收起为紧凑形态。
/// 在这里（始终存在的容器）按连接状态驱动内核速率与日志流的启停，切走再回来数据不清零。
struct RootView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var kernel: KernelController
    @EnvironmentObject private var logs: LogStreamController

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                tabs
                    .tabBarMinimizeBehavior(.onScrollDown)
            } else {
                tabs
            }
        }
        .onChange(of: core.isActive) { _, active in
            syncStreams(active)
        }
        .onAppear { syncStreams(core.isActive) }
    }

    private var tabs: some View {
        TabView {
            Tab("连接", systemImage: "power") {
                ConnectView()
            }
            Tab("配置", systemImage: "doc.text") {
                SubscriptionsView()
            }
            Tab("节点", systemImage: "point.3.connected.trianglepath.dotted") {
                ProxiesView()
            }
            Tab("日志", systemImage: "list.bullet.rectangle") {
                LogsView()
            }
            Tab("设置", systemImage: "gearshape") {
                SettingsView()
            }
        }
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
