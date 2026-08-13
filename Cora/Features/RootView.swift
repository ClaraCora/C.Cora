import SwiftUI

/// 根视图：原生 TabView 四页（总览 / 策略 / 记录 / 设置）。
/// iOS 26 由系统提供悬浮液态玻璃外观；底栏保持完整形态，不随滚动收缩。
/// 在这里（始终存在的容器）按连接状态驱动内核速率与日志流的启停，切走再回来数据不清零。
struct RootView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var kernel: KernelController
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connections = ConnectionsController()

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                tabs
                    .tabBarMinimizeBehavior(.never)
            } else {
                tabs
            }
        }
        .onChange(of: core.status) { _, _ in
            syncStreams()
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhase(phase)
        }
        .onAppear { syncStreams() }
        .task(id: core.status.rawValue) {
            switch core.status {
            case .connecting:
                connections.reset()
            case .connected, .reasserting:
                await connections.poll()
            case .disconnected, .invalid:
                connections.reset()
            default:
                break
            }
        }
    }

    private var tabs: some View {
        TabView {
            ConnectView()
                .tabItem { Label("总览", systemImage: "gauge.with.dots.needle.67percent") }
            ProxiesView()
                .tabItem { Label("策略", systemImage: "slider.horizontal.3") }
            ActivityView(connections: connections)
                .tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }

    private func syncStreams() {
        if core.status == .connecting {
            LogStreamController.shared.start(awaitingNewSession: true)
        } else if core.status == .connected || core.status == .reasserting {
            kernel.start()
            LogStreamController.shared.start()
        } else if core.status == .disconnected || core.status == .invalid {
            kernel.stop()
            LogStreamController.shared.stop()
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task {
                await core.refreshStatus()
                syncStreams()
                if core.status == .connected || core.status == .reasserting {
                    await kernel.refreshMemory()
                }
            }
        case .inactive, .background:
            Task { await subscriptions.flushPersistence() }
        default:
            break
        }
    }
}
