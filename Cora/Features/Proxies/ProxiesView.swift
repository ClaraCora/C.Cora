import SwiftUI
import UIKit

/// 节点页：紧凑展示策略组，展开后可搜索、切换并比较节点延迟。
struct ProxiesView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @StateObject private var controller = ProxyController()
    @State private var expanded: Set<String> = []
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var groupGradients: [String: Int] = [:]
    @AppStorage("proxyNodeLayout") private var layoutRawValue = ProxyNodeLayout.list.rawValue
    @AppStorage("proxyGroupGradients") private var gradientStorage = "{}"

    var body: some View {
        NavigationStack {
            ZStack {
                AppAmbientBackground()
                navigationContent
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsSearch || canRefresh {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if showsSearch {
                            layoutMenu

                            Button {
                                isSearchPresented = true
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .accessibilityLabel("搜索节点")
                            .help("搜索节点")
                        }
                        refreshControl
                    }
                }
            }
            .task(id: LoadContext(status: core.status.rawValue,
                                  subscriptionID: subscriptions.selectedID,
                                  configurationUpdatedAt: subscriptions.selected?.updatedAt,
                                  providerRevision: subscriptions.providerCacheRevision)) {
                loadGroupGradients()
                await reload()
            }
            .onChange(of: isSearchPresented) { _, presented in
                if !presented { searchText = "" }
            }
        }
    }

    @ViewBuilder private var navigationContent: some View {
        if showsSearch && isSearchPresented {
            content
                .searchable(text: $searchText,
                            isPresented: $isSearchPresented,
                            placement: .navigationBarDrawer(displayMode: .automatic),
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

    private var nodeLayout: ProxyNodeLayout {
        ProxyNodeLayout(rawValue: layoutRawValue) ?? .list
    }

    private var layoutMenu: some View {
        Menu {
            Picker("节点布局", selection: $layoutRawValue) {
                Label("列表", systemImage: "list.bullet").tag(ProxyNodeLayout.list.rawValue)
                Label("网格", systemImage: "square.grid.2x2").tag(ProxyNodeLayout.grid.rawValue)
            }
        } label: {
            Image(systemName: nodeLayout.systemImage)
        }
        .accessibilityLabel("切换节点布局")
        .help("切换节点布局")
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

    @ViewBuilder private var groupList: some View {
        if nodeLayout == .grid {
            gridGroupList
        } else {
            listGroupList
        }
    }

    private var listGroupList: some View {
        let results = displayedGroups

        return List {
            if !controller.isRuntimeAvailable {
                Section {
                    Label("VPN 未连接。选择会保存，并在下次连接时生效；测速需连接后使用。",
                          systemImage: "checkmark.circle")
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
                ForEach(results) { result in
                    StrategyGroupListPanel(
                        group: result.group,
                        visibleNodes: result.nodes,
                        isExpanded: result.isExpanded,
                        isTesting: controller.testing.contains(result.group.name),
                        currentDelay: controller.delays[result.group.now],
                        canTest: controller.isRuntimeAvailable,
                        canToggle: normalizedSearch.isEmpty,
                        selecting: controller.selecting[result.group.name],
                        testingNodes: controller.testingNodes,
                        delays: controller.delays,
                        gradientIndex: groupGradient(for: result.group.name),
                        onToggle: { openGroup(result.group.name) },
                        onTest: { Task { await controller.testGroup(result.group.name) } },
                        onTestNode: { name in Task { await controller.testNode(name, in: result.group.name) } },
                        onGradient: { setGradient($0, for: result.group.name) },
                        onSelect: { name in
                            Task { await controller.select(group: result.group.name, name: name) }
                        })
                    .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(0)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .refreshable { await reload() }
    }

    private var gridGroupList: some View {
        let results = displayedGroups
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !controller.isRuntimeAvailable {
                    Label("VPN 未连接。选择会保存，并在下次连接时生效；测速需连接后使用。",
                          systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
                if let error = controller.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                }
                if results.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    if let expandedGroup = results.first(where: { $0.isExpanded }) {
                        GroupExpandedPanel(
                            group: expandedGroup.group,
                            isTesting: controller.testing.contains(expandedGroup.group.name),
                            canTest: controller.isRuntimeAvailable,
                            selecting: controller.selecting[expandedGroup.group.name],
                            testingNodes: controller.testingNodes,
                            delays: controller.delays,
                            gradientIndex: groupGradient(for: expandedGroup.group.name),
                            onToggle: { openGroup(expandedGroup.group.name) },
                            onTest: { Task { await controller.testGroup(expandedGroup.group.name) } },
                            onTestNode: { name in Task { await controller.testNode(name, in: expandedGroup.group.name) } },
                            onGradient: { setGradient($0, for: expandedGroup.group.name) },
                            onSelect: { name in
                                Task { await controller.select(group: expandedGroup.group.name, name: name) }
                            })
                        .padding(.horizontal, 14)
                    }
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ], spacing: 12) {
                        ForEach(results.filter { !$0.isExpanded }) { result in
                            GroupGridCard(
                                group: result.group,
                                gradientIndex: groupGradient(for: result.group.name),
                                onToggle: { openGroup(result.group.name) },
                                onGradient: { setGradient($0, for: result.group.name) })
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
            .padding(.vertical, 10)
        }
        .background(Color.clear)
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
        if nodeLayout == .grid {
            expanded = expanded.contains(name) ? [] : [name]
            return
        }
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
        assignMissingGradients()
    }

    private func loadGroupGradients() {
        guard let data = gradientStorage.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        groupGradients = values
    }

    private func setGradient(_ value: Int, for group: String) {
        groupGradients[group] = value
        persistGradients()
    }

    private func groupGradient(for group: String) -> Int {
        groupGradients[group] ?? GroupGradient.defaultIndex(for: group)
    }

    private func assignMissingGradients() {
        var updated = groupGradients
        for group in controller.groups where updated[group.name] == nil {
            updated[group.name] = GroupGradient.defaultIndex(for: group.name)
        }
        guard updated != groupGradients else { return }
        groupGradients = updated
        persistGradients()
    }

    private func persistGradients() {
        guard let data = try? JSONEncoder().encode(groupGradients),
              let raw = String(data: data, encoding: .utf8) else { return }
        gradientStorage = raw
    }
}

private enum ProxyNodeLayout: String {
    case list
    case grid

    var systemImage: String {
        self == .list ? "list.bullet" : "square.grid.2x2"
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

private struct StrategyGroupListPanel: View {
    let group: ProxyGroup
    let visibleNodes: [ProxyGroupNode]
    let isExpanded: Bool
    let isTesting: Bool
    let currentDelay: Int?
    let canTest: Bool
    let canToggle: Bool
    let selecting: String?
    let testingNodes: Set<String>
    let delays: [String: Int]
    let gradientIndex: Int
    let onToggle: () -> Void
    let onTest: () -> Void
    let onTestNode: (String) -> Void
    let onGradient: (Int) -> Void
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                GroupHeaderButton(group: group,
                                  isExpanded: isExpanded,
                                  canToggle: canToggle,
                                  onToggle: onToggle)
                if isExpanded {
                    testButton
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contextMenu { GradientMenu(selected: gradientIndex, onSelect: onGradient) }

            if isExpanded {
                Divider().overlay(Color.primary.opacity(0.10))
                Group {
                if group.all.isEmpty {
                    Text("该策略组没有节点")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 14)
                } else {
                    ForEach(Array(visibleNodes.enumerated()), id: \.element.id) { index, item in
                        ProxyNodeListRow(
                            node: item.name,
                            isCurrent: item.name == group.now,
                            isSelecting: selecting == item.name,
                            isSelectionBlocked: selecting != nil,
                            selectable: group.selectable,
                            isReadOnly: !canTest && !group.selectable,
                            canTest: canTest,
                            isTestingDelay: testingNodes.contains(item.name),
                            delay: delays[item.name],
                            onTestDelay: { onTestNode(item.name) },
                            onSelect: { onSelect(item.name) })
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .overlay(alignment: .bottom) {
                            if index < visibleNodes.count - 1 {
                                Divider()
                                    .overlay(Color.primary.opacity(0.12))
                                    .padding(.leading, 46)
                                    .padding(.trailing, 14)
                            }
                        }
                    }
                }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isExpanded)
        .background(GroupGradient.background(for: gradientIndex))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        Image(systemName: isTesting ? "hourglass" : "speedometer")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(testTint)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private var testTint: Color {
        if isTesting || currentDelay == nil { return Color.accentColor }
        return DelayBadge.tint(currentDelay)
    }

}

private struct GroupHeaderButton: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let group: ProxyGroup
    let isExpanded: Bool
    let canToggle: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                GroupIcon(url: group.icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    Text(group.now.isEmpty ? "未选择" : group.now)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? nil : 30,
                               alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: canToggle ? "chevron.right" : "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 44)
                    .rotationEffect(.degrees(canToggle && isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.16), value: isExpanded)
            }
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(canToggle ? (isExpanded ? "双击收起" : "双击展开") : "双击查看完整策略组")
    }

    private var accessibilityValue: String {
        let current = group.now.isEmpty ? "未选择节点" : "当前节点 \(group.now)"
        let state = canToggle ? (isExpanded ? "已展开" : "已折叠") : "搜索结果"
        return "\(group.all.count) 个节点，\(current)，\(state)"
    }
}

private enum GroupGradient {
    struct Palette {
        let name: String
        let colors: [Color]
        let motif: String
    }

    static let palettes: [Palette] = [
        .init(name: "海岸", colors: [.blue.opacity(0.34), .cyan.opacity(0.12)], motif: "circle.grid.2x2.fill"),
        .init(name: "霞光", colors: [.purple.opacity(0.31), .pink.opacity(0.14)], motif: "sparkles"),
        .init(name: "日光", colors: [.orange.opacity(0.31), .yellow.opacity(0.14)], motif: "sun.max.fill"),
        .init(name: "森林", colors: [.green.opacity(0.30), .mint.opacity(0.13)], motif: "leaf.fill"),
        .init(name: "深海", colors: [.indigo.opacity(0.32), .teal.opacity(0.14)], motif: "drop.fill"),
        .init(name: "莓果", colors: [.red.opacity(0.28), .purple.opacity(0.14)], motif: "diamond.fill"),
        .init(name: "石墨", colors: [.gray.opacity(0.25), .indigo.opacity(0.13)], motif: "hexagon.fill"),
    ]

    static func defaultIndex(for name: String) -> Int {
        let seed = name.unicodeScalars.reduce(UInt(5381)) {
            ($0 &* 33) &+ UInt($1.value)
        }
        return Int(seed % UInt(palettes.count))
    }

    static func name(for index: Int) -> String {
        palette(for: index).name
    }

    static func background(for index: Int) -> some View {
        let palette = palette(for: index)
        return ZStack {
            Color(uiColor: .secondarySystemGroupedBackground).opacity(0.70)
            LinearGradient(colors: palette.colors,
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            Image(systemName: palette.motif)
                .font(.system(size: 72, weight: .medium))
                .foregroundStyle(palette.colors[0].opacity(0.24))
                .rotationEffect(.degrees(-16))
                .offset(x: 54, y: -20)
                .accessibilityHidden(true)
        }
    }

    private static func palette(for index: Int) -> Palette {
        palettes.indices.contains(index) ? palettes[index] : palettes[defaultIndex(for: "Cora")]
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
            guard let url else { return }
            guard image == nil else { return }
            failed = false
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
    let canTest: Bool
    let isTestingDelay: Bool
    let delay: Int?
    let onTestDelay: () -> Void
    let onSelect: () -> Void

    var body: some View {
        Group {
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
        .contextMenu {
            Button(action: onTestDelay) {
                Label(isTestingDelay ? "正在测速" : "测试此节点延迟",
                      systemImage: isTestingDelay ? "hourglass" : "speedometer")
            }
            .disabled(!canTest || isTestingDelay)
        } preview: {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private var row: some View {
        ProxyNodeRow(
            node: node,
            isCurrent: isCurrent,
            isSelecting: isSelecting,
            delay: delay)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(node)
            .accessibilityValue(accessibilityValue)
            .background {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.42), lineWidth: 1)
                        }
                }
            }
    }

    private var accessibilityValue: String {
        [
            isCurrent ? "当前节点" : nil,
            DelayBadge.accessibilityText(delay),
            isReadOnly ? "离线只读" : (selectable ? nil : "由策略组自动选择"),
        ]
        .compactMap { $0 }
        .joined(separator: "，")
    }
}

private struct GroupGridCard: View {
    let group: ProxyGroup
    let gradientIndex: Int
    let onToggle: () -> Void
    let onGradient: (Int) -> Void

    var body: some View {
        GroupCompactHeader(group: group, onToggle: onToggle)
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(GroupGradient.background(for: gradientIndex))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            GradientMenu(selected: gradientIndex, onSelect: onGradient)
        }
    }
}

private struct GroupExpandedPanel: View {
    let group: ProxyGroup
    let isTesting: Bool
    let canTest: Bool
    let selecting: String?
    let testingNodes: Set<String>
    let delays: [String: Int]
    let gradientIndex: Int
    let onToggle: () -> Void
    let onTest: () -> Void
    let onTestNode: (String) -> Void
    let onGradient: (Int) -> Void
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupExpandedHeader(group: group,
                                isTesting: isTesting,
                                canTest: canTest,
                                onToggle: onToggle,
                                onTest: onTest)
            .contextMenu { GradientMenu(selected: gradientIndex, onSelect: onGradient) }

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ], spacing: 12) {
                ForEach(group.nodes) { item in
                    GroupNodeGridCell(node: item,
                                      isCurrent: item.name == group.now,
                                      isSelecting: selecting == item.name,
                                      isSelectionBlocked: selecting != nil,
                                      selectable: group.selectable,
                                      canTest: canTest,
                                      isTestingDelay: testingNodes.contains(item.name),
                                      delay: delays[item.name],
                                      onTestDelay: { onTestNode(item.name) },
                                      onSelect: { onSelect(item.name) })
                }
            }
        }
        .padding(14)
        .background(GroupGradient.background(for: gradientIndex))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeInOut(duration: 0.22), value: group.id)
    }
}

private struct GroupCompactHeader: View {
    let group: ProxyGroup
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 9) {
                GroupIcon(url: group.icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name).font(.headline).lineLimit(1)
                    Text(group.now.isEmpty ? "未选择" : group.now)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .frame(minHeight: 30, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GroupExpandedHeader: View {
    let group: ProxyGroup
    let isTesting: Bool
    let canTest: Bool
    let onToggle: () -> Void
    let onTest: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            GroupCompactHeader(group: group, onToggle: onToggle)
            Button(action: onTest) {
                Image(systemName: isTesting ? "hourglass" : "speedometer")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(SpeedTestButtonStyle())
            .foregroundStyle(Color.accentColor)
            .disabled(isTesting || !canTest)
            .frame(width: 56, height: 56)
            .contentShape(Rectangle())
            .zIndex(2)
            .accessibilityLabel("测试\(group.name)延迟")
        }
    }
}

private struct GroupNodeGridCell: View {
    let node: ProxyGroupNode
    let isCurrent: Bool
    let isSelecting: Bool
    let isSelectionBlocked: Bool
    let selectable: Bool
    let canTest: Bool
    let isTestingDelay: Bool
    let delay: Int?
    let onTestDelay: () -> Void
    let onSelect: () -> Void

    var body: some View {
        ZStack {
            if selectable && !isCurrent {
                Button(action: onSelect) { card }
                    .buttonStyle(.plain)
                    .disabled(isSelectionBlocked)
            } else if isCurrent {
                card
                    .accessibilityAddTraits(.isSelected)
                    .onTapGesture { }
            } else {
                card
                    .onTapGesture { }
            }
        }
        .contextMenu {
            Button(action: onTestDelay) {
                Label(isTestingDelay ? "正在测速" : "测试此节点延迟",
                      systemImage: isTestingDelay ? "hourglass" : "speedometer")
            }
            .disabled(!canTest || isTestingDelay)
        } preview: {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Text(node.name)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(2)
                    .frame(minHeight: 36, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelecting {
                    ProgressView().controlSize(.mini)
                } else if isCurrent {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                if isTestingDelay {
                    ProgressView().controlSize(.mini)
                } else {
                    DelayBadge(delay: delay)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCurrent
                      ? Color.accentColor.opacity(0.12)
                      : Color(uiColor: .secondarySystemGroupedBackground).opacity(0.82))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isCurrent
                                ? Color.accentColor.opacity(0.48)
                                : Color.primary.opacity(0.08),
                                lineWidth: isCurrent ? 1.5 : 1)
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(node.name)
        .accessibilityValue(isCurrent ? "当前节点，\(DelayBadge.accessibilityText(delay))" : DelayBadge.accessibilityText(delay))
    }
}

private struct GradientMenu: View {
    let selected: Int
    let onSelect: (Int) -> Void

    var body: some View {
        Menu("分组背景") {
            ForEach(Array(GroupGradient.palettes.enumerated()), id: \.offset) { index, _ in
                Button { onSelect(index) } label: {
                    Label(GroupGradient.name(for: index),
                          systemImage: index == selected ? "checkmark" : "paintpalette")
                }
            }
        }
    }
}

private struct ProxyNodeRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let node: String
    let isCurrent: Bool
    let isSelecting: Bool
    let delay: Int?

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            HStack(alignment: .top, spacing: 10) {
                marker
                labels
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        } else {
            HStack(spacing: 10) {
                marker
                labels
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
            HStack(spacing: 8) {
                Spacer(minLength: 4)
                DelayBadge(delay: delay)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
