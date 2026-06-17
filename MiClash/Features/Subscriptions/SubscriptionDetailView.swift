import SwiftUI
import UIKit

/// 订阅/配置详情：查看元信息与配置原文（YAML），并可设为当前、刷新（远程）或编辑（本地）。
struct SubscriptionDetailView: View {
    @EnvironmentObject private var store: SubscriptionStore
    let subID: UUID

    @State private var showEditor = false

    private var sub: Subscription? {
        store.subscriptions.first(where: { $0.id == subID })
    }

    var body: some View {
        Group {
            if let sub {
                List {
                    infoSection(sub)
                    actionSection(sub)
                    yamlSection(sub)
                }
            } else {
                ContentUnavailableView("配置不存在", systemImage: "doc.questionmark")
            }
        }
        .navigationTitle(sub?.name ?? "详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEditor) {
            if let sub { LocalConfigEditorView(editing: sub).environmentObject(store) }
        }
    }

    @ViewBuilder private func infoSection(_ sub: Subscription) -> some View {
        Section("信息") {
            LabeledContent("类型", value: sub.isLocal ? "本地配置" : "远程订阅")
            LabeledContent("节点数", value: "\(sub.nodeCount)")
            if !sub.isLocal {
                LabeledContent("链接") {
                    Text(sub.url).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            if sub.hasUsage {
                LabeledContent("流量",
                    value: "\(ByteFormat.size(sub.used)) / \(ByteFormat.size(sub.total))")
            }
            if let exp = sub.expire {
                LabeledContent("到期",
                    value: exp.formatted(date: .numeric, time: .omitted))
            }
            if let t = sub.updatedAt {
                LabeledContent("更新于",
                    value: t.formatted(date: .numeric, time: .shortened))
            }
        }
    }

    @ViewBuilder private func actionSection(_ sub: Subscription) -> some View {
        Section {
            if sub.id == store.selectedID {
                Label("已是当前配置", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button {
                    store.select(sub.id)
                } label: {
                    Label("设为当前配置", systemImage: "checkmark.circle")
                }
            }

            if sub.isLocal {
                Button {
                    showEditor = true
                } label: {
                    Label("编辑配置", systemImage: "pencil")
                }
            } else {
                Button {
                    Task { await store.refresh(sub.id) }
                } label: {
                    Label("刷新订阅", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    @ViewBuilder private func yamlSection(_ sub: Subscription) -> some View {
        Section("配置内容") {
            if sub.yaml.isEmpty {
                Text(sub.isLocal ? "（空，点上方编辑添加内容）" : "（未拉取，下拉刷新）")
                    .foregroundStyle(.secondary)
            } else {
                // 整份 YAML 放进 List 的单个 Text 会让滑动很卡（SwiftUI 要测量整段超长文本）。
                // 改为跳转到 UITextView 承载的只读页，原生虚拟化滚动，丝滑。
                NavigationLink {
                    ConfigTextReader(title: sub.name, text: sub.yaml)
                } label: {
                    Label("查看配置内容（\(sub.yaml.count) 字符）", systemImage: "doc.plaintext")
                }
            }
        }
    }
}

/// 只读配置阅读器：用 UITextView 承载超长 YAML，避免 SwiftUI Text 的卡顿。
private struct ConfigTextReader: View {
    let title: String
    let text: String

    var body: some View {
        MonospacedTextView(text: text)
            .ignoresSafeArea(edges: .bottom)
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
