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
            // 底栏用 overlay 悬浮在内容之上（不占布局），各页自行在底部预留 TabBarMetrics.reserve
            // 的安全高度。早先用 safeAreaInset 包在每页 NavigationStack 外层，预留量无法传进内部的
            // 滚动视图，导致末尾内容被底栏遮住——改成「overlay 画 + 内部 inset 让位」即可。
            .overlay(alignment: .bottom) {
                FloatingTabBar(selection: $tab)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 0)
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

/// 悬浮底栏尺寸：胶囊高度(~61) + 余量，供各页底部预留安全高度。
enum TabBarMetrics {
    static let reserve: CGFloat = 66
}

extension View {
    /// 在页面（NavigationStack 内的滚动内容）底部预留悬浮底栏的高度，避免末尾内容被遮挡。
    /// 必须作用在 Form / List / ScrollView 等可滚动视图上，inset 才能转成滚动内容的底部留白。
    func floatingTabBarInset() -> some View {
        safeAreaInset(edge: .bottom) { Color.clear.frame(height: TabBarMetrics.reserve) }
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
        .modifier(GlassBarBackground())
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
    }
}

/// 底栏背景：iOS 26 用原生液态玻璃（Liquid Glass），更低版本回退毛玻璃。
/// 注意：glassEffect 需用 iOS 26 SDK（Xcode 26）编译；CI 若用旧 SDK 会报错，届时退回 else 分支即可。
private struct GlassBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06))
                )
        }
    }
}
