import SwiftUI
import UIKit

/// 节点页：紧凑展示策略组，展开后可搜索、切换并比较节点延迟。
struct ProxiesView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @StateObject private var controller = ProxyController()
    @State private var expanded: Set<String> = []
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            navigationContent
                .navigationTitle("节点")
                .toolbar {
                    if canRefresh {
                        ToolbarItem(placement: .topBarTrailing) {
                            refreshControl
                        }
                    }
                }
                .task(id: LoadContext(status: core.status.rawValue,
                                      subscriptionID: subscriptions.selectedID,
                                      configurationUpdatedAt: subscriptions.selected?.updatedAt,
                                      providerRevision: subscriptions.providerCacheRevision)) {
                    await reload()
                }
        }
    }

    @ViewBuilder private var navigationContent: some View {
        if showsSearch {
            content
                .searchable(text: $searchText,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "搜索策略组或节点")
        } else {
            content
        }
    }

    private var canRefresh: Bool {
        controller.mode != "direct" || !controller.isRuntimeAvailable
    }

    private var showsSearch: Bool {
        canRefresh && !controller.groups.isEmpty
    }

    @ViewBuilder private var content: some View {
        if let err = controller.error, controller.groups.isEmpty {
            ContentUnavailableView {
                Label("拿不到节点", systemImage: "exclamationmark.triangle")
            } description: {
                Text(err)
            } actions: {
                Button("重试") { Task { await reload() } }
            }
        } else if controller.mode == "direct" && controller.isRuntimeAvailable {
            ContentUnavailableView("直连模式",
                systemImage: "arrow.up.forward",
                description: Text("当前为直连模式，不经过代理节点"))
        } else if controller.groups.isEmpty && (!controller.hasLoaded || controller.isLoading) {
            ProgressView("加载策略组…")
        } else if controller.groups.isEmpty {
            ContentUnavailableView("没有策略组",
                systemImage: "square.stack.3d.up",
                description: Text("当前配置没有可显示的代理策略组"))
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
                .help("刷新节点")
            }
        }
        .frame(width: 44, height: 44)
    }

    private var groupList: some View {
        let results = displayedGroups

        return List {
            if !controller.isRuntimeAvailable {
                Section {
                    Label("VPN 未连接，当前显示已保存配置；节点切换和测速暂不可用。",
                          systemImage: "eye")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = controller.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .listRowBackground(Color.orange.opacity(0.08))
                }
            }

            if results.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ProxyOverviewRow(
                        mode: controller.mode,
                        visibleGroupCount: results.count,
                        totalGroupCount: controller.groups.count,
                        nodeCount: controller.uniqueNodeCount,
                        isSearching: !normalizedSearch.isEmpty)
                        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                        .listRowSeparator(.hidden)
                }

                ForEach(results) { result in
                    Section {
                        GroupHeaderRow(
                            group: result.group,
                            isExpanded: result.isExpanded,
                            isTesting: controller.testing.contains(result.group.name),
                            currentDelay: controller.delays[result.group.now],
                            canTest: controller.isRuntimeAvailable,
                            isRuntimeAvailable: controller.isRuntimeAvailable,
                            canToggle: normalizedSearch.isEmpty,
                            onToggle: { openGroup(result.group.name) },
                            onTest: {
                                Task { await controller.testGroup(result.group.name) }
                            })
                        .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 8))
                        .listRowSeparator(.hidden)

                        if result.isExpanded && result.group.all.isEmpty {
                            Text("该策略组没有节点")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                                .listRowInsets(EdgeInsets(top: 4, leading: 46, bottom: 4, trailing: 14))
                                .listRowSeparator(.hidden)
                        } else {
                            ForEach(result.nodes) { item in
                                let selectingNode = controller.selecting[result.group.name]
                                ProxyNodeListRow(
                                    node: item.name,
                                    isCurrent: item.name == result.group.now,
                                    isSelecting: selectingNode == item.name,
                                    isSelectionBlocked: selectingNode != nil,
                                    selectable: controller.isRuntimeAvailable && result.group.selectable,
                                    isReadOnly: !controller.isRuntimeAvailable,
                                    delay: controller.delays[item.name],
                                    detail: controller.details[item.name],
                                    onSelect: {
                                        Task {
                                            await controller.select(
                                                group: result.group.name,
                                                name: item.name)
                                        }
                                    })
                                .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 14))
                                .listRowSeparator(.hidden)
                                .background {
                                    // 选中高亮：向外扩 8pt 贴近卡片边缘，呈现为整行选中态，
                                    // 而不是浮在文字后面的小色块。仅选中行绘制。
                                    if item.name == result.group.now {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.accentColor.opacity(0.08))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .stroke(Color.accentColor.opacity(0.25),
                                                            lineWidth: 1))
                                            .padding(.horizontal, -8)
                                            .padding(.vertical, -2)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(6)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable { await reload() }
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var displayedGroups: [DisplayedProxyGroup] {
        let query = normalizedSearch
        guard !query.isEmpty else {
            return controller.groups.map { group in
                let isExpanded = expanded.contains(group.name)
                return DisplayedProxyGroup(
                    group: group,
                    nodes: isExpanded ? group.nodes : [],
                    isExpanded: isExpanded)
            }
        }

        return controller.groups.compactMap { group in
            let matchedNodes = group.nodes.filter { item in
                item.normalizedSearchText.contains(query)
            }
            guard groupMetadata(group).contains(query) || !matchedNodes.isEmpty else { return nil }
            return DisplayedProxyGroup(
                group: group,
                nodes: matchedNodes,
                isExpanded: !matchedNodes.isEmpty)
        }
    }

    private func groupMetadata(_ group: ProxyGroup) -> String {
        "\(group.name) \(group.now) \(group.type) \(group.displayType)".lowercased()
    }

    private func toggle(_ name: String) {
        guard normalizedSearch.isEmpty else { return }
        if expanded.contains(name) {
            expanded.remove(name)
        } else {
            expanded.insert(name)
        }
    }

    private func openGroup(_ name: String) {
        if normalizedSearch.isEmpty {
            toggle(name)
        } else {
            searchText = ""
            expanded.insert(name)
        }
    }

    private func reload() async {
        await controller.load()
    }
}

private struct LoadContext: Hashable {
    let status: Int
    let subscriptionID: UUID?
    let configurationUpdatedAt: Date?
    let providerRevision: Int
}

private struct DisplayedProxyGroup: Identifiable {
    let group: ProxyGroup
    let nodes: [ProxyGroupNode]
    let isExpanded: Bool

    var id: String { group.id }
}

private struct ProxyOverviewRow: View {
    let mode: String
    let visibleGroupCount: Int
    let totalGroupCount: Int
    let nodeCount: Int
    let isSearching: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: mode == "global" ? "globe" : "list.bullet.indent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 28, height: 28)

            Text(modeTitle)
                .font(.subheadline.weight(.semibold))

            Spacer(minLength: 8)

            Text(countText)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var modeTitle: String {
        mode == "global" ? "全局模式" : "规则模式"
    }

    private var countText: String {
        let groups = isSearching
            ? "\(visibleGroupCount)/\(totalGroupCount) 组"
            : "\(totalGroupCount) 组"
        return "\(groups) · \(nodeCount) 节点"
    }
}

private struct GroupHeaderRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let group: ProxyGroup
    let isExpanded: Bool
    let isTesting: Bool
    let currentDelay: Int?
    let canTest: Bool
    let isRuntimeAvailable: Bool
    let canToggle: Bool
    let onToggle: () -> Void
    let onTest: () -> Void

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .trailing, spacing: 6) {
                toggleButton
                testButton
            }
        } else {
            HStack(spacing: 4) {
                toggleButton
                testButton
            }
        }
    }

    private var toggleButton: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                GroupIcon(url: group.icon)
                groupLabels

                Image(systemName: canToggle
                      ? "chevron.right"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .rotationEffect(.degrees(canToggle && isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.16), value: isExpanded)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(group.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(
            canToggle
                ? (isExpanded ? "双击收起" : "双击展开")
                : "双击查看完整策略组")
    }

    private var groupLabels: some View {
        VStack(alignment: .leading, spacing: 4) {
            if dynamicTypeSize.isAccessibilitySize {
                Text(group.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                metadata
            } else {
                HStack(spacing: 5) {
                    Text(group.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    metadata
                }
            }

            HStack(spacing: 5) {
                Image(systemName: isRuntimeAvailable && group.selectable ? "hand.tap" : "gearshape")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                Text(group.now.isEmpty ? "未选择" : group.now)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadata: some View {
        Text("\(group.displayType) · \(group.all.count)")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.08)))
            .lineLimit(1)
    }

    private var testButton: some View {
        Button(action: onTest) {
            testLabel
        }
        .buttonStyle(SpeedTestButtonStyle())
        .disabled(isTesting || !canTest)
        .accessibilityLabel("测试\(group.name)延迟")
        .accessibilityValue(
            isTesting ? "正在测速" : DelayBadge.accessibilityText(currentDelay))
        .accessibilityHint(canTest ? "测试该策略组全部节点" : "连接 VPN 后可测速")
    }

    private var testLabel: some View {
        HStack(spacing: 5) {
            if isTesting {
                ProgressView()
                    .controlSize(.mini)
                    .tint(testTint)
            } else {
                Image(systemName: "speedometer")
                    .font(.system(size: 11, weight: .semibold))
            }

            Text(testStatusText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(testTint)
        .frame(width: testButtonWidth, height: 28)
        .background(Capsule().fill(testTint.opacity(0.12)))
        .overlay(Capsule().stroke(testTint.opacity(0.22), lineWidth: 0.5))
        .frame(width: testButtonWidth, height: 44)
        .contentShape(Rectangle())
    }

    private var testButtonWidth: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 124 }
        if dynamicTypeSize == .xxLarge || dynamicTypeSize == .xxxLarge { return 96 }
        return 84
    }

    private var testStatusText: String {
        if isTesting { return "测速中" }
        return currentDelay == nil ? "测速" : DelayBadge.shortText(currentDelay)
    }

    private var testTint: Color {
        if isTesting || currentDelay == nil { return Color.accentColor }
        return DelayBadge.tint(currentDelay)
    }

    private var accessibilityValue: String {
        let current = group.now.isEmpty ? "未选择节点" : "当前节点 \(group.now)"
        let state = canToggle ? (isExpanded ? "已展开" : "已折叠") : "搜索结果"
        return "\(group.displayType)，\(group.all.count) 个节点，\(current)，\(DelayBadge.accessibilityText(currentDelay))，\(state)"
    }
}

private struct SpeedTestButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 策略组图标：配置图标带内存和磁盘缓存；缺失或失败时使用稳定占位。
private struct GroupIcon: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                // 加载成功的图标直接显示，不垫任何底色——透明 PNG 的镂空区域保持透明。
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.07)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))

                if url == nil || failed {
                    Image(systemName: "network")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
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

private struct ProxyNodeListRow: View {
    let node: String
    let isCurrent: Bool
    let isSelecting: Bool
    let isSelectionBlocked: Bool
    let selectable: Bool
    let isReadOnly: Bool
    let delay: Int?
    let detail: String?
    let onSelect: () -> Void

    @ViewBuilder var body: some View {
        if selectable && !isCurrent {
            Button(action: onSelect) {
                row
            }
            .buttonStyle(.plain)
            .disabled(isSelectionBlocked)
            .accessibilityHint("双击切换到此节点")
        } else if isCurrent {
            row
                .accessibilityAddTraits(.isSelected)
        } else {
            row
        }
    }

    private var row: some View {
        ProxyNodeRow(
            node: node,
            isCurrent: isCurrent,
            isSelecting: isSelecting,
            delay: delay,
            detail: detail)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(node)
            .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        [
            isCurrent ? "当前节点" : nil,
            detail?.isEmpty == false ? detail : nil,
            DelayBadge.accessibilityText(delay),
            isReadOnly ? "离线只读" : (selectable ? nil : "由策略组自动选择"),
        ]
        .compactMap { $0 }
        .joined(separator: "，")
    }
}

private struct ProxyNodeRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let node: String
    let isCurrent: Bool
    let isSelecting: Bool
    let delay: Int?
    let detail: String?

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            HStack(alignment: .top, spacing: 10) {
                marker
                VStack(alignment: .leading, spacing: 5) {
                    labels
                    DelayBadge(delay: delay)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        } else {
            HStack(spacing: 10) {
                marker
                labels
                Spacer(minLength: 8)
                DelayBadge(delay: delay)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder private var marker: some View {
        if isSelecting {
            ProgressView()
                .controlSize(.small)
                .frame(width: 20, height: 22)
        } else if isCurrent {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, height: 22)
        } else {
            Circle()
                .fill(Color.secondary.opacity(0.24))
                .frame(width: 5, height: 5)
                .frame(width: 20, height: 22)
        }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node)
                .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
        }
    }
}

private struct DelayBadge: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let delay: Int?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)

            Text(Self.shortText(delay))
        }
        .foregroundStyle(color)
        .font(.caption.monospacedDigit().weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.10)))
        .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? nil : 66,
               alignment: .trailing)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(Self.accessibilityText(delay))
    }

    private var color: Color {
        Self.tint(delay)
    }

    static func shortText(_ delay: Int?) -> String {
        guard let delay else { return "未测" }
        return delay > 0 ? "\(delay) ms" : "超时"
    }

    static func tint(_ delay: Int?) -> Color {
        guard let delay else { return .secondary.opacity(0.45) }
        guard delay > 0 else { return .red }
        return color(delay)
    }

    static func accessibilityText(_ delay: Int?) -> String {
        guard let delay else { return "未测速" }
        return delay > 0 ? "延迟 \(delay) 毫秒" : "延迟测试超时"
    }

    private static func color(_ milliseconds: Int) -> Color {
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
