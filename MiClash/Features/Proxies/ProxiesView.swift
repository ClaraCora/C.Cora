import SwiftUI

/// 节点页：卡片式可折叠列表（每组一张圆角卡片，左右留白、组间留白、无分割线）。
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
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(controller.groups) { group in
                    GroupCard(
                        group: group,
                        isExpanded: expanded.contains(group.name),
                        isTesting: controller.testing.contains(group.name),
                        delays: controller.delays,
                        onToggle: { toggle(group.name) },
                        onTest: { Task { await controller.testGroup(group.name) } },
                        onSelect: { node in
                            guard group.selectable, node != group.now else { return }
                            Task { await controller.select(group: group.name, name: node) }
                        })
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollIndicators(.hidden)
    }

    private func toggle(_ name: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
        }
    }
}

/// 单个策略组卡片：组头 +（展开时）节点列表，整体一张圆角矩形。
private struct GroupCard: View {
    let group: ProxyGroup
    let isExpanded: Bool
    let isTesting: Bool
    let delays: [String: Int]
    let onToggle: () -> Void
    let onTest: () -> Void
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)

            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(group.all, id: \.self) { node in
                        ProxyNodeRow(
                            node: node,
                            isCurrent: node == group.now,
                            selectable: group.selectable,
                            delay: delays[node])
                        .padding(.horizontal, 14)
                        .frame(minHeight: 34)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(node) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(group.name).font(.headline)
                    TypeBadge(type: group.type)
                }
                Text(group.now)
                    .font(.subheadline)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
                .font(.body)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary.opacity(0.35))
            Text(node)
                .font(.body)
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
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(color(d))
        } else if delay == 0 {
            Text("超时").font(.subheadline).foregroundStyle(.red)
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
