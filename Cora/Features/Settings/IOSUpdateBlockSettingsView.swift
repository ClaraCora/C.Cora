import SwiftUI

struct IOSUpdateBlockSettingsEntry: View {
    @ObservedObject private var store = IOSUpdateBlockStore.shared
    @EnvironmentObject private var core: CoreStateManager
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            NavigationLink {
                IOSUpdateBlockSettingsView()
            } label: {
                HStack(spacing: 12) {
                    SettingsSymbol(systemImage: "hand.raised.shield", category: .privacy)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("iOS 更新拦截").font(.body).foregroundStyle(.primary)
                        Text(store.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    SettingsActivityIndicator(isRunning: store.isSaving)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsPressStyle())
            InfoButton(message: "仅拦截经过 VPN 的两个 Apple 更新目录域名。可查看真实 DNS 和连接拒绝计数。系统缓存仍可能显示可用版本；本功能不会清除已下载的更新，也不会改变流量接管设置。",
                       accessibilityLabel: "查看 iOS 更新拦截说明")
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in iconSize + 12 }
        .task(id: "\(scenePhase)-\(core.status.rawValue)") {
            guard scenePhase == .active else { return }
            await store.refresh() // One read; polling belongs to the visible subpage.
        }
    }
}

struct IOSUpdateBlockSettingsView: View {
    @ObservedObject private var store = IOSUpdateBlockStore.shared
    @EnvironmentObject private var core: CoreStateManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    private let domains = [("gdmf.apple.com", "软件更新目录"), ("mesu.apple.com", "软件更新目录与元数据")]

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { store.configuration.enabled }, set: { enabled in
                    Task { await store.setEnabled(enabled) }
                })) {
                    HStack(spacing: 12) {
                        SettingsSymbol(systemImage: "hand.raised.shield", category: .privacy)
                        Text("拦截更新检查")
                    }
                }
                .disabled(store.isSaving)
                LabeledContent("已保存设置", value: store.configuration.enabled ? "开启" : "关闭")
                LabeledContent {
                    HStack(spacing: 6) {
                        SettingsActivityIndicator(isRunning: store.isSaving)
                        Text(store.summary).foregroundStyle(.secondary)
                    }
                } label: { Text("VPN 生效状态") }
                if let message = store.message {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.isReady && (!store.isSynchronized || store.message != nil) {
                    Button("重试同步") { Task { await store.retry() } }
                        .disabled(store.isSaving || store.isRefreshing)
                }
            } header: {
                Text("功能与状态")
            } footer: {
                Text("开启后立即应用，无需重连 VPN。退出 App 后仍会拦截；VPN 停止后不生效。")
            }
            .settingsSectionStyle()

            Section {
                ForEach(domains, id: \.0) { domain, _ in
                    domainStatistics(domain)
                }
                if store.snapshot?.hasHits != true {
                    Text(!store.isReady ? "连接 VPN 后可查看本次会话的实际拦截记录"
                         : store.snapshot == nil ? "尚未读取统计，请刷新或重试同步"
                         : "尚未观察到请求，请到系统设置检查更新后返回查看")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("刷新统计", systemImage: "arrow.clockwise")
                }
                .disabled(!store.isReady || store.isSaving || store.isRefreshing)
                Button("清空本次统计") { Task { await store.resetStats() } }
                    .disabled(!store.isReady || store.isSaving || store.isRefreshing || store.snapshot?.hasHits != true)
            } header: {
                Text("实际拦截")
            } footer: {
                Text("仅统计本次 VPN 会话中的域名请求，不能据此判断更新次数或请求进程。刷新只读取统计；清空统计不会关闭拦截。")
            }
            .settingsSectionStyle()

            Section {
                ForEach(domains, id: \.0) { domain, purpose in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(domain).font(.subheadline.monospaced()).textSelection(.enabled)
                        Text(purpose).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("拦截范围")
            } footer: {
                Text("仅精确匹配以上两个域名。DNS 返回 REFUSED；已知域名的连接在规则、全局和直连模式下均拒绝。不封锁下载 CDN、共享 IP 或其他 Apple 域名。目录服务可能兼用于部分系统资源查询。")
            }
            .settingsSectionStyle()

            Section {
                if let coverage = store.snapshot?.coverage, store.isReady {
                    LabeledContent("当前流量接管", value: coverage.includeAllNetworks ? "接管全部流量" : "沿用默认接管")
                    LabeledContent("强制路由", value: coverage.enforceRoutes ? "开启" : "关闭")
                    LabeledContent("IPv6 隧道", value: coverage.ipv6 ? "开启" : "关闭")
                    LabeledContent("排除蜂窝服务", value: coverage.excludeCellularServices ? "开启" : "关闭")
                    LabeledContent("排除 Apple 推送", value: coverage.excludeAPNs ? "开启" : "关闭")
                    if #available(iOS 17.4, *) {
                        LabeledContent("排除设备间通信", value: coverage.excludeDeviceCommunication ? "开启" : "关闭")
                    }
                } else {
                    Text("连接后读取当前 VPN 实际生效的路由与 IPv6 设置")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                NavigationLink("隧道与隐私") { TunnelRouteSettingsView() }
            } header: {
                Text("覆盖与验证")
            } footer: {
                Text("本功能沿用现有流量接管设置。绕过隧道或无法还原域名的纯 IP 请求不会被扩大封锁。iOS 缓存的版本信息仍可能显示，不能保证“软件更新”出现“无法连接”；已下载更新也无法由 Cora 清除或阻止安装。请以实际拒绝记录判断请求是否被拦截。")
            }
            .settingsSectionStyle()
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .listStyle(.insetGrouped)
        .coraListSectionSpacing(12)
        .listRowSeparatorTint(Color.primary.opacity(0.08))
        .navigationTitle("iOS 更新拦截")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.coraSettingsAppearance, true)
        .environment(\.settingsCategory, .privacy)
        .environment(\.defaultMinListRowHeight, 44)
        .tint(Color(uiColor: .systemBlue))
        .settingsChangeAnimation(value: store.isSaving)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: "\(isVisible)-\(scenePhase)-\(core.status.rawValue)") {
            store.connectionChanged()
            guard isVisible, scenePhase == .active, store.isReady else { return }
            while !Task.isCancelled {
                await store.refresh()
                do { try await Task.sleep(nanoseconds: 3_000_000_000) }
                catch { return }
            }
        }
    }

    private func domainStatistics(_ domain: String) -> some View {
        let entry = store.snapshot?.domains.first { $0.domain == domain }
        return VStack(alignment: .leading, spacing: 8) {
            Text(domain).font(.subheadline.monospaced()).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    statistic("DNS 拒绝", count: entry?.dnsRefused)
                    statistic("连接拒绝", count: entry?.connectionsRejected)
                }
                VStack(alignment: .leading, spacing: 6) {
                    statistic("DNS 拒绝", count: entry?.dnsRefused)
                    statistic("连接拒绝", count: entry?.connectionsRejected)
                }
            }
            if let lastHit = entry?.lastHit {
                Text("最后命中：\(lastHit.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(entry == nil ? "尚未读取统计" : "暂无命中")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func statistic(_ title: String, count: UInt64?) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(count.map { String($0) } ?? "—").monospacedDigit()
        }
        .font(.subheadline)
    }
}
