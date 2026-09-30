import SwiftUI

struct PO0WhitelistSettingsEntry: View {
    @ObservedObject private var store = PO0WhitelistStore.shared
    @EnvironmentObject private var core: CoreStateManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationLink {
            PO0WhitelistSettingsView()
        } label: {
            HStack(spacing: 12) {
                SettingsSymbol(systemImage: "checkmark.shield", category: .privacy)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PO0 白名单")
                    Text(store.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                SettingsActivityIndicator(isRunning: core.isActive && store.snapshot?.isWorking == true)
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(SettingsPressStyle())
        .alignmentGuide(.listRowSeparatorLeading) { _ in 42 }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.refresh()
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            }
        }
    }
}

struct PO0WhitelistSettingsView: View {
    @ObservedObject private var store = PO0WhitelistStore.shared
    @EnvironmentObject private var core: CoreStateManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = PO0WhitelistStorage.load()
    @State private var showToken = false
    @State private var didSave = false

    private var hasChanges: Bool { draft != store.configuration }

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await store.refreshReadOnly() }
                } label: {
                    HStack {
                        Label("刷新查看", systemImage: "arrow.clockwise")
                        Spacer()
                        SettingsActivityIndicator(isRunning: core.isActive && (store.isRequestingRefresh || store.snapshot?.refreshing == true))
                    }
                }
                .disabled(!core.isActive || store.configuration.tokens.isEmpty || store.isSaving ||
                          hasChanges || store.isRequestingRefresh || store.snapshot?.refreshing == true)
                if let snapshot = store.snapshot, snapshot.configurationID == store.configuration.id,
                   let time = snapshot.lastRefreshedAt, time > 0 {
                    dateRow("最近刷新", timestamp: time)
                }
                if let error = store.readOnlyMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.snapshot?.results.isEmpty != false {
                    Text(store.configuration.tokens.isEmpty ? "填写并保存 Token 后，可在这里查看白名单。" : "暂无白名单结果，点击“刷新查看”获取。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("白名单")
            } footer: {
                if hasChanges {
                    Text("请先保存修改，再刷新对应 Token 的白名单。")
                } else if !core.isActive {
                    Text("连接 VPN 后可刷新查看。已有结果仅代表上次查询。")
                } else {
                    Text("刷新只查询，不添加白名单或写入槽位。已开启的自动加白仍按原计划运行。")
                }
            }
            .settingsSectionStyle()

            if let snapshot = store.snapshot, snapshot.configurationID == store.configuration.id {
                ForEach(snapshot.results) { result in
                    resultSection(result)
                }
            }

            Section {
                Toggle(isOn: $draft.enabled) {
                    Label("自动检测并加白", systemImage: "checkmark.shield")
                }
                Picker("检测频率", selection: $draft.intervalMinutes) {
                    ForEach(PO0WhitelistConfiguration.intervals, id: \.self) { minutes in
                        Text(minutes == 60 ? "每小时" : "每 \(minutes) 分钟").tag(minutes)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("自动检测")
            } footer: {
                Text("保存后，在 VPN 运行期间自动登记本机直连出口，退出 App 后继续执行。网络切换后会补检，断开 VPN 后停止。")
            }
            .settingsSectionStyle()
            .disabled(store.isSaving)

            Section {
                HStack(spacing: 8) {
                    Group {
                        if showToken {
                            TextField("pgnfw_…", text: $draft.tokens)
                        } else {
                            SecureField("pgnfw_…", text: $draft.tokens)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .privacySensitive()
                    .accessibilityLabel("PO0 Token")

                    Button { showToken.toggle() } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showToken ? "隐藏 Token" : "显示 Token")
                }
            } header: {
                Text("Token")
            } footer: {
                Text("Token 仅保存在本机。多个 Token 用逗号分隔，最多 8 个。可填写 pgnfw_xxx@0 指定固定槽位；使用固定槽位会替换该槽位原有 IP。")
            }
            .settingsSectionStyle()
            .disabled(store.isSaving)

            Section {
                HStack {
                    Text("当前状态")
                    Spacer()
                    Text(store.summary).foregroundStyle(.secondary)
                }
                if let snapshot = store.snapshot, snapshot.configurationID == store.configuration.id {
                    if snapshot.lastCheckedAt > 0 {
                        dateRow("最近检测", timestamp: snapshot.lastCheckedAt)
                    }
                    if core.isActive, snapshot.enabled, snapshot.nextCheckAt > 0 {
                        dateRow("下次检测", timestamp: snapshot.nextCheckAt)
                    }
                }
                Button {
                    Task { await store.checkNow() }
                } label: {
                    HStack {
                        Label("立即检测并加白", systemImage: "plus.shield")
                        Spacer()
                        SettingsActivityIndicator(isRunning: core.isActive && store.snapshot?.isWorking == true)
                    }
                }
                .disabled(!core.isActive || !store.configuration.enabled || store.isSaving ||
                          hasChanges || store.snapshot?.isWorking == true)
            } header: {
                Text("检测状态")
            } footer: {
                if hasChanges {
                    Text("有尚未保存的修改，请点击右上角“保存”。")
                } else if !core.isActive {
                    Text("VPN 未连接。下次从 App 连接 VPN 后应用设置；已有结果仅代表上次检测。")
                } else if didSave, store.message == nil {
                    Text("设置已保存并应用。")
                } else {
                    Text("检测调用 PO0 加白接口，同一出口重复请求不会重复占用白名单名额。")
                }
            }
            .settingsSectionStyle()

            if let message = store.validationMessage ?? store.message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if store.validationMessage == nil {
                        Button("重试同步") { Task { await store.refresh(force: true) } }
                            .disabled(!core.isActive || store.isSaving || hasChanges)
                    }
                }
                .settingsSectionStyle()
            }

        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .listStyle(.insetGrouped)
        .coraListSectionSpacing(12)
        .listRowSeparatorTint(Color.primary.opacity(0.08))
        .navigationTitle("PO0 白名单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    Task {
                        if await store.save(draft) {
                            draft = store.configuration
                            didSave = true
                            showToken = false
                        }
                    }
                }
                .disabled(!hasChanges || store.isSaving)
            }
        }
        .settingsChangeAnimation(value: store.isSaving)
        .onChange(of: draft) { value in
            store.clearValidationMessage()
            if value != store.configuration { didSave = false }
        }
        .onChange(of: scenePhase) { phase in if phase != .active { showToken = false } }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.refresh()
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            }
        }
        .environment(\.coraSettingsAppearance, true)
        .environment(\.defaultMinListRowHeight, 44)
        .tint(Color(uiColor: .systemBlue))
    }

    private func dateRow(_ title: String, timestamp: Double) -> some View {
        LabeledContent(title) {
            Text(Date(timeIntervalSince1970: timestamp), format: .dateTime.month().day().hour().minute().second())
                .font(.subheadline)
                .monospacedDigit()
        }
    }

    private func resultSection(_ result: PO0WhitelistResult) -> some View {
        Section {
            Label(result.title, systemImage: result.applied ? "checkmark.shield.fill" : "exclamationmark.shield")
                .foregroundStyle(result.applied ? Color.green : (result.error == nil ? Color.orange : Color.red))
            if let error = result.error {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !result.currentIp.isEmpty {
                LabeledContent("当前直连出口", value: result.currentIp)
                    .textSelection(.enabled)
                LabeledContent("白名单占用", value: "\(result.whitelist.count)\(result.truncated ? "+" : "") / \(result.limit)")
            }
            ForEach(Array(result.whitelist.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .top) {
                    Text(entry.ip).textSelection(.enabled)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        if result.isCurrentExit(entry) {
                            Label("当前出口", systemImage: "location.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                        if let slot = entry.slot {
                            Label("槽位 \(slot)", systemImage: "pin")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
            if result.truncated {
                Text("仅显示前 64 条，完整白名单可在 PO0 网站查看。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Token \(result.index)\(result.slot.map { " · 固定槽位 \($0)" } ?? "")")
        }
        .settingsSectionStyle()
    }
}
