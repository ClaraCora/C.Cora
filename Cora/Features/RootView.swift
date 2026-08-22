import SwiftUI
import NetworkExtension

/// 根视图：原生 TabView 五页（总览 / 策略 / 节点 / 记录 / 设置）。
/// iOS 26 由系统提供悬浮液态玻璃外观；底栏保持完整形态，不随滚动收缩。
/// 在这里（始终存在的容器）按连接状态驱动内核速率与日志流的启停，切走再回来数据不清零。
struct RootView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var kernel: KernelController
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connections = ConnectionsController()
    @StateObject private var proxies = ProxyController()
    @State private var previousProxyStatus: Int?

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
            case .disconnected:
                connections.reset()
            default:
                break
            }
        }
        .task(id: proxyLoadContext) {
            let context = proxyLoadContext
            if let previousProxyStatus, previousProxyStatus != context.status {
                syncProxySession(for: context.status)
            }
            previousProxyStatus = context.status
            await proxies.load()
        }
    }

    private var tabs: some View {
        TabView {
            ConnectView(connections: connections)
                .tabItem { Label("总览", systemImage: "gauge.with.dots.needle.67percent") }
            ProxiesView(controller: proxies, category: .strategy)
                .tabItem { Label("策略", systemImage: "slider.horizontal.3") }
            ProxiesView(controller: proxies, category: .node)
                .tabItem { Label("节点", systemImage: "server.rack") }
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

    private var proxyLoadContext: ProxyLoadContext {
        ProxyLoadContext(status: core.status.rawValue,
                         subscriptionID: subscriptions.selectedID,
                         configurationUpdatedAt: subscriptions.selected?.updatedAt,
                         providerRevision: subscriptions.providerCacheRevision)
    }

    private func syncProxySession(for rawStatus: Int) {
        guard let status = NEVPNStatus(rawValue: rawStatus) else { return }
        switch status {
        case .connecting:
            proxies.resetSession()
        case .disconnected, .invalid:
            proxies.clearDisconnectedSession()
        default:
            break
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
            connections.flushPersistence()
            Task { await subscriptions.flushPersistence() }
        default:
            break
        }
    }
}

private struct ProxyLoadContext: Hashable {
    let status: Int
    let subscriptionID: UUID?
    let configurationUpdatedAt: Date?
    let providerRevision: Int
}
