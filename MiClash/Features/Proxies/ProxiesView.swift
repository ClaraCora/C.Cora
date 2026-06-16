import SwiftUI

/// 节点页：策略组可折叠（默认收起），支持延迟测速，手动切换（仅 Selector 组）。
struct ProxiesView: View {
    @EnvironmentObject private var core: CoreStateManager
    @StateObject private var controller = ProxyController()
    @State private var expanded: Set<String> = []

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
                    if expanded.contains(group.name) {
                        ForEach(group.all, id: \.self) { node in
                            ProxyNodeRow(
                                node: node,
                                isCurrent: node == group.now,
                                selectable: group.selectable,
                                delay: controller.delays[node])
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard group.selectable, node != group.now else { return }
                                Task { await controller.select(group: group.name, name: node) }
                            }
                        }
                    }
                } header: {
                    GroupHeader(
                        group: group,
                        isExpanded: expanded.contains(group.name),
                        isTesting: controller.testing.contains(group.name),
                        onToggle: { toggle(group.name) },
                        onTest: { Task { await controller.testGroup(group.name) } })
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func toggle(_ name: String) {
        if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
    }
}

private struct GroupHeader: View {
    let group: ProxyGroup
    let isExpanded: Bool
    let isTesting: Bool
    let onToggle: () -> Void
    let onTest: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // 标题区：点击折叠/展开
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(group.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            TypeBadge(type: group.type)
                        }
                        Text(group.now)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 测速
            Button(action: onTest) {
                if isTesting {
                    ProgressView()
                } else {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.yellow)
                }
            }
            .buttonStyle(.borderless)
            .disabled(isTesting)
        }
        .textCase(nil)
        .padding(.vertical, 2)
    }
}

private struct ProxyNodeRow: View {
    let node: String
    let isCurrent: Bool
    let selectable: Bool
    let delay: Int?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary.opacity(0.35))
            Text(node)
                .foregroundStyle(selectable ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            DelayBadge(delay: delay)
        }
        .padding(.vertical, 3)
    }
}

private struct DelayBadge: View {
    let delay: Int?
    var body: some View {
        if let d = delay, d > 0 {
            Text("\(d) ms")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(color(d))
        } else if delay == 0 {
            Text("超时").font(.caption2).foregroundStyle(.red)
        }
    }
    private func color(_ ms: Int) -> Color {
        ms <= 200 ? .green : (ms <= 500 ? .orange : .red)
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
