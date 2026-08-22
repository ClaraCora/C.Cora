import SwiftUI
import UIKit

/// 设置页：按功能类型组织现有设置，详细说明通过名称后的信息按钮按需查看。
struct SettingsView: View {
    @EnvironmentObject private var core: CoreStateManager
    var body: some View {
        NavigationStack {
            ZStack {
                AppAmbientBackground()
                Form {
                    Section {
                        SettingsNavigationRow(
                            title: "配置与订阅",
                            systemImage: "doc.text.magnifyingglass",
                            message: "管理远程订阅、本地配置和配置覆写。",
                            destination: SubscriptionsView())
                    }
                    .listRowBackground(AppListRowBackground())

                    Section {
                        SettingsNavigationRow(
                            title: "远程资源",
                            systemImage: "externaldrive.connected.to.line.below",
                            message: "查看配置引用的节点来源和规则来源。节点来源可离线缓存；规则来源需连接当前配置后更新。",
                            destination: RemoteResourcesView())
                    }
                    .listRowBackground(AppListRowBackground())

                    Section {
                        SettingsNavigationRow(
                            title: "内核运行",
                            systemImage: "gearshape.2",
                            message: "设置内核运行参数，并查看连接诊断。",
                            destination: KernelSettingsView())
                        SettingsNavigationRow(
                            title: "规则数据",
                            systemImage: "globe.americas",
                            message: "管理 GEO、GeoSite 和 ASN 规则数据。",
                            destination: GeoSettingsView())
                        SettingsNavigationRow(
                            title: "隧道与隐私",
                            systemImage: "arrow.triangle.branch",
                            message: "设置流量接管范围、系统服务排除和防泄露选项。",
                            destination: TunnelRouteSettingsView())
                        SettingsNavigationRow(
                            title: "测速",
                            systemImage: "speedometer",
                            message: "设置测速地址和测速超时时间。",
                            destination: DelayTestSettingsView())
                    }
                    .listRowBackground(AppListRowBackground())

                    Section {
                        SettingsNavigationRow(
                            title: "检测脚本",
                            systemImage: "play.tv",
                            message: "管理节点解锁检测脚本。脚本在 Cora 外部仓库维护，更新前会校验签名和摘要。",
                            destination: UnlockScriptSettingsView())
                    }
                    .listRowBackground(AppListRowBackground())

                    Section {
                        HStack(spacing: 12) {
                            SettingsSymbol(systemImage: "info.circle")
                            Text("App 版本").font(.body.weight(.medium))
                            Spacer()
                            Text(appVersion)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .listRowBackground(AppListRowBackground())
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .listStyle(.insetGrouped)
                .listSectionSpacing(18)
                .listRowSeparatorTint(Color.primary.opacity(0.08))
            }
            .navigationTitle("设置")
            .task { await core.refreshStatus() }
        }
    }

    private var appVersion: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.3"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

struct RemoteResourcesView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var core: CoreStateManager
    @State private var resultMessage: String?
    @State private var selectedContent: RemoteResourceContent?
    @State private var contentError: String?

    var body: some View {
        Form {
            remoteSection(kind: .proxyProvider,
                          title: "节点来源",
                          emptyMessage: "没有远程节点来源",
                          isBatchRefreshing: proxyResources.contains {
                              subscriptions.refreshingResourceIDs.contains($0.id)
                          },
                          batchAction: refreshAllProxyProviders)

            remoteSection(kind: .ruleProvider,
                          title: "规则来源",
                          emptyMessage: "没有远程规则来源",
                          isBatchRefreshing: ruleResources.contains {
                              subscriptions.refreshingResourceIDs.contains($0.id)
                          },
                          batchAction: refreshAllRuleProviders)
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("远程资源")
        .navigationBarTitleDisplayMode(.inline)
        .task { await core.refreshStatus() }
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
        subscriptions.remoteResources()
    }

    private var proxyResources: [RemoteResource] {
        resources.filter { $0.kind == .proxyProvider }
    }

    private var ruleResources: [RemoteResource] {
        resources.filter { $0.kind == .ruleProvider }
    }

    @ViewBuilder
    private func remoteSection(kind: RemoteResource.Kind,
                               title: String,
                               emptyMessage: String,
                               isBatchRefreshing: Bool,
                               batchAction: @escaping () async -> Void) -> some View {
        let sectionResources = resources.filter { $0.kind == kind }
        Section {
            if sectionResources.isEmpty {
                Label(emptyMessage, systemImage: "tray")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sectionResources) { resource in
                    RemoteResourceRow(
                        resource: resource,
                        isRefreshing: subscriptions.refreshingResourceIDs.contains(resource.id),
                        canRefresh: resource.kind == .proxyProvider ||
                            subscriptions.runtimeCanUpdateRules(for: resource.subscriptionID))
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
                        .disabled(subscriptions.refreshingResourceIDs.contains(resource.id) ||
                                  (resource.kind == .ruleProvider &&
                                   !subscriptions.runtimeCanUpdateRules(for: resource.subscriptionID)))
                    }
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if isBatchRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 44, height: 44)
                } else {
                    Button {
                        Task { await batchAction() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("批量刷新\(title)")
                    .disabled(sectionResources.isEmpty ||
                              (kind == .ruleProvider && !canBatchUpdateRules))
                }
            }
        } footer: {
            if kind == .ruleProvider && !canBatchUpdateRules && !sectionResources.isEmpty {
                Text("规则来源由运行中的内核加载。连接对应的当前配置后可更新。")
            }
        }
        .listRowBackground(AppListRowBackground())
    }

    private var canBatchUpdateRules: Bool {
        guard let selectedID = subscriptions.selectedID else { return false }
        return subscriptions.runtimeCanUpdateRules(for: selectedID) &&
            ruleResources.contains { $0.subscriptionID == selectedID }
    }

    private func refresh(_ resource: RemoteResource) async {
        switch resource.kind {
        case .proxyProvider:
            await subscriptions.refreshProxyProvider(resource)
        case .ruleProvider:
            await subscriptions.refreshRuleProvider(resource)
        }
        resultMessage = subscriptions.lastError ?? "\(resource.name) 已刷新"
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
        await subscriptions.refreshAllProxyProviders()
        resultMessage = subscriptions.lastError ?? "节点来源已全部刷新"
    }

    private func refreshAllRuleProviders() async {
        await subscriptions.refreshAllRuleProviders()
        resultMessage = subscriptions.lastError ?? "当前配置的规则来源已全部更新"
    }
}

private struct RemoteResourceRow: View {
    let resource: RemoteResource
    let isRefreshing: Bool
    let canRefresh: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: resource.kind == .proxyProvider
                  ? "point.3.connected.trianglepath.dotted"
                  : "list.bullet.rectangle.portrait")
                .foregroundStyle(resource.kind == .proxyProvider ? Color.blue : Color.orange)
                .frame(width: 28)
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
            Spacer(minLength: 8)
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else if !canRefresh {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("连接对应配置后可更新")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
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
                ToolbarItem(placement: .topBarTrailing) {
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

    var body: some View {
        Form {
            Section {
                HStack {
                    InfoLabel(title: "当前版本", message: "长按节点或分组进行解锁测试时使用本地已验证的脚本版本。")
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
                        if scripts.isUpdating {
                            ProgressView()
                        }
                    }
                }
                .disabled(scripts.isUpdating)

                if let message = scripts.updateMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message.hasPrefix("更新失败") ? .red : .secondary)
                }
            }
            .listRowBackground(AppListRowBackground())

            Section {
                Text("脚本只允许通过受限的 mihomo 节点请求访问检测地址，不会把检测逻辑编译进 App。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("检测脚本")
        .navigationBarTitleDisplayMode(.inline)
        .task { scripts.refreshCacheState() }
    }

    private func updateScript() async {
        do {
            _ = try await scripts.refreshUnlockScript()
        } catch {
            // ExternalScriptStore publishes the verified failure reason and keeps the old cache.
        }
    }
}

private struct DelayTestSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                InfoToggleRow(
                    title: "统一测速地址",
                    message: "让 mihomo 的策略组使用统一的测速地址。关闭时保留配置内各策略组自带的测速地址；主 App 手动测速仍使用下方地址。",
                    isOn: $settings.unifiedDelay)

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
            .listRowBackground(AppListRowBackground())

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    InfoLabel(title: "代理测速地址", message: "普通代理节点的策略组与单节点测速使用此 HTTP 或 HTTPS 地址。留空时使用默认地址；修改后立即用于下一次测速。")
                    TextField(SettingsStore.defaultDelayTestURL,
                              text: $settings.delayTestURL,
                              axis: .vertical)
                        .font(.footnote.monospaced())
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                }
                .padding(.vertical, 2)
            }
            .listRowBackground(AppListRowBackground())

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    InfoLabel(title: "直连测速地址", message: "DIRECT 或最终落到 DIRECT 的国内直连策略使用此地址。留空时使用默认地址；不会改变普通代理节点的测速地址。")
                    TextField(SettingsStore.defaultDirectDelayTestURL,
                              text: $settings.directDelayTestURL,
                              axis: .vertical)
                        .font(.footnote.monospaced())
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                }
                .padding(.vertical, 2)
            }
            .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("测速")
        .navigationBarTitleDisplayMode(.inline)
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
                    ForEach(SettingsStore.logLevelOptions, id: \.self) { Text($0).tag($0) }
                } label: {
                    InfoLabel(title: "日志级别", message: "控制内核输出的日志详细程度。修改后重新连接 VPN 生效。")
                }
                InfoToggleRow(title: "IPv6", message: "允许隧道处理 IPv6 流量。部分网络或配置不支持 IPv6 时可以关闭。", systemImage: "network", isOn: $settings.ipv6)
                InfoToggleRow(
                    title: "Snell 自适应 TFO",
                    message: "在蜂窝网络上分别测试每个 Snell 入口。仅当某个入口的 TFO 失败而普通 TCP 可用时，临时对该入口回退普通 TCP，其他入口和 Wi-Fi 仍使用 TFO；10 分钟后自动重试。修改后重新连接 VPN 生效。",
                    systemImage: "antenna.radiowaves.left.and.right",
                    isOn: $settings.cellularSnellCompatibility)
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
            .listRowBackground(AppListRowBackground())

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
                            Text(isKernelAvailable ? "✅" : "❌")
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
            .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
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
                .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
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

    var body: some View {
        Form {
            Section("流量接管") {
                InfoToggleRow(title: "接管全部流量", message: "将系统默认排除的流量也纳入隧道。只有需要完整 VPN 覆盖时才建议开启。", systemImage: "network", isOn: $settings.includeAllNetworks)
                InfoToggleRow(title: "强制路由", message: "即使未接管全部流量，也强制按规则路由隧道流量。", systemImage: "arrow.triangle.branch", isOn: $settings.enforceRoutes)
            }
            .listRowBackground(AppListRowBackground())

            Section("系统服务") {
                InfoToggleRow(title: "排除蜂窝服务", message: "将蜂窝网络服务排除在隧道之外，避免影响系统电话和运营商服务。", systemImage: "antenna.radiowaves.left.and.right", isOn: $settings.excludeCellularServices)
                InfoToggleRow(title: "排除 Apple 推送", message: "将 Apple 推送服务排除在隧道之外，保持系统通知稳定。", systemImage: "bell.badge", isOn: $settings.excludeAPNs)
                if #available(iOS 17.4, *) {
                    InfoToggleRow(title: "排除设备间通信", message: "将本地设备间通信排除在隧道之外，保留 AirDrop 和附近设备连接。", systemImage: "person.2", isOn: $settings.excludeDeviceCommunication)
                }
            }
            .listRowBackground(AppListRowBackground())

            Section("隐私防护") {
                InfoToggleRow(title: "防止 WebRTC 泄露", message: "仅阻止常见公网 STUN 探测端点以降低 WebRTC 泄露风险，不封锁普通 DIRECT 的语音、视频和 P2P 流量。", systemImage: "lock.shield", isOn: $settings.blockDirectSTUN)
            }
            .listRowBackground(AppListRowBackground())

            Section("自动连接") {
                InfoToggleRow(
                    title: "自动连接 VPN",
                    message: "使用 iOS Connect On Demand，在重启或网络变化后自动连接。通过 Cora 控制中心按钮关闭时会暂停自动连接；苹果受监管设备的真正 Always-On VPN 仍需 MDM。",
                    systemImage: "bolt.shield",
                    isOn: Binding(
                        get: { settings.alwaysOnVPN },
                        set: { value in
                            Task { await core.setAlwaysOnVPN(value) }
                        }))
            }
            .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("隧道与隐私")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SettingsNavigationRow<Destination: View>: View {
    let title: String
    let systemImage: String
    let message: String
    let destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 12) {
                SettingsSymbol(systemImage: systemImage)
                Text(title)
                    .font(.body.weight(.medium))
                InfoButton(message: message, accessibilityLabel: "查看\(title)说明")
            }
            .padding(.vertical, 4)
        }
    }
}

struct SettingsSymbol: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color.accentColor)
            .frame(width: 30, height: 30)
            .background(.thinMaterial,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.16), lineWidth: 0.6)
            }
    }
}

private struct GeoSettingsContent: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var geoDatabase: GeoDatabaseManager
    let installedInfo: GeoInstalledInfo?

    var body: some View {
        Group {
            Toggle("使用 GEO 规则", isOn: $settings.geoEnabled)
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
                Picker("加载方式", selection: $settings.geoLoader) {
                    ForEach(SettingsStore.geoLoaderOptions, id: \.self) { Text($0).tag($0) }
                }
                Toggle("GeoIP 数据格式", isOn: $settings.geodataMode)
                Toggle("忽略 GEO 取反规则", isOn: $settings.ignoreGeoNegation)
                if settings.geodataMode {
                    GeoURLField(title: "GeoIP 下载地址", text: $settings.geoIPDatURL)
                } else {
                    GeoURLField(title: "MMDB 下载地址", text: $settings.geoMMDBURL)
                }
                GeoURLField(title: "GeoSite 下载地址", text: $settings.geoSiteURL)
                Toggle("自动更新", isOn: $settings.geoAutoUpdate)
                if settings.geoAutoUpdate {
                    Stepper("更新间隔 \(settings.geoUpdateInterval) 小时",
                            value: $settings.geoUpdateInterval, in: 1...168)
                }
                Button {
                    Task { await updateGeo() }
                } label: {
                    HStack {
                        Label("立即更新规则数据", systemImage: "arrow.down.circle")
                        Spacer()
                        if geoDatabase.isUpdating { ProgressView() }
                    }
                }
                .disabled(geoDatabase.isUpdating)
                if let installedInfo {
                    HStack {
                        Text("本地数据")
                        Spacer()
                        Text("\(ByteFormat.size(installedInfo.size)) · "
                           + installedInfo.updatedAt.formatted(date: .abbreviated,
                                                               time: .shortened))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let result = geoDatabase.statusText {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(geoDatabase.statusIsError ? Color.red : Color.secondary)
                }
            }
        }
    }

    private func updateGeo() async {
        do {
            try await geoDatabase.updateManually()
        } catch {
            // 具体错误由 GeoDatabaseManager 发布到设置页。
        }
    }
}

private struct GeoURLField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: $text, axis: .vertical)
                .font(.footnote.monospaced())
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...3)
        }
        .padding(.vertical, 2)
    }
}

struct InfoLabel: View {
    let title: String
    let message: String
    @State private var showingInfo = false

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
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        }
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
