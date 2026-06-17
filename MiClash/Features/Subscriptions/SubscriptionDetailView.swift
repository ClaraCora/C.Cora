import SwiftUI

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
                Text(sub.yaml)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
