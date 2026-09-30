import SwiftUI

struct PO0WhitelistSettingsEntry: View {
    @ObservedObject private var store = PO0WhitelistStore.shared
    @EnvironmentObject private var core: CoreStateManager
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            NavigationLink {
                PO0WhitelistSettingsView()
            } label: {
                HStack(spacing: 12) {
                    SettingsSymbol(systemImage: "checkmark.shield", category: .privacy)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PO0 白名单")
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(store.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    SettingsActivityIndicator(isRunning: core.isActive && store.snapshot?.isWorking == true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsPressStyle())
            InfoButton(
                message: "在 VPN 运行期间定时检测并登记当前直连出口。可设置 Token 和检测频率，查看白名单及当前出口。退出 App 后自动检测仍会继续；“刷新查看”只查询白名单。",
                accessibilityLabel: "查看 PO0 白名单说明")
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in iconSize + 12 }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft = PO0WhitelistStorage.load()
    @State private var showToken = false
    @State private var didSave = false
    @FocusState private var tokenFocused: Bool
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 30

    private var hasChanges: Bool { draft != store.configuration }
    private var currentSnapshot: PO0WhitelistSnapshot? {
        guard let snapshot = store.snapshot, snapshot.configurationID == store.configuration.id else { return nil }
        return snapshot
    }
    private var isRefreshing: Bool {
        core.isActive && (store.isRequestingRefresh || currentSnapshot?.refreshing == true)
    }
    private var isWorking: Bool {
        core.isActive && (store.isRequestingRefresh || currentSnapshot?.isWorking == true)
    }
    private var canRefresh: Bool {
        core.isActive && !store.configuration.tokens.isEmpty && !store.isSaving && !hasChanges && !isWorking
    }
    private var canCheck: Bool {
        core.isActive && store.configuration.enabled && !store.isSaving && !hasChanges && !isWorking
    }

    var body: some View {
        Form {
            whitelistSection
            if let snapshot = currentSnapshot {
                ForEach(snapshot.results) { result in
                    PO0WhitelistTokenSection(result: result)
                }
            }
            statusSection
            automaticSection
            tokenSection
            if let message = store.validationMessage ?? store.message {
                Section("需要处理") {
                    notice(message, systemImage: "exclamationmark.triangle.fill", color: .red)
                    if store.validationMessage == nil {
                        Button {
                            Task { await store.refresh(force: true) }
                        } label: {
                            Label("重试同步", systemImage: "arrow.triangle.2.circlepath")
                                .frame(minHeight: 44)
                        }
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
                Button {
                    tokenFocused = false
                    Task {
                        if await store.save(draft) {
                            draft = store.configuration
                            didSave = true
                            showToken = false
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if store.isSaving { ProgressView().controlSize(.small) }
                        Text("保存").fontWeight(.semibold)
                    }
                    .frame(minHeight: 44)
                }
                .disabled(!hasChanges || store.isSaving)
            }
        }
        .settingsChangeAnimation(value: store.isSaving)
        .settingsChangeAnimation(value: didSave)
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
        .environment(\.settingsCategory, .privacy)
        .environment(\.defaultMinListRowHeight, 44)
        .tint(Color(uiColor: .systemBlue))
    }

    private var whitelistSection: some View {
        Section {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        whitelistHeading
                        refreshButton
                    }
                } else {
                    HStack(spacing: 12) {
                        whitelistHeading
                        Spacer(minLength: 8)
                        refreshButton
                    }
                }
            }
            .padding(.vertical, 4)
            if let error = store.readOnlyMessage {
                notice(error, systemImage: "exclamationmark.triangle.fill", color: .red)
            }
            if currentSnapshot?.results.isEmpty != false {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "tray")
                        .foregroundStyle(.secondary)
                        .frame(width: iconSize)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.configuration.tokens.isEmpty ? "尚未配置 Token" : "等待白名单结果")
                            .font(.subheadline.weight(.medium))
                        Text(store.configuration.tokens.isEmpty ? "在下方填写并保存 Token，即可查看白名单。" : "连接 VPN 后，点击“刷新查看”获取白名单。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
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
    }

    private var whitelistHeading: some View {
        HStack(spacing: 12) {
            SettingsSymbol(systemImage: "list.bullet.rectangle", category: .privacy)
            VStack(alignment: .leading, spacing: 4) {
                Text("白名单").font(.headline)
                if let time = currentSnapshot?.lastRefreshedAt, time > 0 {
                    Text("最近刷新 \(Date(timeIntervalSince1970: time).formatted(.dateTime.month().day().hour().minute().second()))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("查看 Token 白名单与直连出口")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await store.refreshReadOnly() }
        } label: {
            HStack(spacing: 6) {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text("刷新查看")
            }
            .font(.subheadline.weight(.medium))
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
        }
        .buttonStyle(.borderless)
        .disabled(!canRefresh)
        .accessibilityHint("只查询已保存 Token 的白名单")
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                SettingsSymbol(systemImage: "waveform.path.ecg", category: .privacy)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.summary).font(.body.weight(.medium))
                    Text(core.isActive ? "VPN 已连接" : "VPN 未连接")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if isWorking {
                    SettingsActivityIndicator(isRunning: true)
                } else {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            if let snapshot = currentSnapshot {
                if snapshot.lastCheckedAt > 0 {
                    dateRow("最近检测", systemImage: "clock.arrow.circlepath", timestamp: snapshot.lastCheckedAt)
                }
                if core.isActive, snapshot.enabled, snapshot.nextCheckAt > 0 {
                    dateRow("下次检测", systemImage: "clock", timestamp: snapshot.nextCheckAt)
                }
            }
            Button {
                Task { await store.checkNow() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.shield")
                        .frame(width: iconSize)
                        .accessibilityHidden(true)
                    Text("立即检测并加白").font(.body.weight(.medium))
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.right")
                        .font(.footnote.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(SettingsPressStyle())
            .disabled(!canCheck)
        } header: {
            Text("检测状态")
        } footer: {
            if hasChanges {
                Text("有尚未保存的修改，请点击右上角“保存”。")
            } else if !core.isActive {
                Text("VPN 未连接。下次从 App 连接 VPN 后应用设置；已有结果仅代表上次检测。")
            } else if didSave, store.message == nil {
                Label("设置已保存并应用。", systemImage: "checkmark.circle")
            } else {
                Text("检测调用 PO0 加白接口，同一出口重复请求不会重复占用白名单名额。")
            }
        }
        .settingsSectionStyle()
    }

    private var statusSymbol: String {
        if !store.configuration.enabled { return "pause.circle" }
        if !core.isActive { return "link.badge.plus" }
        if store.message != nil { return "exclamationmark.circle.fill" }
        guard let snapshot = currentSnapshot, !snapshot.results.isEmpty else { return "clock" }
        return snapshot.successfulCount == snapshot.results.count ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var statusColor: Color {
        if !store.configuration.enabled { return .secondary }
        if !core.isActive { return .orange }
        if store.message != nil { return .red }
        guard let snapshot = currentSnapshot, !snapshot.results.isEmpty else { return .secondary }
        return snapshot.successfulCount == snapshot.results.count ? .green : .orange
    }

    private var automaticSection: some View {
        Section {
            InfoToggleRow(
                title: "自动检测并加白",
                message: "保存后，在 VPN 运行期间自动登记本机直连出口。退出 App 后继续执行，网络切换后会补检，断开 VPN 后停止。",
                systemImage: "checkmark.shield",
                isOn: $draft.enabled)
            Picker(selection: $draft.intervalMinutes) {
                ForEach(PO0WhitelistConfiguration.intervals, id: \.self) { minutes in
                    Text(minutes == 60 ? "每小时" : "每 \(minutes) 分钟").tag(minutes)
                }
            } label: {
                HStack(spacing: 12) {
                    SettingsSymbol(systemImage: "clock", category: .speed)
                    Text("检测频率")
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
        } header: {
            Text("自动检测")
        } footer: {
            Text("保存后生效，仅在 VPN 运行期间持续检测。")
        }
        .settingsSectionStyle()
        .disabled(store.isSaving)
    }

    private var tokenSection: some View {
        Section {
            HStack(spacing: 12) {
                SettingsSymbol(systemImage: "key.fill", category: .configuration)
                VStack(alignment: .leading, spacing: 6) {
                    Text("访问 Token")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Group {
                        if showToken {
                            TextField("pgnfw_…", text: $draft.tokens)
                        } else {
                            SecureField("pgnfw_…", text: $draft.tokens)
                        }
                    }
                    .font(.subheadline.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .privacySensitive()
                    .accessibilityLabel("PO0 Token")
                    .focused($tokenFocused)
                }
                Button { showToken.toggle() } label: {
                    Image(systemName: showToken ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showToken ? "隐藏 Token" : "显示 Token")
            }
            .padding(.vertical, 4)
        } header: {
            Text("Token")
        } footer: {
            Text("Token 仅保存在本机。多个 Token 用逗号分隔，最多 8 个。可填写 pgnfw_xxx@0 指定固定槽位；使用固定槽位会替换该槽位原有 IP。")
        }
        .settingsSectionStyle()
        .disabled(store.isSaving)
    }

    private func notice(_ text: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }

    private func dateRow(_ title: String, systemImage: String, timestamp: Double) -> some View {
        LabeledContent {
            Text(Date(timeIntervalSince1970: timestamp), format: .dateTime.month().day().hour().minute().second())
                .font(.subheadline)
                .monospacedDigit()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PO0WhitelistTokenSection: View {
    let result: PO0WhitelistResult
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 30

    private var statusColor: Color {
        if result.error != nil { return .red }
        if !result.enabled { return .secondary }
        return result.applied ? .green : .orange
    }

    private var statusSymbol: String {
        if result.error != nil { return "exclamationmark.shield.fill" }
        if !result.enabled { return "shield.slash" }
        return result.applied ? "checkmark.shield.fill" : "exclamationmark.shield"
    }

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                SettingsSymbol(systemImage: "key.fill", category: .configuration)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Token \(result.index)").font(.headline)
                    Text(result.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let slot = result.slot {
                        Label("固定槽位 \(slot)", systemImage: "pin")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: statusSymbol)
                    .font(.title3)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            if let error = result.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !result.currentIp.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "location")
                        .foregroundStyle(Color(uiColor: .systemTeal))
                        .frame(width: iconSize)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前直连出口")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(result.currentIp)
                            .font(.body.monospacedDigit())
                            .textSelection(.enabled)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
            if result.error == nil || !result.whitelist.isEmpty {
                LabeledContent {
                    Text("\(result.whitelist.count)\(result.truncated ? "+" : "") / \(result.limit)")
                        .fontWeight(.medium)
                        .monospacedDigit()
                } label: {
                    Label("白名单占用", systemImage: "list.number")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                ForEach(result.whitelist.indices, id: \.self) { index in
                    PO0WhitelistEntryRow(entry: result.whitelist[index], isCurrentExit: result.isCurrentExit(result.whitelist[index]))
                }
                if result.whitelist.isEmpty {
                    Text("白名单中暂无记录")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if result.truncated {
                Text("仅显示前 64 条，完整白名单可在 PO0 网站查看。")
            }
        }
        .settingsSectionStyle()
    }
}

private struct PO0WhitelistEntryRow: View {
    let entry: PO0WhitelistResult.Entry
    let isCurrentExit: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 30

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isCurrentExit ? "location.fill" : "globe")
                .foregroundStyle(isCurrentExit ? Color(uiColor: .systemTeal) : Color.secondary)
                .frame(width: iconSize)
                .accessibilityHidden(true)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    address
                    metadata
                }
            } else {
                address
                Spacer(minLength: 8)
                metadata
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var address: some View {
        Text(entry.ip)
            .font(.subheadline.monospacedDigit())
            .fontWeight(isCurrentExit ? .semibold : .regular)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var metadata: some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
            if isCurrentExit {
                Label {
                    Text("当前出口").foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "location.fill").foregroundStyle(Color(uiColor: .systemTeal))
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(uiColor: .systemTeal).opacity(0.12), in: Capsule())
            }
            if let slot = entry.slot {
                Text("槽位 \(slot)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
