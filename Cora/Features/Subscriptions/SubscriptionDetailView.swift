import SwiftUI
import UIKit

/// 订阅/配置详情：查看元信息与配置原文（YAML），并可设为当前或编辑配置。
struct SubscriptionDetailView: View {
    @EnvironmentObject private var store: SubscriptionStore
    let subID: UUID

    @State private var showEditor = false
    @State private var showRemoteEditor = false

    private var sub: Subscription? {
        store.subscriptions.first(where: { $0.id == subID })
    }

    var body: some View {
        Group {
            if let sub {
                List {
                    summarySection(sub).listRowBackground(AppListRowBackground())
                    primaryActionSection(sub).listRowBackground(AppListRowBackground())
                    configurationSection(sub).listRowBackground(AppListRowBackground())
                    detailsSection(sub).listRowBackground(AppListRowBackground())
                    yamlSection(sub).listRowBackground(AppListRowBackground())
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(AppAmbientBackground())
            } else {
                CoraUnavailableState("配置不存在", systemImage: "doc.questionmark")
            }
        }
        .navigationTitle(sub?.name ?? "详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEditor) {
            if let sub { LocalConfigEditorView(editing: sub).environmentObject(store) }
        }
        .sheet(isPresented: $showRemoteEditor) {
            if let sub { EditSubscriptionView(sub: sub).environmentObject(store) }
        }
    }

    @ViewBuilder private func summarySection(_ sub: Subscription) -> some View {
        Section {
            SubscriptionSummary(sub: sub, isSelected: sub.id == store.selectedID)
        }
    }

    @ViewBuilder private func primaryActionSection(_ sub: Subscription) -> some View {
        Section("主要操作") {
            if sub.id == store.selectedID {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("当前正在使用")
                    Spacer()
                    Text("已启用")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                }
            } else {
                Button {
                    store.select(sub.id)
                } label: {
                    Label("设为当前配置", systemImage: "checkmark.circle")
                }
            }
        }
    }

    @ViewBuilder private func configurationSection(_ sub: Subscription) -> some View {
        Section("配置行为") {
            Button {
                if sub.isLocal {
                    showEditor = true
                } else {
                    showRemoteEditor = true
                }
            } label: {
                Label(sub.isLocal ? "编辑配置" : "编辑名称 / 链接",
                      systemImage: "pencil")
            }

            Toggle(isOn: Binding(
                get: { sub.overrideEnabled },
                set: { store.setOverrideEnabled(sub.id, enabled: $0) }
            )) {
                Label("启用配置覆写", systemImage: "slider.horizontal.3")
            }
        }
    }

    @ViewBuilder private func detailsSection(_ sub: Subscription) -> some View {
        Section("详细信息") {
            LabeledContent("类型", value: sub.isLocal ? "本地配置" : "远程订阅")
            LabeledContent("节点数", value: "\(sub.nodeCount)")
            LabeledContent("配置覆写", value: sub.overrideEnabled ? "已启用" : "未启用")
            if !sub.isLocal {
                VStack(alignment: .leading, spacing: 5) {
                    Text("订阅链接")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(sub.url)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            if sub.hasUsage {
                LabeledContent("流量",
                    value: "\(ByteFormat.size(sub.used)) / \(ByteFormat.size(sub.total))")
            }
            if let text = sub.expireText {
                LabeledContent("到期", value: text)
            }
            if let text = sub.updatedText {
                LabeledContent("更新于", value: text)
            }
        }
    }

    @ViewBuilder private func yamlSection(_ sub: Subscription) -> some View {
        Section("配置内容") {
            if sub.yaml.isEmpty {
                Label(sub.isLocal ? "配置为空，可在上方编辑后保存" : "尚未拉取配置，可在上方同步",
                      systemImage: sub.isLocal ? "doc.badge.plus" : "arrow.clockwise")
                    .foregroundStyle(.secondary)
            } else {
                // 整份 YAML 放进 List 的单个 Text 会让滑动很卡（SwiftUI 要测量整段超长文本）。
                // 改为跳转到 UITextView 承载的只读页，原生虚拟化滚动，丝滑。
                NavigationLink {
                    ConfigTextReader(title: sub.name, text: sub.yaml)
                } label: {
                    Label("查看配置内容（\(sub.yaml.count) 字符）",
                          systemImage: "doc.plaintext")
                }
            }
        }
    }
}

/// 顶部配置摘要：只显示当前使用状态和最需要快速确认的信息。
private struct SubscriptionSummary: View {
    let sub: Subscription
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(
                            colors: [iconTint.opacity(0.20), iconTint.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing))
                    Image(systemName: sub.isLocal ? "doc.text.fill" : "link")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(iconTint)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 5) {
                    Text(sub.name)
                        .font(.headline)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? .green : .secondary)
                        Text(isSelected ? "当前使用" : "备用配置")
                        Text(sub.isLocal ? "本地" : "远程")
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(iconTint.opacity(0.12)))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Divider()

            HStack(spacing: 0) {
                SubscriptionSummaryMetric(
                    title: "节点",
                    value: "\(sub.nodeCount)",
                    systemImage: "circle.hexagongrid",
                    tint: .accentColor
                )

                Divider()
                    .frame(height: 30)
                    .padding(.horizontal, 12)

                SubscriptionSummaryMetric(
                    title: sub.hasUsage ? "已用流量" : "上次更新",
                    value: sub.hasUsage ? ByteFormat.size(sub.used) : (sub.updatedText ?? "未更新"),
                    systemImage: sub.hasUsage ? "chart.bar.fill" : "clock",
                    tint: sub.hasUsage ? usageTint : .secondary
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var iconTint: Color {
        sub.isLocal ? .orange : .accentColor
    }

    private var usageTint: Color {
        let ratio = sub.total > 0 ? Double(sub.used) / Double(sub.total) : 0
        return ratio > 0.9 ? .red : (ratio > 0.7 ? .orange : .green)
    }
}

private struct SubscriptionSummaryMetric: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 只读配置阅读器：用 UITextView 承载超长 YAML，避免 SwiftUI Text 的卡顿。
private struct ConfigTextReader: View {
    let title: String
    let text: String

    var body: some View {
        MonospacedTextView(text: text)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// UITextView 包装：只读、可选中、等宽。大文本滚动平滑（自带虚拟化）。
private struct MonospacedTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.alwaysBounceVertical = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        tv.backgroundColor = .systemBackground
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text { tv.text = text }
    }
}

/// 编辑远程订阅：名称 + 订阅链接。链接变更后自动重新拉取。
struct EditSubscriptionView: View {
    @EnvironmentObject private var store: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    let sub: Subscription
    @State private var name: String
    @State private var url: String

    init(sub: Subscription) {
        self.sub = sub
        _name = State(initialValue: sub.name)
        _url = State(initialValue: sub.url)
    }

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
                if urlChanged {
                    Label("保存后将按新链接重新拉取，原有节点与流量信息会被替换。",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .listRowBackground(AppListRowBackground())
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppAmbientBackground())
            .navigationTitle("编辑订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        let n = name, u = url
                        dismiss()
                        Task { await store.updateRemote(sub.id, name: n, url: u) }
                    }
                    .disabled(!isDirty || !SettingsStore.isValidHTTPURL(url, allowEmpty: false))
                }
            }
        }
    }

    private var urlChanged: Bool {
        url.trimmingCharacters(in: .whitespacesAndNewlines) != sub.url
    }

    private var isDirty: Bool {
        urlChanged || name.trimmingCharacters(in: .whitespacesAndNewlines) != sub.name
    }
}
