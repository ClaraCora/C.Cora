import SwiftUI

/// 节点页：按配置顺序展示策略组，按模式决定显示哪些组，可手动切换（仅 Selector 组）。
struct ProxiesView: View {
    @EnvironmentObject private var core: CoreStateManager
    @StateObject private var controller = ProxyController()

    var body: some View {
        NavigationStack {
            Group {
                if !core.isActive {
                    ContentUnavailableView("未连接",
                        systemImage: "bolt.horizontal.circle",
                        description: Text("先在「连接」页连上 VPN，再查看策略组"))
                } else if controller.mode == "direct" {
                    ContentUnavailableView("直连模式",
                        systemImage: "arrow.up.forward",
                        description: Text("当前为直连模式，不经过代理节点"))
                } else if let err = controller.error, controller.groups.isEmpty {
                    ContentUnavailableView("拿不到节点",
                        systemImage: "exclamationmark.triangle",
                        description: Text(err))
                } else if controller.groups.isEmpty {
                    ProgressView("加载策略组…")
                } else {
                    groupList
                }
            }
            .navigationTitle("节点")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await controller.load() }
                    } label: {
                        if controller.isLoading { ProgressView() }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(controller.isLoading)
                }
            }
            .task(id: core.isActive) {
                if core.isActive { await controller.load() }
            }
        }
    }

    private var groupList: some View {
        List {
            ForEach(controller.groups) { group in
                Section {
                    ForEach(group.all, id: \.self) { node in
                        ProxyNodeRow(
                            node: node,
                            isCurrent: node == group.now,
                            selectable: group.selectable)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard group.selectable, node != group.now else { return }
                            Task { await controller.select(group: group.name, name: node) }
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(group.name).font(.subheadline.weight(.semibold))
                        TypeBadge(type: group.type)
                        Spacer()
                        Text(group.now)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct ProxyNodeRow: View {
    let node: String
    let isCurrent: Bool
    let selectable: Bool

    var body: some View {
        HStack {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary.opacity(0.4))
            Text(node)
                .foregroundStyle(selectable ? .primary : .secondary)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

private struct TypeBadge: View {
    let type: String
    var body: some View {
        Text(type)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
    }
}
