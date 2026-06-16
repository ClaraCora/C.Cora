import SwiftUI

/// 节点页：扁平可折叠列表（默认收起），支持延迟测速，手动切换（仅 Selector 组）。
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
                GroupHeaderRow(
                    group: group,
                    isExpanded: expanded.contains(group.name),
                    isTesting: controller.testing.contains(group.name),
                    onToggle: { toggle(group.name) },
                    onTest: { Task { await controller.testGroup(group.name) } })

                if expanded.contains(group.name) {
                    ForEach(group.all, id: \.self) { node in
                        ProxyNodeRow(
                            node: node,
                            isCurrent: node == group.now,
                            selectable: group.selectable,
                            delay: controller.delays[node])
                        .listRowInsets(EdgeInsets(top: 4, leading: 34, bottom: 4, trailing: 16))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard group.selectable, node != group.now else { return }
                            Task { await controller.select(group: group.name, name: node) }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func toggle(_ name: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
        }
    }
}

private struct GroupHeaderRow: View {
    let group: ProxyGroup
    let isExpanded: Bool
    let isTesting: Bool
    let onToggle: () -> Void
    let onTest: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.name).font(.subheadline.weight(.semibold))
                    TypeBadge(type: group.type)
                }
                Text(group.now)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onTest) {
                if isTesting {
                    ProgressView()
                } else {
                    Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                }
            }
            .buttonStyle(.borderless)
            .disabled(isTesting)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
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
                .font(.footnote)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary.opacity(0.35))
            Text(node)
                .font(.callout)
                .foregroundStyle(selectable ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            DelayBadge(delay: delay)
        }
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
