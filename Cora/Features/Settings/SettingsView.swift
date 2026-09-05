import SwiftUI
import UIKit

/// 设置页：按功能类型组织现有设置，详细说明通过名称后的信息按钮按需查看。
struct SettingsView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var configOverrides: ConfigOverrideStore
    @State private var pendingApplyError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppAmbientBackground()
                Form {
                    if settings.pendingConnectionApply || configOverrides.pendingConnectionApply {
                        Section {
                            HStack(spacing: 12) {
                                SettingsSymbol(systemImage: "arrow.triangle.2.circlepath", category: .speed)
                                Text("部分设置将在下次连接时生效。")
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if core.isActive {
                                Button {
                                    Task {
                                        let applied = await core.applyPendingSettings()
                                        if !applied {
                                            pendingApplyError = core.lastError ?? "VPN 重连失败，请稍后重试"
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Label("应用并重连", systemImage: "arrow.clockwise")
                                        Spacer()
                                        SettingsActivityIndicator(isRunning: core.isBusy)
                                    }
                                }
                                .disabled(core.isBusy)
                            } else {
                                Text("设置已保存，下一次连接 VPN 时会自动应用。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } footer: {
                            Text("应用过程中会先完整停止旧的隧道，再启动新配置，以避免内存峰值叠加。")
                        }
                        .settingsSectionStyle()
                        .transition(.opacity)
                    }

                    Section("配置") {
                        SettingsNavigationRow(
                            title: "配置与订阅",
                            systemImage: "doc.text.magnifyingglass",
                            message: "管理远程订阅、本地配置和配置覆写。",
                            destination: SubscriptionsView())
                        SettingsNavigationRow(
                            title: "远程资源",
                            systemImage: "externaldrive.connected.to.line.below",
                            message: "查看配置引用的节点来源和规则来源。节点来源可离线缓存；规则来源需连接当前配置后更新。",
                            category: .resources,
                            destination: RemoteResourcesView())
                    }
                    .settingsSectionStyle()

                    Section("运行") {
                        SettingsNavigationRow(
                            title: "内核运行",
                            systemImage: "gearshape.2",
                            message: "设置内核运行参数，并查看连接诊断。",
                            category: .graphite,
                            destination: KernelSettingsView())
                        SettingsNavigationRow(
                            title: "开发者模式",
                            systemImage: "wrench.and.screwdriver",
                            message: "按需采集和分析 Network Extension 内存快照，普通模式不会持续采样。",
                            category: .graphite,
                            destination: DeveloperDiagnosticsView())
                        SettingsNavigationRow(
                            title: "规则数据",
                            systemImage: "globe.americas",
                            message: "管理 GEO、GeoSite 和 ASN 规则数据。",
                            category: .rules,
                            destination: GeoSettingsView())
                        SettingsNavigationRow(
                            title: "隧道与隐私",
                            systemImage: "arrow.triangle.branch",
                            message: "设置流量接管范围、系统服务排除和防泄露选项。",
                            category: .privacy,
                            destination: TunnelRouteSettingsView())
                        SettingsNavigationRow(
                            title: "测速",
                            systemImage: "speedometer",
                            message: "设置测速地址和测速超时时间。",
                            category: .speed,
                            destination: DelayTestSettingsView())
                    }
                    .settingsSectionStyle()

                    Section("维护") {
                        SettingsNavigationRow(
                            title: "检测脚本",
                            systemImage: "play.tv",
                            message: "管理节点解锁检测脚本。脚本在 Cora 外部仓库维护，更新前会校验签名和摘要。",
                            category: .scripts,
                            destination: UnlockScriptSettingsView())
                        HStack(spacing: 12) {
                            SettingsSymbol(systemImage: "info.circle", category: .graphite)
                            Text("App 版本").font(.body)
                            Spacer()
                            Text(appVersion)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .frame(minHeight: 44)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 42 }
                    }
                    .settingsSectionStyle()
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .listStyle(.insetGrouped)
                .coraListSectionSpacing(12)
                .listRowSeparatorTint(Color.primary.opacity(0.08))
                .settingsChangeAnimation(value: settings.pendingConnectionApply || configOverrides.pendingConnectionApply)
            }
            .navigationTitle("设置")
            .task { await core.refreshStatus() }
            .alert("设置应用失败", isPresented: Binding(
                get: { pendingApplyError != nil },
                set: { if !$0 { pendingApplyError = nil } }
            )) {
                Button("好") { pendingApplyError = nil }
            } message: {
                Text(pendingApplyError ?? "")
            }
        }
        .environment(\.coraSettingsAppearance, true)
        .environment(\.defaultMinListRowHeight, 44)
        .tint(Color(uiColor: .systemBlue))
    }

    private var appVersion: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.6"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

struct RemoteResourcesView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var resultMessage: String?
    @State private var selectedContent: RemoteResourceContent?
    @State private var contentError: String?
    @State private var showUpdateSettings = false
    @State private var refreshingBatch: RemoteResource.Kind?
    @State private var proxyRefreshToken = 0
    @State private var ruleRefreshToken = 0
    @State private var resourceRefreshToken = 0
    @State private var refreshedResourceID: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Form {
                remoteSection(kind: .proxyProvider,
                              title: "节点来源",
                              emptyMessage: "没有远程节点来源",
                              isBatchRefreshing: refreshingBatch == .proxyProvider || proxyResources.contains {
                                  subscriptions.refreshingResourceIDs.contains($0.id)
                              },
                              now: context.date,
                              batchAction: refreshAllProxyProviders)

                remoteSection(kind: .ruleProvider,
                              title: "规则来源",
                              emptyMessage: "没有远程规则来源",
                              isBatchRefreshing: refreshingBatch == .ruleProvider || ruleResources.contains {
                                  subscriptions.refreshingResourceIDs.contains($0.id)
                              },
                              now: context.date,
                              batchAction: refreshAllRuleProviders)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .listStyle(.insetGrouped)
        .coraListSectionSpacing(12)
        .listRowSeparatorTint(Color.primary.opacity(0.08))
        .navigationTitle("远程资源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showUpdateSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("远程资源自动更新设置")
            }
        }
        .task { await refreshRuntimeResourceUpdateTimes() }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await refreshRuntimeResourceUpdateTimes() }
        }
        .alert("远程资源", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button("好") { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
        .sheet(item: $selectedContent) { content in
            RemoteResourceContentView(content: content)
        }
        .sheet(isPresented: $showUpdateSettings) {
            RemoteResourceUpdateSettingsView()
                .environmentObject(settings)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert("查看资源内容", isPresented: Binding(
            get: { contentError != nil },
            set: { if !$0 { contentError = nil } }
        )) {
            Button("好") { contentError = nil }
        } message: {
            Text(contentError ?? "")
        }
    }

    private var resources: [RemoteResource] {
        subscriptions.selectedRemoteResources
    }

    private var proxyResources: [RemoteResource] {
        resources.filter { $0.kind == .proxyProvider }
    }

    private var ruleResources: [RemoteResource] {
        resources.filter { $0.kind == .ruleProvider }
    }

    private var resourceActionsBusy: Bool {
        refreshingBatch != nil || subscriptions.isBusy ||
            !subscriptions.refreshingProviderIDs.isEmpty || !subscriptions.refreshingResourceIDs.isEmpty
    }

    @ViewBuilder
    private func remoteSection(kind: RemoteResource.Kind,
                               title: String,
                               emptyMessage: String,
                               isBatchRefreshing: Bool,
                               now: Date,
                               batchAction: @escaping () async -> Void) -> some View {
        let sectionResources = resources.filter { $0.kind == kind }
        Section {
            if sectionResources.isEmpty {
                Label(emptyMessage, systemImage: "tray")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(sectionResources) { resource in
                    RemoteResourceRow(
                        resource: resource,
                        isRefreshing: subscriptions.refreshingResourceIDs.contains(resource.id),
                        canRefresh: resource.kind == .proxyProvider ||
                            subscriptions.runtimeCanUpdateRules(for: resource.subscriptionID),
                        successToken: refreshedResourceID == resource.id ? resourceRefreshToken : 0,
                        now: now)
                    .contextMenu {
                        Button {
                            Task { await showContent(resource) }
                        } label: {
                            Label("查看资源内容", systemImage: "doc.text.magnifyingglass")
                        }
                        Button {
                            Task { await refresh(resource) }
                        } label: {
                            Label("刷新此资源", systemImage: "arrow.clockwise")
                        }
                        .disabled(resourceActionsBusy ||
                                  (resource.kind == .ruleProvider &&
                                   !subscriptions.runtimeCanUpdateRules(for: resource.subscriptionID)))
                    }
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    Task { await batchAction() }
                } label: {
                    SettingsActivityIndicator(isRunning: isBatchRefreshing,
                                              successToken: kind == .proxyProvider ? proxyRefreshToken : ruleRefreshToken,
                                              idleSystemImage: "arrow.clockwise")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("批量刷新\(title)")
                .buttonStyle(SettingsPressStyle())
                .disabled(resourceActionsBusy || sectionResources.isEmpty ||
                          (kind == .ruleProvider && !canBatchUpdateRules))
            }
        } footer: {
            if kind == .ruleProvider && !canBatchUpdateRules && !sectionResources.isEmpty {
                Text("规则来源由运行中的内核加载。连接对应的当前配置后可更新。")
            }
        }
        .settingsSectionStyle()
    }

    private var canBatchUpdateRules: Bool {
        guard let selectedID = subscriptions.selectedID else { return false }
        return subscriptions.runtimeCanUpdateRules(for: selectedID) &&
            ruleResources.contains { $0.subscriptionID == selectedID }
    }

    private func refresh(_ resource: RemoteResource) async {
        guard !resourceActionsBusy,
              resource.kind == .proxyProvider || subscriptions.runtimeCanUpdateRules(for: resource.subscriptionID)
        else { return }
        switch resource.kind {
        case .proxyProvider:
            await subscriptions.refreshProxyProvider(resource)
        case .ruleProvider:
            await subscriptions.refreshRuleProvider(resource)
        }
        resultMessage = subscriptions.lastError
        if resultMessage == nil {
            refreshedResourceID = resource.id
            resourceRefreshToken += 1
        }
    }

    private func showContent(_ resource: RemoteResource) async {
        let result = await subscriptions.readRemoteResourceContent(resource)
        switch result {
        case .content(let content):
            selectedContent = content
        case .unavailable(let message):
            contentError = message
        }
    }

    private func refreshAllProxyProviders() async {
        guard !resourceActionsBusy, !proxyResources.isEmpty else { return }
        let selectedID = subscriptions.selectedID
        refreshingBatch = .proxyProvider
        defer { refreshingBatch = nil }
        await subscriptions.refreshAllProxyProviders()
        resultMessage = subscriptions.lastError
        if resultMessage == nil, subscriptions.selectedID == selectedID { proxyRefreshToken += 1 }
    }

    private func refreshAllRuleProviders() async {
        guard !resourceActionsBusy, canBatchUpdateRules else { return }
        let selectedID = subscriptions.selectedID
        refreshingBatch = .ruleProvider
        defer { refreshingBatch = nil }
        await subscriptions.refreshAllRuleProviders()
        resultMessage = subscriptions.lastError
        if resultMessage == nil, subscriptions.selectedID == selectedID { ruleRefreshToken += 1 }
    }

    private func refreshRuntimeResourceUpdateTimes() async {
        await core.refreshStatus()
        await subscriptions.synchronizeRuntimeRemoteResourceUpdateTimes()
    }
}

private struct RemoteResourceRow: View {
    let resource: RemoteResource
    let isRefreshing: Bool
    let canRefresh: Bool
    let successToken: Int
    let now: Date
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            resourceLabel
            statusLabel
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var resourceLabel: some View {
        HStack(spacing: 12) {
            SettingsSymbol(systemImage: resource.kind == .proxyProvider
                           ? "point.3.connected.trianglepath.dotted"
                           : "list.bullet.rectangle.portrait",
                           category: resource.kind == .proxyProvider ? .resources : .rules)
            VStack(alignment: .leading, spacing: 3) {
                Text(resource.name)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(resource.subscriptionName)
                    if let host = URL(string: resource.url)?.host {
                        Text("·")
                        Text(host)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLabel: some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 5) {
            SettingsActivityIndicator(isRunning: isRefreshing, successToken: successToken)
            if !canRefresh && !isRefreshing {
                Label("待连接", systemImage: "lock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("连接对应配置后可更新")
            }

            updateText
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        }
        .frame(minWidth: 86, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
    }

    private var updateText: Text {
        guard let updatedAt = resource.updatedAt else {
            return Text("未更新")
        }
        return Text(resource.updateTimeIsApproximate ? "缓存 · " : "更新 · ")
            + Text(Self.relativeUpdateText(updatedAt, now: now))
    }

    private static func relativeUpdateText(_ date: Date, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 {
            return "刚刚"
        }
        if elapsed < 3_600 {
            return "\(Int(elapsed / 60)) 分钟前"
        }
        return "\(Int(elapsed / 3_600)) 小时前"
    }
}

private struct RemoteResourceUpdateSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private static let fixedIntervals = [6, 12, 24, 72, 168]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("更新方式", selection: $settings.remoteResourceUpdatePolicy) {
                        Text("遵从配置").tag("inherit")
                        Text("关闭自动更新").tag("disabled")
                        Text("固定间隔").tag("fixed")
                    }

                    if settings.remoteResourceUpdatePolicy == "fixed" {
                        Picker("更新间隔", selection: $settings.remoteResourceUpdateInterval) {
                            ForEach(Self.fixedIntervals, id: \.self) { hours in
                                Text(intervalText(hours)).tag(hours)
                            }
                        }
                    }
                } header: {
                    Text("自动更新")
                } footer: {
                    Text(updateDescription)
                }
                .settingsSectionStyle()
            }
            .scrollContentBackground(.hidden)
            .background(AppAmbientBackground())
            .listStyle(.insetGrouped)
            .coraListSectionSpacing(12)
            .listRowSeparatorTint(Color.primary.opacity(0.08))
            .settingsChangeAnimation(value: settings.remoteResourceUpdatePolicy)
            .navigationTitle("自动更新")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var updateDescription: String {
        switch settings.remoteResourceUpdatePolicy {
        case "disabled":
            return "关闭后不再定时检查。首次没有本地缓存时仍会下载，后续只能手动刷新。"
        case "fixed":
            return "下次连接 VPN 后，HTTP 节点来源和规则来源会由 mihomo 在扩展内每 \(intervalText(settings.remoteResourceUpdateInterval)) 原地更新，不会重载 VPN。"
        default:
            return "保留配置文件中每个 HTTP Provider 自带的 interval。配置未设置 interval 时不会自动更新。"
        }
    }

    private func intervalText(_ hours: Int) -> String {
        switch hours {
        case 72: return "3 天"
        case 168: return "7 天"
        default: return "\(hours) 小时"
        }
    }
}

private struct RemoteResourceContentView: View {
    let content: RemoteResourceContent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Text(content.content)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(AppAmbientBackground())
            .navigationTitle(content.resourceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = content.content
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("复制资源内容")
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Label(content.kind == .proxyProvider ? "节点来源" : "规则来源",
                          systemImage: content.kind == .proxyProvider ? "point.3.connected.trianglepath.dotted" : "list.bullet.rectangle.portrait")
                    Text(ByteCountFormatter.string(fromByteCount: content.size, countStyle: .file))
                    if content.isTruncated { Text("已截断") }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }
}

private struct UnlockScriptSettingsView: View {
    @ObservedObject private var scripts = ExternalScriptStore.shared
    @State private var refreshToken = 0

    var body: some View {
        Form {
            Section {
                HStack {
                    InfoLabel(title: "解锁脚本版本", message: "长按节点或分组检测时使用本地已验证的脚本版本。")
                    Spacer()
                    Text(scripts.cachedVersion ?? "未下载")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack {
                    Text("上次更新")
                    Spacer()
                    if let date = scripts.cachedUpdatedAt {
                        Text(date, style: .date)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("尚未更新")
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task { await updateScript() }
                } label: {
                    HStack {
                        Label("检查并更新脚本", systemImage: "arrow.down.circle")
                        Spacer()
                        SettingsActivityIndicator(isRunning: scripts.isUpdating, successToken: refreshToken)
                    }
                }
                .disabled(scripts.isUpdating)

                if let message = scripts.updateMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message.hasPrefix("更新失败") ? .red : .secondary)
                }
            }
            .settingsSectionStyle()

            Section("可用检测") {
                ForEach(scripts.availableScripts) { script in
                    HStack(spacing: 12) {
                        SettingsSymbol(systemImage: script.icon, category: .scripts)
                        Text(script.name)
                        Spacer()
                        Text(script.version.isEmpty ? "待更新" : script.version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .settingsSectionStyle()

            Section {
                Text("脚本只允许通过受限的 mihomo 节点请求访问检测地址，不会把检测逻辑编译进 App。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .settingsSectionStyle()
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .listStyle(.insetGrouped)
        .coraListSectionSpacing(12)
        .listRowSeparatorTint(Color.primary.opacity(0.08))
        .navigationTitle("检测脚本")
        .navigationBarTitleDisplayMode(.inline)
        .task { scripts.refreshCacheState() }
    }

    private func updateScript() async {
        do {
            _ = try await scripts.refreshAllScripts()
            refreshToken += 1
        } catch {
            // ExternalScriptStore publishes the verified failure reason and keeps the old cache.
        }
    }
}

private struct DelayTestSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("测试方式") {
                InfoToggleRow(
                    title: "统一测速地址",
                    message: "让 mihomo 的策略组使用统一的测速地址。关闭时保留配置内各策略组自带的测速地址；主 App 手动测速仍使用下方地址。",
                    isOn: $settings.unifiedDelay)
            }
            .settingsSectionStyle()

            Section("测试时限") {
                HStack {
                    InfoLabel(title: "测速超时", message: "单个节点最长等待时间。范围为 1 到 60 秒，默认 5 秒。")
                    Spacer()
                    TextField("5", value: $settings.delayTestTimeout,
                              format: IntegerFormatStyle<Int>.number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Text("秒")
                        .foregroundStyle(.secondary)
                }
            }
            .settingsSectionStyle()

            Section("测试地址") {
                DelayTestURLField(
                    title: "代理测速地址",
                    message: "普通代理节点的策略组与单节点测速使用此 HTTP 或 HTTPS 地址。留空时使用默认地址；修改后立即用于下一次测速。",
                    placeholder: SettingsStore.defaultDelayTestURL,
                    defaultValue: SettingsStore.defaultDelayTestURL,
                    text: $settings.delayTestURL)
                DelayTestURLField(
                    title: "直连测速地址",
                    message: "DIRECT 或最终落到 DIRECT 的国内直连策略使用此地址。留空时使用默认地址；不会改变普通代理节点的测速地址。",
                    placeholder: SettingsStore.defaultDirectDelayTestURL,
                    defaultValue: SettingsStore.defaultDirectDelayTestURL,
                    text: $settings.directDelayTestURL)
            }
            .settingsSectionStyle()
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .listStyle(.insetGrouped)
        .coraListSectionSpacing(12)
        .listRowSeparatorTint(Color.primary.opacity(0.08))
        .navigationTitle("测速")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DelayTestURLField: View {
    let title: String
    let message: String
    let placeholder: String
    let defaultValue: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            InfoLabel(title: title, message: message)
                .font(.body.weight(.medium))
            HStack(alignment: .top, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .font(.footnote.monospaced())
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1...3)
                Button {
                    text = defaultValue
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("恢复默认地址")
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private var validationMessage: String? {
        SettingsStore.httpURLValidationMessage(text)
    }
}

private struct KernelSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var core: CoreStateManager
    @State private var isKernelAvailable = false
    @State private var isCheckingKernel = true

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.logLevel) {
                    Text("静默").tag("silent")
                    Text("仅错误").tag("error")
                    Text("警告").tag("warning")
                    Text("信息").tag("info")
                    Text("调试").tag("debug")
                } label: {
                    InfoLabel(title: "日志级别", message: "控制内核输出的日志详细程度。修改后重新连接 VPN 生效。")
                }
                HStack {
                    InfoLabel(title: "TCP 栈", message: "iOS Network Extension 仅使用经过验证的 gVisor 栈。system 和 mixed 在本项目中可能导致连接后无网络，因此不提供切换。")
                    Spacer()
                    Text("gVisor")
                        .foregroundStyle(.secondary)
                }
                InfoToggleRow(title: "IPv6", message: "允许隧道处理 IPv6 流量。部分网络或配置不支持 IPv6 时可以关闭。", systemImage: "network", isOn: $settings.ipv6)
                HStack {
                    Label {
                        InfoLabel(title: "本机代理端口", message: "在本机回环监听 HTTP+SOCKS 混合代理端口，设为 0 表示关闭。")
                    } icon: {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                    }
                    Spacer()
                    TextField("0=不开", value: $settings.mixedPort,
                              format: IntegerFormatStyle<Int>.number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
            }
            .settingsSectionStyle()

            Section {
                NavigationLink {
                    KernelStatusView()
                } label: {
                    HStack {
                        InfoLabel(title: "连接诊断", message: "检查 App 与隧道扩展之间的控制通道和当前内核响应。")
                        Spacer()
                        if isCheckingKernel {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: isKernelAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(isKernelAvailable ? Color.green : Color.secondary)
                                .accessibilityLabel(isKernelAvailable ? "内核可用" : "内核不可用")
                        }
                    }
                }
                HStack {
                    InfoLabel(title: "内核版本", message: "当前由隧道扩展运行的 mihomo 内核版本。")
                    Spacer()
                    Text(core.coreVersion)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
            }
            .settingsSectionStyle()
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .listStyle(.insetGrouped)
        .coraListSectionSpacing(12)
        .listRowSeparatorTint(Color.primary.opacity(0.08))
        .navigationTitle("内核运行")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: core.status.rawValue) { await refreshKernelAvailability() }
    }

    private func refreshKernelAvailability() async {
        guard core.status == .connected || core.status == .reasserting else {
            isKernelAvailable = false
            isCheckingKernel = false
            return
        }
        isCheckingKernel = true
        let result = await CoreStateManager.shared.sendMessage(["cmd": "hello"])
        guard !Task.isCancelled else { return }
        if case .ok = result {
            isKernelAvailable = true
        } else {
            isKernelAvailable = false
        }
        isCheckingKernel = false
    }
}

private struct GeoSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var geoDatabase: GeoDatabaseManager
    @State private var installedInfo: GeoInstalledInfo?

    var body: some View {
        Form {
            GeoSettingsContent(installedInfo: installedInfo)
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .listStyle(.insetGrouped)
        .coraListSectionSpacing(12)
        .listRowSeparatorTint(Color.primary.opacity(0.08))
        .settingsChangeAnimation(value: settings.geoEnabled)
        .settingsChangeAnimation(value: settings.geoAutoUpdate)
        .settingsChangeAnimation(value: settings.geodataMode)
        .navigationTitle("规则数据")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: refreshID) { await refreshInstalledInfo() }
    }

    private var refreshID: String {
        "\(settings.geoEnabled)-\(settings.geodataMode)-\(geoDatabase.revision)"
    }

    private func refreshInstalledInfo() async {
        guard settings.geoEnabled else {
            installedInfo = nil
            return
        }
        installedInfo = nil
        let info = await geoDatabase.installedInfo(geodataMode: settings.geodataMode)
        guard !Task.isCancelled else { return }
        installedInfo = info
    }
}

private struct TunnelRouteSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var core: CoreStateManager
    @State private var isUpdatingAutoConnect = false
    @State private var autoConnectError: String?

    var body: some View {
        Form {
            Section {
                InfoToggleRow(title: "接管全部流量", message: "将系统默认排除的流量也纳入隧道。只有需要完整 VPN 覆盖时才建议开启。", systemImage: "network", isOn: $settings.includeAllNetworks)
                InfoToggleRow(title: "强制路由", message: "即使未接管全部流量，也强制按规则路由隧道流量。", systemImage: "arrow.triangle.branch", isOn: $settings.enforceRoutes)
            } header: {
                Text("流量接管")
            } footer: {
                if settings.includeAllNetworks {
                    Text("完整接管可能影响局域网、系统服务和电池消耗；系统服务排除项仍按下方设置处理。")
                } else if settings.enforceRoutes {
                    Text("强制路由只影响进入隧道的流量，不会把系统默认排除的流量纳入隧道。")
                } else {
                    Text("修改后需要重新连接 VPN 才会更新系统路由。")
                }
            }
            .settingsSectionStyle()

            Section("系统服务") {
                InfoToggleRow(title: "排除蜂窝服务", message: "将蜂窝网络服务排除在隧道之外，避免影响系统电话和运营商服务。", systemImage: "antenna.radiowaves.left.and.right", isOn: $settings.excludeCellularServices)
                InfoToggleRow(title: "排除 Apple 推送", message: "将 Apple 推送服务排除在隧道之外，保持系统通知稳定。", systemImage: "bell.badge", isOn: $settings.excludeAPNs)
                if #available(iOS 17.4, *) {
                    InfoToggleRow(title: "排除设备间通信", message: "将本地设备间通信排除在隧道之外，保留 AirDrop 和附近设备连接。", systemImage: "person.2", isOn: $settings.excludeDeviceCommunication)
                }
            }
            .settingsSectionStyle()

            Section("隐私防护") {
                InfoToggleRow(title: "防止 WebRTC 泄露", message: "仅阻止常见公网 STUN 探测端点以降低 WebRTC 泄露风险，不封锁普通 DIRECT 的语音、视频和 P2P 流量。", systemImage: "lock.shield", isOn: $settings.blockDirectSTUN)
            }
            .settingsSectionStyle()

            Section("自动连接") {
                InfoToggleRow(
                    title: "自动连接 VPN",
                    message: "使用 iOS Connect On Demand，在重启或网络变化后自动连接。通过 Cora 控制中心按钮关闭时会暂停自动连接；苹果受监管设备的真正 Always-On VPN 仍需 MDM。",
                    systemImage: "bolt.shield",
                    isOn: alwaysOnBinding)
                    .disabled(isUpdatingAutoConnect)
            }
            .settingsSectionStyle()
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .listStyle(.insetGrouped)
        .coraListSectionSpacing(12)
        .listRowSeparatorTint(Color.primary.opacity(0.08))
        .navigationTitle("隧道与隐私")
        .navigationBarTitleDisplayMode(.inline)
        .alert("自动连接设置失败", isPresented: Binding(
            get: { autoConnectError != nil },
            set: { if !$0 { autoConnectError = nil } }
        )) {
            Button("好") { autoConnectError = nil }
        } message: {
            Text(autoConnectError ?? "")
        }
    }

    private var alwaysOnBinding: Binding<Bool> {
        Binding(
            get: { settings.alwaysOnVPN },
            set: { value in
                guard !isUpdatingAutoConnect else { return }
                isUpdatingAutoConnect = true
                Task {
                    let applied = await core.setAlwaysOnVPN(value)
                    if !applied {
                        autoConnectError = core.lastError ?? "请先连接一次 VPN，再启用自动连接"
                    }
                    isUpdatingAutoConnect = false
                }
            })
    }
}

struct SettingsNavigationRow<Destination: View>: View {
    let title: String
    let systemImage: String
    let message: String
    var category: SettingsCategory = .configuration
    let destination: Destination
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            NavigationLink {
                destination.environment(\.settingsCategory, category)
            } label: {
                HStack(spacing: 12) {
                    SettingsSymbol(systemImage: systemImage, category: category)
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsPressStyle())
            InfoButton(message: message, accessibilityLabel: "查看\(title)说明")
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in iconSize + 12 }
    }
}

struct SettingsSymbol: View {
    let systemImage: String
    var category: SettingsCategory? = nil
    @Environment(\.settingsCategory) private var inheritedCategory
    @Environment(\.settingsIconPressed) private var isPressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle((category ?? inheritedCategory).iconForeground)
            .frame(width: size, height: size)
            .background((category ?? inheritedCategory).color,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.8), value: isPressed)
            .accessibilityHidden(true)
    }
}

private struct GeoSettingsContent: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var geoDatabase: GeoDatabaseManager
    let installedInfo: GeoInstalledInfo?
    @State private var refreshToken = 0

    var body: some View {
        Section("启用与状态") {
            InfoToggleRow(
                title: "使用 GEO 规则",
                message: "使用 GeoIP、GeoSite 和 ASN 数据解析配置中的 GEO 规则。关闭后不会删除已下载的数据。",
                isOn: $settings.geoEnabled)

            if settings.geoEnabled {
                if AppGroup.containerURL == nil {
                    Label("签名未授予 \(AppGroup.identifier)，连接时会自动忽略 GEO/ASN 规则。",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if AppGroup.usesTrollStoreFallback {
                    Label("正在使用 TrollStore 共享目录",
                          systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } else {
                Label("关闭后将忽略配置中的 GEO/ASN 规则。",
                      systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsSectionStyle()

        if settings.geoEnabled {
            Section("加载格式") {
                Picker(selection: $settings.geoLoader) {
                    Text("内存保守").tag("memconservative")
                    Text("标准").tag("standard")
                } label: {
                    InfoLabel(title: "加载方式", message: "控制规则数据被内核读取的方式。更改后在下一次连接时生效。")
                }
                Picker(selection: $settings.geodataMode) {
                    Text("GeoIP.dat").tag(true)
                    Text("MMDB").tag(false)
                } label: {
                    InfoLabel(title: "GeoIP 数据格式", message: "选择内核读取的 GeoIP 数据格式。切换后需要重新连接，下载地址也会随格式切换。")
                }
                InfoToggleRow(
                    title: "忽略 GEO 取反规则",
                    message: "忽略配置中以 GEO 规则取反的匹配条件。",
                    isOn: $settings.ignoreGeoNegation)
            }
            .settingsSectionStyle()

            Section("本地数据") {
                if let installedInfo {
                    HStack(spacing: 10) {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ByteFormat.size(installedInfo.size))
                                .font(.body.weight(.medium))
                            Text("更新于 \(installedInfo.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } else {
                    Label("尚未下载规则数据", systemImage: "internaldrive")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await updateGeo() }
                } label: {
                    HStack {
                        Label("立即更新规则数据", systemImage: "arrow.down.circle")
                        Spacer()
                        SettingsActivityIndicator(isRunning: geoDatabase.isUpdating, successToken: refreshToken)
                    }
                }
                .disabled(geoDatabase.isUpdating)
                if let result = geoDatabase.statusText {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(geoDatabase.statusIsError ? Color.red : Color.secondary)
                }
            }
            .settingsSectionStyle()

            Section("更新策略") {
                InfoToggleRow(
                    title: "自动更新",
                    message: "App 启动时和下一次连接 VPN 前按设定间隔检查并下载规则数据。App 被划掉且 VPN 持续运行时不会单独启动后台下载。",
                    isOn: $settings.geoAutoUpdate)
                if settings.geoAutoUpdate {
                    Stepper(value: $settings.geoUpdateInterval, in: 1...168) {
                        HStack {
                            InfoLabel(title: "更新间隔", message: "可设置为 1 到 168 小时。")
                            Spacer()
                            Text("\(settings.geoUpdateInterval) 小时")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .settingsSectionStyle()

            Section("下载来源") {
                if settings.geodataMode {
                    GeoURLField(title: "GeoIP 下载地址", defaultValue: SettingsStore.defaultGeoIPDatURL, text: $settings.geoIPDatURL)
                } else {
                    GeoURLField(title: "MMDB 下载地址", defaultValue: SettingsStore.defaultGeoMMDBURL, text: $settings.geoMMDBURL)
                }
                GeoURLField(title: "GeoSite 下载地址", defaultValue: SettingsStore.defaultGeoSiteURL, text: $settings.geoSiteURL)
            }
            .settingsSectionStyle()
        }
    }

    private func updateGeo() async {
        do {
            try await geoDatabase.updateManually()
            refreshToken += 1
        } catch {
            // 具体错误由 GeoDatabaseManager 发布到设置页。
        }
    }
}

private struct GeoURLField: View {
    let title: String
    let defaultValue: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body.weight(.medium))
            HStack(alignment: .top, spacing: 8) {
                TextField(title, text: $text, axis: .vertical)
                    .font(.footnote.monospaced())
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1...3)
                Button {
                    text = defaultValue
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("恢复默认地址")
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private var validationMessage: String? {
        SettingsStore.httpURLValidationMessage(text)
    }
}

struct InfoLabel: View {
    let title: String
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            InfoButton(message: message, accessibilityLabel: "查看\(title)说明")
        }
    }
}

struct InfoButton: View {
    let message: String
    var accessibilityLabel = "查看说明"
    @State private var showingInfo = false

    var body: some View {
        Button {
            showingInfo = true
        } label: {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $showingInfo, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .presentationCompactAdaptation(.popover)
        }
    }
}

struct SettingsInfoRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
            Spacer(minLength: 8)
            InfoButton(message: message, accessibilityLabel: "查看\(title)说明")
        }
    }
}

struct InfoToggleRow: View {
    let title: String
    let message: String
    let systemImage: String?
    @Binding var isOn: Bool

    init(title: String, message: String, systemImage: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                SettingsSymbol(systemImage: systemImage)
            }
            InfoLabel(title: title, message: message)
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Color(uiColor: .systemGreen))
                .accessibilityLabel(title)
        }
        .frame(minHeight: 44)
    }
}

/// 内核状态页：验证 App 与 Tunnel 之间的主控制通道。
private struct KernelStatusView: View {
    @State private var text = "探测中…"

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
        }
        .background(AppAmbientBackground())
        .navigationTitle("内核状态")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("刷新") { Task { await reload() } } }
        .task { await reload() }
    }

    private func reload() async {
        text = "探测中…"
        let transport = TrollStoreIPC.isEnabled
            ? "TrollStore 文件 IPC"
            : "sendProviderMessage IPC"
        var out = "（请在 VPN 已连接时探测）\n\n【\(transport)】\n"
        let hello = await CoreStateManager.shared.sendMessage(["cmd": "hello"])
        if case .ok(let data) = hello,
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            out += "协议 v\((object["protocolVersion"] as? NSNumber)?.intValue ?? 0)，"
                + "内核 \(object["coreVersion"] as? String ?? "?")\n"
        }
        let ipc = await CoreStateManager.shared.sendMessage(["cmd": "queryProxies"])
        switch ipc {
        case .ok(let data):
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let proxies = (obj?["proxies"] as? [String: Any]) ?? [:]
            let groupCount = proxies.values.compactMap { ($0 as? [String: Any])?["all"] }.count
            out += "✅ 可用，queryProxies 回 \(data.count) 字节，策略组 \(groupCount)\n"
        case .failure(let reason):
            out += "❌ \(reason)\n"
        }

        text = out
    }
}
