import SwiftUI
import UIKit

/// 节点页：紧凑展示策略组，展开后可搜索、切换并比较节点延迟。
struct ProxiesView: View {
    @EnvironmentObject private var core: CoreStateManager
    @StateObject private var controller = ProxyController()
    @State private var expanded: Set<String> = []
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("节点")
                .searchable(text: $searchText,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "搜索策略组或节点")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        refreshControl
                    }
                }
                .task(id: core.isActive) {
                    guard core.isActive else { return }
                    await reload()
                }
                .onChange(of: core.isActive) { _, active in
                    guard !active else { return }
                    searchText = ""
                    expanded.removeAll()
                }
        }
    }

    @ViewBuilder private var content: some View {
        if !core.isActive {
            ContentUnavailableView("未连接",
                systemImage: "bolt.horizontal.circle",
                description: Text("先在「连接」页连上 VPN，再查看策略组"))
        } else if controller.mode == "direct" {
            ContentUnavailableView("直连模式",
                systemImage: "arrow.up.forward",
                description: Text("当前为直连模式，不经过代理节点"))
        } else if let err = controller.error, controller.groups.isEmpty {
            ContentUnavailableView {
                Label("拿不到节点", systemImage: "exclamationmark.triangle")
            } description: {
                Text(err)
            } actions: {
                Button("重试") { Task { await reload() } }
            }
        } else if controller.groups.isEmpty {
            ProgressView("加载策略组…")
        } else {
            groupList
        }
    }

    private var refreshControl: some View {
        Group {
            if controller.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新节点")
            }
        }
        .frame(width: 32, height: 32)
    }

    private var groupList: some View {
        List {
            if let error = controller.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .listRowBackground(Color.orange.opacity(0.08))
                }
            }

            if filteredGroups.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(filteredGroups) { group in
                    Section {
                        GroupHeaderRow(
                            group: group,
                            isExpanded: isExpanded(group),
                            isTesting: controller.testing.contains(group.name),
                            currentDelay: controller.delays[group.now],
                            onToggle: { toggle(group.name) },
                            onTest: { Task { await controller.testGroup(group.name) } })
                        .listRowInsets(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 12))

                        if isExpanded(group) {
                            ForEach(visibleNodes(in: group), id: \.self) { node in
                                let selectingNode = controller.selecting[group.name]
                                Button {
                                    guard group.selectable,
                                          selectingNode == nil,
                                          node != group.now else { return }
                                    Task { await controller.select(group: group.name, name: node) }
                                } label: {
                                    ProxyNodeRow(
                                        node: node,
                                        isCurrent: node == group.now,
                                        isSelecting: selectingNode == node,
                                        selectable: group.selectable,
                                        delay: controller.delays[node],
                                        detail: controller.details[node])
                                }
                                .buttonStyle(.plain)
                                .disabled(!group.selectable || selectingNode != nil)
                                .listRowInsets(EdgeInsets(top: 7, leading: 18, bottom: 7, trailing: 14))
                                .listRowSeparator(.hidden)
                                .listRowBackground(
                                    node == group.now
                                        ? Color.accentColor.opacity(0.08)
                                        : Color(uiColor: .secondarySystemGroupedBackground))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(6)
        .refreshable { await reload() }
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredGroups: [ProxyGroup] {
        let query = normalizedSearch
        guard !query.isEmpty else { return controller.groups }
        return controller.groups.filter { group in
            groupMetadata(group).contains(query) || group.all.contains { node in
                node.lowercased().contains(query)
                    || (controller.details[node]?.lowercased().contains(query) ?? false)
            }
        }
    }

    private func visibleNodes(in group: ProxyGroup) -> [String] {
        let query = normalizedSearch
        guard !query.isEmpty, !groupMetadata(group).contains(query) else { return group.all }
        return group.all.filter { node in
            node.lowercased().contains(query)
                || (controller.details[node]?.lowercased().contains(query) ?? false)
        }
    }

    private func groupMetadata(_ group: ProxyGroup) -> String {
        "\(group.name) \(group.now) \(group.type) \(group.displayType)".lowercased()
    }

    private func isExpanded(_ group: ProxyGroup) -> Bool {
        !normalizedSearch.isEmpty || expanded.contains(group.name)
    }

    private func toggle(_ name: String) {
        guard normalizedSearch.isEmpty else { return }
        if expanded.contains(name) {
            expanded.remove(name)
        } else {
            expanded.insert(name)
        }
    }

    private func reload() async {
        await controller.load()
    }
}

private struct GroupHeaderRow: View {
    let group: ProxyGroup
    let isExpanded: Bool
    let isTesting: Bool
    let currentDelay: Int?
    let onToggle: () -> Void
    let onTest: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    GroupIcon(url: group.icon)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption2)
                            Text("\(group.now.isEmpty ? "未选择" : group.now) · \(group.all.count) 个 · \(group.displayType)")
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    DelayBadge(delay: currentDelay)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.16), value: isExpanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onTest) {
                Group {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "speedometer")
                    }
                }
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.accentColor.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .disabled(isTesting)
            .accessibilityLabel("测试\(group.name)延迟")
        }
    }
}

/// 策略组图标：配置图标带内存和磁盘缓存；缺失或失败时使用稳定占位。
private struct GroupIcon: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if url == nil || failed {
                Image(systemName: "network")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .task(id: url) {
            image = nil
            failed = false
            guard let url else { return }
            await load(url)
        }
    }

    private func load(_ url: URL) async {
        if let loaded = await IconCache.shared.load(url) {
            image = loaded
        } else {
            failed = true
        }
    }
}

private struct ProxyNodeRow: View {
    let node: String
    let isCurrent: Bool
    let isSelecting: Bool
    let selectable: Bool
    let delay: Int?
    let detail: String?

    var body: some View {
        HStack(spacing: 11) {
            Group {
                if isSelecting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isCurrent
                            ? Color.accentColor
                            : Color.secondary.opacity(selectable ? 0.32 : 0.16))
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(node)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(selectable ? .primary : .secondary)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            DelayBadge(delay: delay)
        }
        .frame(minHeight: 42)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct DelayBadge: View {
    let delay: Int?

    var body: some View {
        Group {
            if let delay, delay > 0 {
                Text("\(delay) ms")
                    .foregroundStyle(color(delay))
            } else if delay == 0 {
                Text("超时")
                    .foregroundStyle(.red)
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption.monospacedDigit().weight(.medium))
        .frame(minWidth: 52, alignment: .trailing)
    }

    private func color(_ milliseconds: Int) -> Color {
        milliseconds <= 200 ? .green : (milliseconds <= 500 ? .orange : .red)
    }
}

private extension ProxyGroup {
    var displayType: String {
        switch type.lowercased() {
        case "selector": return "手动选择"
        case "urltest", "url-test": return "自动测速"
        case "fallback": return "故障转移"
        case "loadbalance", "load-balance": return "负载均衡"
        case "relay": return "链式代理"
        default: return type.isEmpty ? "策略组" : type
        }
    }
}
