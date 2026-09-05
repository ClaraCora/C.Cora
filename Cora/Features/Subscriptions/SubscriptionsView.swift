import SwiftUI

/// 配置与订阅页：管理配置列表，并提供页面级同步、订阅 UA 和配置覆写入口。
struct SubscriptionsView: View {
    @EnvironmentObject private var store: SubscriptionStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var core: CoreStateManager
    @State private var showAddRemote = false
    @State private var showAddLocal = false
    @State private var editingSub: Subscription?

    var body: some View {
        List {
            Section {
                Button {
                    Task { await store.refreshRemoteSubscriptions() }
                } label: {
                    HStack {
                        Label("刷新订阅", systemImage: "arrow.clockwise")
                        Spacer()
                        if store.isBusy {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(store.isBusy || isRefreshingSelectedProviders || !store.hasRemoteSubscriptions)

                Button {
                    guard let selectedID = store.selectedID else { return }
                    Task { await store.refreshProxyProviders(selectedID) }
                } label: {
                    HStack {
                        Label("刷新远程 Provider", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if isRefreshingSelectedProviders {
                            ProgressView().controlSize(.small)
                        } else if !selectedProxyProviders.isEmpty {
                            Text("当前配置 · \(selectedProxyProviders.count) 个")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(store.isBusy || isRefreshingSelectedProviders || selectedProxyProviders.isEmpty)
            } header: {
                Text("快速操作")
            } footer: {
                if let selected = store.selected {
                    Text("刷新订阅会重新下载远程配置；Provider 刷新只作用于当前配置“\(selected.name)”并保留本地缓存。")
                } else {
                    Text("请先添加并选择一个配置。")
                }
            }
            .listRowBackground(AppListRowBackground())

            Section("配置") {
                if store.subscriptions.isEmpty {
                    CoraUnavailableState("还没有配置",
                                         systemImage: "tray",
                                         description: "点右上角 + 添加订阅链接，或新建一个本地配置")
                        .listRowBackground(Color.clear)
                }

                ForEach(store.subscriptions) { sub in
                    NavigationLink {
                        SubscriptionDetailView(subID: sub.id)
                    } label: {
                        SubscriptionRow(sub: sub, isSelected: sub.id == store.selectedID)
                    }
                    .listRowBackground(AppListRowBackground())
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.remove(sub.id)
                        } label: { Label("删除", systemImage: "trash") }
                        if !sub.isLocal {
                            Button {
                                Task { await store.refresh(sub.id) }
                            } label: { Label("刷新", systemImage: "arrow.clockwise") }
                            .tint(.blue)
                            Button {
                                editingSub = sub
                            } label: { Label("编辑", systemImage: "pencil") }
                            .tint(.orange)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if sub.id != store.selectedID {
                            Button {
                                store.select(sub.id)
                            } label: { Label("设为当前", systemImage: "checkmark.circle") }
                            .tint(.green)
                        }
                    }
                }
            }
            .listRowBackground(AppListRowBackground())

            Section("配置选项") {
                if !core.configNotices.isEmpty {
                    SettingsInfoRow(
                        title: "配置提示",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange,
                        message: core.configNotices.joined(separator: "\n\n"))
                }
                SubscriptionUserAgentSetting(userAgent: $settings.subscriptionUA)
                SettingsNavigationRow(
                    title: "配置覆写",
                    systemImage: "slider.horizontal.3",
                    message: "为当前配置选择是否应用 Cora 的 DNS、嗅探和 TUN 设置。",
                    destination: ConfigOverrideSettingsView())
            }
            .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .listStyle(.insetGrouped)
        .coraListSectionSpacing(12)
        .navigationTitle("配置与订阅")
        .task { await core.refreshStatus() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { showAddRemote = true } label: {
                        Label("添加订阅链接", systemImage: "link")
                    }
                    Button { showAddLocal = true } label: {
                        Label("新建本地配置", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay {
            if store.isBusy { ProgressView().controlSize(.large) }
        }
        .sheet(isPresented: $showAddRemote) {
            AddSubscriptionView().environmentObject(store)
        }
        .sheet(isPresented: $showAddLocal) {
            LocalConfigEditorView(editing: nil).environmentObject(store)
        }
        .sheet(item: $editingSub) { sub in
            EditSubscriptionView(sub: sub).environmentObject(store)
        }
        .alert("出错了", isPresented: .constant(store.lastError != nil)) {
            Button("好") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var selectedProxyProviders: [RemoteResource] {
        store.selectedRemoteResources.filter { $0.kind == .proxyProvider }
    }

    private var isRefreshingSelectedProviders: Bool {
        guard let selectedID = store.selectedID else { return false }
        return store.refreshingProviderIDs.contains(selectedID)
    }
}

private struct SubscriptionUserAgentSetting: View {
    @Binding var userAgent: String
    @State private var selectedPreset = "clash-meta"

    private static let customPreset = "__custom__"
    private static let presets = [
        UserAgentPreset(title: "Clash Meta", value: "clash-meta"),
        UserAgentPreset(title: "Mihomo", value: "mihomo"),
        UserAgentPreset(title: "Clash Verge", value: "Clash Verge"),
        UserAgentPreset(title: "Clash for Windows", value: "ClashForWindows"),
        UserAgentPreset(title: "Surge", value: "Surge iOS"),
        UserAgentPreset(title: "Quantumult X", value: "Quantumult X"),
        UserAgentPreset(title: "Shadowrocket", value: "Shadowrocket"),
        UserAgentPreset(title: "Stash", value: "Stash"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SettingsSymbol(systemImage: "network.badge.shield.half.filled")
                InfoLabel(
                    title: "订阅请求 UA",
                    message: "拉取订阅时发送的 User-Agent。不同服务可能根据 UA 返回不同配置格式，修改后重新拉取订阅生效。")
                Spacer(minLength: 8)
                Picker("订阅请求 UA 预设", selection: $selectedPreset) {
                    ForEach(Self.presets) { preset in
                        Text(preset.title).tag(preset.value)
                    }
                    Text("自定义").tag(Self.customPreset)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel("订阅请求 UA 预设")
            }

            if selectedPreset == Self.customPreset {
                TextField("自定义 UA", text: $userAgent)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("自定义订阅请求 UA")
                    .padding(.leading, 42)
            }
        }
        .padding(.vertical, 2)
        .onAppear { synchronizePresetSelection() }
        .onChange(of: userAgent) { _ in
            guard selectedPreset != Self.customPreset else { return }
            synchronizePresetSelection()
        }
        .onChange(of: selectedPreset) { preset in
            guard preset != Self.customPreset else { return }
            userAgent = preset
        }
    }

    private func synchronizePresetSelection() {
        selectedPreset = Self.presets.contains(where: { $0.value == userAgent })
            ? userAgent
            : Self.customPreset
    }
}

private struct UserAgentPreset: Identifiable {
    let title: String
    let value: String

    var id: String { value }
}

struct SubscriptionRow: View {
    let sub: Subscription
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // 类型图标：渐变圆角方块，与节点页策略组图标的占位样式一致。
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(
                        colors: [iconTint.opacity(0.18), iconTint.opacity(0.07)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: sub.isLocal ? "doc.text" : "link")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(iconTint)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text(sub.name).font(.headline)
                    if sub.isLocal {
                        Text("本地")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.12)))
                            .overlay(Capsule().stroke(Color.orange.opacity(0.25), lineWidth: 0.5))
                    }
                    if sub.overrideEnabled {
                        Text("覆写")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.10)))
                    }
                    Spacer()
                    if sub.nodeCount > 0 {
                        Text("\(sub.nodeCount) 节点")
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.10)))
                    }
                }

                // 流量进度（仅远程订阅有）
                if sub.hasUsage {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(sub.used), total: Double(max(sub.total, 1)))
                            .tint(usageTint)
                        HStack {
                            Text("已用 \(ByteFormat.size(sub.used)) / \(ByteFormat.size(sub.total))")
                            Spacer()
                            Text("剩 \(ByteFormat.size(sub.remaining))")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 14) {
                    if let text = sub.expireText {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                            Text("到期 \(text)")
                        }
                        .foregroundStyle((sub.expire ?? .distantFuture) < Date() ? .red : .primary)
                    }
                    if let text = sub.updatedText {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("更新 \(text)")
                        }
                        .foregroundStyle(.primary)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle")
                            Text("未拉取")
                        }
                        .foregroundStyle(.orange)
                    }
                }
                .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private var iconTint: Color {
        sub.isLocal ? .orange : Color.accentColor
    }

    private var usageTint: Color {
        let ratio = sub.total > 0 ? Double(sub.used) / Double(sub.total) : 0
        return ratio > 0.9 ? .red : (ratio > 0.7 ? .orange : .green)
    }
}

/// 添加订阅链接弹窗。
private struct AddSubscriptionView: View {
    @EnvironmentObject private var store: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("如：我的机场", text: $name)
                }
                .listRowBackground(AppListRowBackground())
                Section("订阅链接") {
                    TextField("https://...", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if let message = SettingsStore.httpURLValidationMessage(url, allowEmpty: false) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .listRowBackground(AppListRowBackground())
                Text("订阅内容需为 Clash/mihomo YAML。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(AppListRowBackground())
            }
            .scrollContentBackground(.hidden)
            .background(AppAmbientBackground())
            .navigationTitle("添加订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("添加") {
                        let n = name, u = url
                        dismiss()
                        Task { await store.add(name: n, url: u) }
                    }
                    .disabled(!SettingsStore.isValidHTTPURL(url, allowEmpty: false))
                }
            }
        }
    }
}
