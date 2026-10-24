import SwiftUI

struct ProxyChainSettingsView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var core: CoreStateManager
    var subscriptionID: UUID?

    @State private var loadedID: UUID?
    @State private var draft = ProxyChainConfiguration()
    @State private var nodes: [ProxyChainCatalog.Node] = []
    @State private var catalogWarnings: [String] = []
    @State private var validationWarnings: [String] = []
    @State private var catalogError: String?
    @State private var validationError: String?
    @State private var search = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var didSave = false

    private var currentID: UUID? { subscriptionID ?? subscriptions.selectedID }
    private var subscription: Subscription? { subscriptions.subscriptions.first { $0.id == currentID } }
    private var hasChanges: Bool { subscription.map { draft != $0.proxyChain } ?? false }
    private var catalogKey: String {
        "\(currentID?.uuidString ?? "none")-\(subscription?.updatedAt?.timeIntervalSince1970 ?? 0)-\(subscriptions.providerCacheRevision)"
    }
    private var selected: Set<ProxyChainReference> { Set(draft.targets) }
    private var sources: [String] { Array(Set(filteredNodes.map(\.source))).sorted() }
    private var filteredNodes: [ProxyChainCatalog.Node] {
        nodes.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search) }
    }
    private var missingTargets: [ProxyChainReference] {
        let available = Set(nodes.map(\.reference))
        return draft.targets.filter { !available.contains($0) }
    }
    private var upstreamName: String { draft.upstream?.name ?? "选择前置节点" }

    var body: some View {
        Group {
            if let subscription {
                Form {
                    configurationSection(subscription)
                    if draft.enabled {
                        upstreamSection
                        targetsSection
                        missingSection
                    }
                    feedbackSection
                }
                .searchable(text: $search, prompt: "搜索后置节点或来源")
                .scrollContentBackground(.hidden)
                .background(AppAmbientBackground())
                .listStyle(.insetGrouped)
                .coraListSectionSpacing(12)
                .listRowSeparatorTint(Color.primary.opacity(0.08))
            } else {
                CoraUnavailableState("请先选择配置", systemImage: "doc.questionmark")
            }
        }
        .navigationTitle("节点前置代理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().controlSize(.small) }
                        Text("保存").fontWeight(.semibold)
                    }
                    .frame(minHeight: 44)
                }
                .disabled(!hasChanges || isLoading || isSaving || core.isBusy)
            }
        }
        .task(id: catalogKey) { await loadCatalog() }
        .task(id: draft) {
            guard loadedID != nil else { return }
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            await validate()
        }
        .onChange(of: draft) { _ in didSave = false }
        .environment(\.coraSettingsAppearance, true)
        .environment(\.settingsCategory, .speed)
        .environment(\.defaultMinListRowHeight, 44)
        .tint(Color(uiColor: .systemBlue))
    }

    private func configurationSection(_ subscription: Subscription) -> some View {
        Section {
            LabeledContent("配置", value: subscription.name)
            Toggle("启用节点前置代理", isOn: $draft.enabled)
            if didSave {
                Label(subscription.id == subscriptions.selectedID && !subscriptions.pendingProxyChainApply
                      ? "已应用" : "已保存，待下次连接生效", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if subscription.id == subscriptions.selectedID,
               subscriptions.pendingProxyChainApply, !hasChanges, core.isActive {
                Button {
                    Task {
                        if !(await core.applyPendingSettings()) {
                            validationError = core.lastError ?? "应用失败，请重试"
                        }
                    }
                } label: {
                    HStack {
                        Label("应用并重连", systemImage: "arrow.clockwise")
                        Spacer()
                        if core.isBusy { ProgressView() }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(core.isBusy || isSaving)
            }
        } footer: {
            Text("设置仅属于这份配置。应用时会短暂断开 VPN；未勾选节点的代理链保持原样。")
        }
        .settingsSectionStyle()
    }

    private var upstreamSection: some View {
        Section {
            Picker("前置来源", selection: $draft.mode) {
                Text("已有节点").tag("existing")
                Text("单独添加 YAML").tag("custom")
            }
            .pickerStyle(.menu)
            if draft.mode == "existing" {
                NavigationLink {
                    ProxyChainUpstreamPicker(nodes: nodes, excluded: selected, selection: $draft.upstream)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(upstreamName).foregroundStyle(.primary)
                        if let reference = draft.upstream {
                            Text(reference.sourceLabel).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 44)
                }
                if let reference = draft.upstream, !nodes.contains(where: { $0.reference == reference }) {
                    Label("此前置当前不存在或尚未缓存；应用后勾选节点会拒绝连接。", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("单节点 YAML").font(.subheadline)
                    TextEditor(text: $draft.yaml)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 180)
                        .accessibilityLabel("前置节点 YAML")
                    Text("粘贴一个包含 name、type、server 等字段的节点映射；无需添加 proxies 列表。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("前置节点")
        } footer: {
            Text("实际链路：设备 → 前置 → 勾选的后置 → 网站。出口仍为后置节点；前置失败时不会自动绕过。UDP 是否可用取决于双方协议能力。")
        }
        .settingsSectionStyle()
    }

    @ViewBuilder private var targetsSection: some View {
        let selectedRefs = selected
        Section {
            LabeledContent("已勾选", value: "\(draft.targets.count) 个节点")
            if !draft.targets.isEmpty {
                Button("取消全部勾选") { draft.targets = [] }
                    .frame(minHeight: 44)
            }
            if isLoading {
                HStack(spacing: 10) { ProgressView(); Text("读取节点…") }
            } else if nodes.isEmpty {
                Text("暂无可选择节点，请先刷新配置及远程节点来源。")
                    .foregroundStyle(.secondary)
            } else if filteredNodes.isEmpty {
                Text("没有匹配的后置节点").foregroundStyle(.secondary)
            }
        } header: { Text("生效的后置节点") }
        .settingsSectionStyle()

        ForEach(sources, id: \.self) { source in
            Section(source.isEmpty ? "配置内节点" : source) {
                ForEach(filteredNodes.filter { $0.source == source }) { node in
                    let isUpstream = draft.mode == "existing" && draft.upstream == node.reference
                    Toggle(isOn: Binding(
                        get: { selectedRefs.contains(node.reference) },
                        set: { value in
                            draft.targets.removeAll { $0 == node.reference }
                            if value { draft.targets.append(node.reference) }
                            draft.targets.sort { ($0.source, $0.name) < ($1.source, $1.name) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.name).fixedSize(horizontal: false, vertical: true)
                            Text(node.issue ?? (isUpstream ? "当前前置节点，不能同时作为后置" : node.type.uppercased()))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isUpstream || node.issue != nil || draft.targets.count >= 4096 && !selectedRefs.contains(node.reference))
                    .frame(minHeight: 44)
                }
            }
            .settingsSectionStyle()
        }
    }

    @ViewBuilder private var missingSection: some View {
        if !missingTargets.isEmpty {
            Section {
                ForEach(missingTargets) { reference in
                    Button {
                        draft.targets.removeAll { $0 == reference }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reference.name).foregroundStyle(.primary)
                            Text("\(reference.sourceLabel) · 当前不存在或尚未缓存 · 点击移除")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                    }
                }
            } header: { Text("失效或未缓存的勾选项") } footer: {
                Text("节点改名后不会自动匹配到其他节点。")
            }
            .settingsSectionStyle()
        }
    }

    @ViewBuilder private var feedbackSection: some View {
        if let error = validationError ?? catalogError {
            Section("需要处理") {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsSectionStyle()
        }
        let warnings = Array(Set(catalogWarnings + validationWarnings)).sorted()
        if !warnings.isEmpty {
            Section("状态说明") {
                ForEach(warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            }
            .settingsSectionStyle()
        }
    }

    @MainActor private func loadCatalog() async {
        guard let subscription else { return }
        if loadedID != subscription.id {
            draft = subscription.proxyChain
            loadedID = subscription.id
            search = ""
            validationError = nil
            didSave = false
        }
        isLoading = true
        let payloads = subscriptions.providerPayloadsJSON(for: subscription.id)
        let yaml = subscription.yaml
        let data = await Task.detached(priority: .userInitiated) {
            MihomoCore.proxyChainCatalog(configYAML: yaml, providerPayloadsJSON: payloads)
        }.value
        guard !Task.isCancelled else { return }
        var result = try? JSONDecoder().decode(ProxyChainCatalog.self, from: data)
        if core.isActive, subscription.id == subscriptions.selectedID,
           case .ok(let runtimeData) = await core.sendMessage(["cmd": "proxyChainCatalog"]),
           let runtime = try? JSONDecoder().decode(ProxyChainCatalog.self, from: runtimeData),
           runtime.subscriptionID == subscription.id.uuidString, runtime.error == nil {
            result = runtime
        }
        guard !Task.isCancelled else { return }
        nodes = result?.nodes ?? []
        catalogWarnings = result?.warnings ?? []
        catalogError = result?.error ?? (result == nil ? "读取节点失败，请重新进入此页" : nil)
        isLoading = false
        await validate()
    }

    @MainActor private func validate() async {
        guard let subscription else { return }
        let configuration = draft
        let yaml = subscription.yaml
        let payloads = subscriptions.providerPayloadsJSON(for: subscription.id)
        let data = await Task.detached(priority: .userInitiated) {
            MihomoCore.validateProxyChain(configYAML: yaml, providerPayloadsJSON: payloads, chainJSON: configuration.json)
        }.value
        guard !Task.isCancelled, configuration == draft else { return }
        let result = try? JSONDecoder().decode(ProxyChainValidation.self, from: data)
        validationError = result?.error ?? (result == nil ? "前置设置校验失败" : nil)
        validationWarnings = result?.warnings ?? []
    }

    @MainActor private func save() async {
        guard let subscription, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let configuration = draft
        let revision = subscriptions.providerCacheRevision
        await validate()
        guard configuration == draft, validationError == nil else { return }
        guard let current = subscriptions.subscriptions.first(where: { $0.id == subscription.id }),
              current.yaml == subscription.yaml, revision == subscriptions.providerCacheRevision else {
            validationError = "节点来源已更新，请检查名单后重新保存"
            return
        }
        subscriptions.setProxyChain(subscription.id, configuration: configuration)
        await subscriptions.flushPersistence()
        if let error = subscriptions.lastError, error.hasPrefix("保存订阅失败") {
            validationError = error
            return
        }
        didSave = true
    }
}

private struct ProxyChainUpstreamPicker: View {
    let nodes: [ProxyChainCatalog.Node]
    let excluded: Set<ProxyChainReference>
    @Binding var selection: ProxyChainReference?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [ProxyChainCatalog.Node] {
        nodes.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            ForEach(Array(Set(filtered.map(\.source))).sorted(), id: \.self) { source in
                Section(source.isEmpty ? "配置内节点" : source) {
                    ForEach(filtered.filter { $0.source == source }) { node in
                        Button {
                            selection = node.reference
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(node.name).foregroundStyle(.primary)
                                    Text(node.issue ?? (excluded.contains(node.reference) ? "请先取消此节点的后置勾选" : node.type.uppercased()))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if selection == node.reference {
                                    Image(systemName: "checkmark").accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .disabled(excluded.contains(node.reference) || node.issue != nil)
                        .accessibilityValue(selection == node.reference ? "已选择" : "未选择")
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "搜索前置节点或来源")
        .navigationTitle("选择前置节点")
        .navigationBarTitleDisplayMode(.inline)
    }
}
