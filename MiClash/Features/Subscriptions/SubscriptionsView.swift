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
            .floatingTabBarInset()
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .green : .secondary)
                Text(sub.name).font(.headline)
                Spacer()
                if sub.nodeCount > 0 {
                    Text("\(sub.nodeCount) 节点")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // 流量进度
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

            HStack(spacing: 12) {
                if let exp = sub.expire {
                    Label(exp.formatted(date: .numeric, time: .omitted), systemImage: "calendar")
                        .foregroundStyle(exp < Date() ? .red : .secondary)
                }
                if let t = sub.updatedAt {
                    Label(t.formatted(date: .omitted, time: .shortened), systemImage: "arrow.clockwise")
                } else {
                    Text("未拉取").foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var usageTint: Color {
        let ratio = sub.total > 0 ? Double(sub.used) / Double(sub.total) : 0
        return ratio > 0.9 ? .red : (ratio > 0.7 ? .orange : .green)
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
