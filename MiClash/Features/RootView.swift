import SwiftUI

/// 根视图：悬浮底栏 + 五页（连接 / 订阅 / 节点 / 日志 / 设置）。
/// 在这里（始终存在的容器）按连接状态驱动内核速率与日志流的启停，切走再回来数据不清零。
struct RootView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var kernel: KernelController
    @EnvironmentObject private var logs: LogStreamController

    @State private var tab: Tab = .connect

    enum Tab: Int, CaseIterable, Identifiable {
        case connect, subscriptions, proxies, logs, settings
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .connect: return "连接"
            case .subscriptions: return "订阅"
            case .proxies: return "节点"
            case .logs: return "日志"
            case .settings: return "设置"
            }
        }
        var icon: String {
            switch self {
            case .connect: return "power"
            case .subscriptions: return "doc.text"
            case .proxies: return "point.3.connected.trianglepath.dotted"
            case .logs: return "list.bullet.rectangle"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        content
            .safeAreaInset(edge: .bottom) {
                FloatingTabBar(selection: $tab)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
            }
            .onChange(of: core.isActive) { _, active in
                syncStreams(active)
            }
            .onAppear { syncStreams(core.isActive) }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .connect: ConnectView()
        case .subscriptions: SubscriptionsView()
        case .proxies: ProxiesView()
        case .logs: LogsView()
        case .settings: SettingsView()
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

/// 悬浮底栏：毛玻璃胶囊 + 阴影，浮在内容上方。
private struct FloatingTabBar: View {
    @Binding var selection: RootView.Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(RootView.Tab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { selection = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 18, weight: .medium))
                        Text(tab.title)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
    }
}
