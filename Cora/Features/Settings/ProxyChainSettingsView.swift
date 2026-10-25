import SwiftUI

struct ProxyChainSettingsView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var core: CoreStateManager
    @Environment(\.dismiss) private var dismiss
    var subscriptionID: UUID?

    @State private var loadedID: UUID?
    @State private var draft = ProxyChainConfiguration()
    @State private var nodes: [ProxyChainCatalog.Node] = []
    @State private var catalogWarnings: [String] = []
    @State private var catalogError: String?
    @State private var validation = ProxyChainValidation()
    @State private var editingGroup: ProxyChainGroup?
    @State private var showDiscard = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var didSave = false

    private var currentID: UUID? { subscriptionID ?? subscriptions.selectedID }
    private var subscription: Subscription? { subscriptions.subscriptions.first { $0.id == currentID } }
    private var hasChanges: Bool { subscription.map { draft != $0.proxyChain } ?? false }
    private var catalogKey: String {
        "\(currentID?.uuidString ?? "none")-\(subscription?.updatedAt?.timeIntervalSince1970 ?? 0)-\(subscriptions.providerCacheRevision)"
    }

    var body: some View {
        Group {
            if let subscription {
                Form {
                    configurationSection(subscription)
                    Section {
                        ForEach(draft.groups) { group in groupRow(group) }
                        Button {
                            var number = 1
                            while draft.groups.contains(where: { $0.name == "分组 \(number)" }) { number += 1 }
                            editingGroup = .init(name: "分组 \(number)")
                        } label: {
                            Label("添加分组", systemImage: "plus")
                                .frame(minHeight: 44)
                        }
                        .disabled(draft.groups.count >= ProxyChainConfiguration.maxGroups || isSaving || isLoading)
                        if draft.groups.isEmpty {
                            Text("添加一组前置，选择需要经过它的后置节点。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: { Text("前置分组") } footer: {
                        Text("每个后置只能属于一个启用组；多个组可共用前置，各组之间不串联。最多 32 组，共 4096 个后置节点。")
                    }
                    .settingsSectionStyle()
                    feedbackSection
                }
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
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    if hasChanges { showDiscard = true } else { dismiss() }
                } label: { Label("返回", systemImage: "chevron.left") }
                .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await save() } } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().controlSize(.small) }
                        Text("保存").fontWeight(.semibold)
                    }.frame(minHeight: 44)
                }
                .disabled(!hasChanges || isLoading || isSaving || core.isBusy)
            }
        }
        .confirmationDialog("分组设置尚未保存", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("放弃修改并返回", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) { }
        }
        .sheet(item: $editingGroup) { group in
            ProxyChainGroupEditor(
                initial: group, nodes: nodes,
                targetOwners: draft.targetOwners(excluding: group.id),
                upstreamOwners: draft.upstreamOwners(excluding: group.id),
                otherTargetCount: draft.groups.filter { $0.id != group.id }.reduce(0) { $0 + $1.targets.count },
                isExisting: draft.groups.contains { $0.id == group.id },
                onComplete: { changed in
                    if let index = draft.groups.firstIndex(where: { $0.id == changed.id }) { draft.groups[index] = changed }
                    else { draft.groups.append(changed) }
                },
                onDelete: { draft.groups.removeAll { $0.id == group.id } })
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
                .disabled(isSaving)
            if isLoading { HStack(spacing: 10) { ProgressView(); Text("读取节点…") } }
            if didSave {
                Label(subscription.id == subscriptions.selectedID && !subscriptions.pendingProxyChainApply
                      ? "已应用" : "已保存，待下次连接生效", systemImage: "checkmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if subscription.id == subscriptions.selectedID,
               subscriptions.pendingProxyChainApply, !hasChanges, core.isActive {
                Button {
                    Task {
                        if !(await core.applyPendingSettings()) {
                            validation.error = core.lastError ?? "应用失败，请重试"
                        }
                    }
                } label: {
                    HStack {
                        Label("应用并重连", systemImage: "arrow.clockwise")
                        Spacer()
                        if core.isBusy { ProgressView() }
                    }.frame(minHeight: 44)
                }.disabled(core.isBusy || isSaving)
            }
        } footer: {
            Text("设置仅属于这份配置。保存后统一应用全部组，重连时会短暂断开 VPN。未勾选节点保持原链路。")
        }
        .settingsSectionStyle()
    }

    private func groupRow(_ group: ProxyChainGroup) -> some View {
        HStack(spacing: 12) {
            Button { editingGroup = group } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.displayName).foregroundStyle(.primary)
                    Text("\(group.upstreamLabel) → \(group.targets.count) 个后置")
                        .font(.caption).foregroundStyle(.secondary)
                    if validation.groupID == group.id || validation.conflictingGroupID == group.id {
                        Label("存在冲突，请编辑此组", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red)
                    } else if let status = status(for: group) {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("编辑前置节点及生效的后置节点")
            Spacer(minLength: 4)
            Toggle("启用\(group.displayName)", isOn: Binding(
                get: { draft.groups.first { $0.id == group.id }?.enabled ?? false },
                set: { enabled in
                    if let index = draft.groups.firstIndex(where: { $0.id == group.id }) { draft.groups[index].enabled = enabled }
                }
            )).labelsHidden()
        }
        .frame(minHeight: 44)
        .disabled(isSaving || isLoading)
    }

    private func status(for group: ProxyChainGroup) -> String? {
        if !group.enabled { return "此组已关闭" }
        if group.targets.isEmpty { return "未选择后置" }
        if !draft.enabled { return "总开关已关闭" }
        let available = Set(nodes.map(\.reference))
        if group.mode == "existing", let ref = group.upstream, !available.contains(ref) { return "前置不存在或尚未缓存" }
        if group.mode == "existing" && group.upstream == nil { return "未选择前置" }
        let missing = group.targets.filter { !available.contains($0) }.count
        return missing > 0 ? "\(missing) 个后置不存在或尚未缓存" : nil
    }

    @ViewBuilder private var feedbackSection: some View {
        if let error = validation.error ?? catalogError {
            Section("需要处理") {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }.settingsSectionStyle()
        }
        let warnings = Array(Set(catalogWarnings + (validation.warnings ?? []))).sorted()
        if !warnings.isEmpty {
            Section("状态说明") {
                ForEach(warnings, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            }.settingsSectionStyle()
        }
    }

    @MainActor private func loadCatalog() async {
        guard let subscription else { return }
        if loadedID != subscription.id {
            draft = subscription.proxyChain
            loadedID = subscription.id
            validation = .init()
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
        guard !Task.isCancelled, loadedID == subscription.id, configuration == draft else { return }
        validation = (try? JSONDecoder().decode(ProxyChainValidation.self, from: data))
            ?? .init(error: "前置设置校验失败")
    }

    @MainActor private func save() async {
        guard let subscription, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let configuration = draft
        let revision = subscriptions.providerCacheRevision
        await validate()
        guard !Task.isCancelled, configuration == draft, validation.error == nil else { return }
        guard let current = subscriptions.subscriptions.first(where: { $0.id == subscription.id }),
              current.yaml == subscription.yaml, revision == subscriptions.providerCacheRevision else {
            validation.error = "节点来源已更新，请检查名单后重新保存"
            return
        }
        subscriptions.setProxyChain(subscription.id, configuration: configuration)
        await subscriptions.flushPersistence()
        if let error = subscriptions.lastError, error.hasPrefix("保存订阅失败") {
            validation.error = error
            return
        }
        didSave = true
    }
}

private struct ProxyChainGroupEditor: View {
    let initial: ProxyChainGroup
    let nodes: [ProxyChainCatalog.Node]
    let targetOwners: [ProxyChainReference: String]
    let upstreamOwners: [ProxyChainReference: String]
    let otherTargetCount: Int
    let isExisting: Bool
    let onComplete: (ProxyChainGroup) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProxyChainGroup
    @State private var search = ""
    @State private var showDiscard = false
    @State private var showDelete = false

    init(initial: ProxyChainGroup, nodes: [ProxyChainCatalog.Node],
         targetOwners: [ProxyChainReference: String], upstreamOwners: [ProxyChainReference: String],
         otherTargetCount: Int, isExisting: Bool,
         onComplete: @escaping (ProxyChainGroup) -> Void, onDelete: @escaping () -> Void) {
        self.initial = initial
        self.nodes = nodes
        self.targetOwners = targetOwners
        self.upstreamOwners = upstreamOwners
        self.otherTargetCount = otherTargetCount
        self.isExisting = isExisting
        self.onComplete = onComplete
        self.onDelete = onDelete
        _draft = State(initialValue: initial)
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
    private var sizeError: String? {
        if draft.yaml.utf8.count > ProxyChainConfiguration.maxYAMLBytes { return "单节点 YAML 不能超过 64 KB" }
        if otherTargetCount + draft.targets.count > ProxyChainConfiguration.maxTargets { return "全部分组最多可勾选 4096 个后置节点" }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("分组名称", text: $draft.name)
                    Toggle("启用此组", isOn: $draft.enabled)
                } footer: { Text("完成后返回列表，点击列表右上角“保存”统一保存分组设置。") }
                .settingsSectionStyle()
                upstreamSection
                targetsSection
                missingSection
                if let sizeError { Section { Text(sizeError).foregroundStyle(.red) }.settingsSectionStyle() }
                if isExisting {
                    Section {
                        Button("删除此组", role: .destructive) { showDelete = true }.frame(minHeight: 44)
                    }.settingsSectionStyle()
                }
            }
            .searchable(text: $search, prompt: "搜索后置节点或来源")
            .scrollContentBackground(.hidden)
            .background(AppAmbientBackground())
            .listStyle(.insetGrouped)
            .coraListSectionSpacing(12)
            .listRowSeparatorTint(Color.primary.opacity(0.08))
            .navigationTitle("编辑前置分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if draft != initial { showDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onComplete(draft); dismiss() }.disabled(sizeError != nil)
                }
            }
            .confirmationDialog("此组修改尚未完成", isPresented: $showDiscard, titleVisibility: .visible) {
                Button("放弃此组修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) { }
            }
            .confirmationDialog("删除这个前置分组？", isPresented: $showDelete, titleVisibility: .visible) {
                Button("删除分组", role: .destructive) { onDelete(); dismiss() }
                Button("取消", role: .cancel) { }
            } message: { Text("保存并重新连接后，该组后置节点将恢复原链路。") }
        }
        .interactiveDismissDisabled(draft != initial)
        .environment(\.coraSettingsAppearance, true)
        .environment(\.settingsCategory, .speed)
        .environment(\.defaultMinListRowHeight, 44)
        .tint(Color(uiColor: .systemBlue))
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
                    ProxyChainUpstreamPicker(nodes: nodes, excluded: selected.union(targetOwners.keys), selection: $draft.upstream)
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
            if nodes.isEmpty {
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
                    let occupied = targetOwners[node.reference].map { "已用于分组 \($0)" }
                        ?? upstreamOwners[node.reference].map { "已作为分组 \($0) 的前置" }
                    let issue = node.issue ?? occupied ?? (isUpstream ? "当前前置节点，不能同时作为后置" : nil)
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
                            Text(issue ?? node.type.uppercased())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!selectedRefs.contains(node.reference) && (issue != nil || otherTargetCount + draft.targets.count >= ProxyChainConfiguration.maxTargets))
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
