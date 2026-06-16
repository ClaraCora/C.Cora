import SwiftUI

/// 节点/策略组页：连接后查看各策略组并手动切换节点（仅 Selector 组可点）。
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
                    } label: { Image(systemName: "arrow.clockwise") }
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
                        Button {
                            guard group.selectable, node != group.now else { return }
                            Task { await controller.select(group: group.name, name: node) }
                        } label: {
                            HStack {
                                Text(node)
                                    .foregroundStyle(group.selectable ? .primary : .secondary)
                                Spacer()
                                if node == group.now {
                                    Image(systemName: "checkmark").foregroundStyle(.green)
                                }
                            }
                        }
                        .disabled(!group.selectable)
                    }
                } header: {
                    HStack {
                        Text(group.name)
                        Text(group.type).font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text(group.now).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
