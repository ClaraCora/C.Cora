import SwiftUI

/// 订阅管理页：添加/刷新/删除订阅，选择当前生效订阅。
struct SubscriptionsView: View {
    @EnvironmentObject private var store: SubscriptionStore
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                if store.subscriptions.isEmpty {
                    ContentUnavailableView("还没有订阅",
                        systemImage: "tray",
                        description: Text("点右上角 + 粘贴 Clash/mihomo 订阅链接"))
                }

                ForEach(store.subscriptions) { sub in
                    SubscriptionRow(sub: sub, isSelected: sub.id == store.selectedID)
                        .contentShape(Rectangle())
                        .onTapGesture { store.select(sub.id) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.remove(sub.id)
                            } label: { Label("删除", systemImage: "trash") }
                            Button {
                                Task { await store.refresh(sub.id) }
                            } label: { Label("刷新", systemImage: "arrow.clockwise") }
                            .tint(.blue)
                        }
                }
            }
            .navigationTitle("订阅")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .overlay {
                if store.isBusy { ProgressView().controlSize(.large) }
            }
            .sheet(isPresented: $showAdd) {
                AddSubscriptionView().environmentObject(store)
            }
            .alert("出错了", isPresented: .constant(store.lastError != nil)) {
                Button("好") { store.lastError = nil }
            } message: {
                Text(store.lastError ?? "")
            }
        }
    }
}

private struct SubscriptionRow: View {
    let sub: Subscription
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(sub.name).font(.headline)
                Text(sub.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if sub.nodeCount > 0 {
                        Text("\(sub.nodeCount) 节点").font(.caption2)
                    }
                    if let t = sub.updatedAt {
                        Text(t.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                    } else {
                        Text("未拉取").font(.caption2).foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(.tertiary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 添加订阅弹窗。
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
                Section("订阅链接") {
                    TextField("https://...", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Text("订阅内容需为 Clash/mihomo YAML。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("添加订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加") {
                        let n = name, u = url
                        dismiss()
                        Task { await store.add(name: n, url: u) }
                    }
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
