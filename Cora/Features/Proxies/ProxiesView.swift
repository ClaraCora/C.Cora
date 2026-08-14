import SwiftUI
import UIKit

/// 节点页：紧凑展示策略组，展开后可搜索、切换并比较节点延迟。
struct ProxiesView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @StateObject private var controller = ProxyController()
    @State private var expanded: Set<String> = []
    @State private var gridRowFrames: [Int: CGRect] = [:]
    @State private var gridRestoreAnchors: [String: UnitPoint] = [:]
    @State private var gridScrollRequest: GridScrollRequest?
    @State private var expandedPanelFrames: [String: CGRect] = [:]
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var groupGradients: [String: Int] = [:]
    @AppStorage("proxyNodeLayout") private var layoutRawValue = ProxyNodeLayout.grid.rawValue
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
            .onChange(of: layoutRawValue) { _, value in
                // Both layouts share one expansion model. Keep a single valid group
                // when switching layouts so neither view inherits stale open rows.
                let retained = controller.groups.first(where: { expanded.contains($0.name) })?.name
                expanded = retained.map { [$0] } ?? []
                gridScrollRequest = nil
                expandedPanelFrames = [:]
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

    private var activeExpandedGroupName: String? {
        guard normalizedSearch.isEmpty, expanded.count == 1 else { return nil }
        return expanded.first
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
        let activeGroupName = activeExpandedGroupName

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !controller.isRuntimeAvailable {
                    Label("VPN 未连接。选择会保存，并在下次连接时生效；测速需连接后使用。",
                          systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                if let error = controller.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if results.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(results) { result in
                        listPanel(for: result,
                                  activeGroupName: activeGroupName)
                    }
                }

                if activeGroupName != nil {
                    Color.clear
                        .frame(height: 120)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .animation(.easeOut(duration: 0.16), value: expanded)
        }
        .coordinateSpace(name: StrategyCoordinateSpace.name)
        .simultaneousGesture(listDismissGesture(activeGroupName))
        .onPreferenceChange(ExpandedPanelFramePreferenceKey.self) { frames in
            expandedPanelFrames = frames
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .refreshable { await reload() }
    }

    private func listPanel(for result: DisplayedProxyGroup,
                           activeGroupName: String?) -> some View {
        let group = result.group
        return StrategyGroupListPanel(
            group: group,
            allGroups: controller.groups,
            visibleNodes: result.nodes,
            isExpanded: result.isExpanded,
            isInteractionLocked: activeGroupName != nil && activeGroupName != group.name,
            isTesting: controller.testing.contains(group.name),
            canTest: controller.isRuntimeAvailable,
            selecting: controller.selecting[group.name],
            testingNodes: controller.testingNodes,
            delays: controller.delays,
            gradientIndex: groupGradient(for: group.name),
            onToggle: { toggleListGroup(group.name) },
            onTest: { Task { await controller.testGroup(group.name) } },
            onTestNode: { name in Task { await controller.testNode(name, in: group.name) } },
            onGradient: { setGradient($0, for: group.name) },
            onRandomizeAll: randomizeAllGradients,
            onSelect: { name in Task { await controller.select(group: group.name, name: name) } })
            .background {
                if result.isExpanded {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ExpandedPanelFramePreferenceKey.self,
                            value: [group.name: geometry.frame(
                                in: .named(StrategyCoordinateSpace.name))])
                    }
                }
            }
    }

    private var gridGroupList: some View {
        let results = displayedGroups
        let rows = stride(from: 0, to: results.count, by: 2).map { index in
            Array(results[index..<min(index + 2, results.count)])
        }
        let upwardExpansionStart = max(0, rows.count - 3)
        let activeGroupName = activeExpandedGroupName
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
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
                        ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                            let expandsUpward = rowIndex >= upwardExpansionStart
                            VStack(alignment: .leading, spacing: 12) {
                                if expandsUpward,
                                   let expandedGroup = row.first(where: { $0.isExpanded }) {
                                    expandedPanel(for: expandedGroup) {
                                        toggleGridGroup(expandedGroup.group.name,
                                                        rowIndex: rowIndex,
                                                        viewportHeight: viewport.size.height)
                                    }
                                        .id(expandedPanelID(for: expandedGroup.group.name))
                                }

                                HStack(alignment: .top, spacing: 12) {
                                    ForEach(row) { result in
                                        GroupGridCard(
                                            group: result.group,
                                            gradientIndex: groupGradient(for: result.group.name),
                                            isInteractionLocked: activeGroupName != nil &&
                                                activeGroupName != result.group.name,
                                            onToggle: {
                                                toggleGridGroup(result.group.name,
                                                                rowIndex: rowIndex,
                                                                viewportHeight: viewport.size.height)
                                            },
                                            onGradient: { setGradient($0, for: result.group.name) },
                                            onRandomizeAll: randomizeAllGradients)
                                            .frame(maxWidth: .infinity)
                                    }
                                    if row.count == 1 {
                                        Color.clear
                                            .frame(maxWidth: .infinity, minHeight: 76)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .id(gridRowID(rowIndex))
                                .background {
                                    GeometryReader { rowGeometry in
                                        Color.clear.preference(
                                            key: GridRowFramePreferenceKey.self,
                                            value: [
                                                rowIndex: rowGeometry.frame(
                                                    in: .named(GridCoordinateSpace.name))
                                            ])
                                    }
                                }
                                if !expandsUpward,
                                   let expandedGroup = row.first(where: { $0.isExpanded }) {
                                    expandedPanel(for: expandedGroup) {
                                        toggleGridGroup(expandedGroup.group.name,
                                                        rowIndex: rowIndex,
                                                        viewportHeight: viewport.size.height)
                                    }
                                        .id(expandedPanelID(for: expandedGroup.group.name))
                                }
                            }
                        }
                        // The tab bar can cover the last row when the content is shorter
                        // than the viewport. Keep enough inert content below the grid so
                        // an expanded panel can always be scrolled into the safe area.
                        if !expanded.isEmpty {
                            Color.clear
                                .frame(height: max(260, viewport.size.height + 80))
                                .accessibilityHidden(true)
                        }
                    }
                }
                .coordinateSpace(name: GridCoordinateSpace.name)
                .coordinateSpace(name: StrategyCoordinateSpace.name)
                .simultaneousGesture(gridDismissGesture(activeGroupName))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                .background(Color.clear)
                .refreshable { await reload() }
                .onPreferenceChange(GridRowFramePreferenceKey.self) { frames in
                    if gridRowFrames != frames {
                        gridRowFrames = frames
                    }
                }
                .onPreferenceChange(ExpandedPanelFramePreferenceKey.self) { frames in
                    expandedPanelFrames = frames
                }
                .task(id: gridScrollRequest) {
                    guard let request = gridScrollRequest else { return }
                    // Re-apply the target after the expanded panel has completed layout.
                    for delay in [UInt64(60_000_000), UInt64(180_000_000)] {
                        try? await Task.sleep(nanoseconds: delay)
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(request.targetID, anchor: request.anchor)
                        }
                    }
                }
            }
        }
        .frame(minHeight: 0)
    }

    private func randomizeAllGradients() {
        var updated = groupGradients
        for group in controller.groups {
            updated[group.name] = Int.random(in: 0..<GroupGradient.palettes.count)
        }
        groupGradients = updated
        persistGradients()
    }

    private func expandedPanelID(for name: String) -> String {
        "proxy-expanded-\(name)"
    }

    private func gridRowID(_ index: Int) -> String {
        "proxy-grid-row-\(index)"
    }

    @ViewBuilder
    private func expandedPanel(for result: DisplayedProxyGroup,
                               onToggle: @escaping () -> Void) -> some View {
        GroupExpandedPanel(
            group: result.group,
            allGroups: controller.groups,
            isTesting: controller.testing.contains(result.group.name),
            canTest: controller.isRuntimeAvailable,
            selecting: controller.selecting[result.group.name],
            testingNodes: controller.testingNodes,
            delays: controller.delays,
             gradientIndex: groupGradient(for: result.group.name),
            onToggle: onToggle,
            onTest: { Task { await controller.testGroup(result.group.name) } },
            onTestNode: { name in Task { await controller.testNode(name, in: result.group.name) } },
             onGradient: { setGradient($0, for: result.group.name) },
            onRandomizeAll: randomizeAllGradients,
            onSelect: { name in
                Task { await controller.select(group: result.group.name, name: name) }
            })
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ExpandedPanelFramePreferenceKey.self,
                    value: [result.group.name: geometry.frame(
                        in: .named(StrategyCoordinateSpace.name))])
            }
        }
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

    private func toggleListGroup(_ name: String) {
        guard normalizedSearch.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            expanded = expanded.contains(name) ? [] : [name]
        }
        gridScrollRequest = nil
        expandedPanelFrames = [:]
    }

    private func dismissExpandedGroup(_ name: String) {
        guard expanded.contains(name) else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            expanded.remove(name)
        }
        gridScrollRequest = nil
        gridRestoreAnchors.removeValue(forKey: name)
        expandedPanelFrames = [:]
    }

    private func gridDismissGesture(_ activeGroupName: String?) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            guard let name = activeGroupName,
                  let frame = expandedPanelFrames[name],
                  !frame.contains(value.location) else { return }
            dismissExpandedGroup(name)
        }
    }

    private func listDismissGesture(_ activeGroupName: String?) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            guard let name = activeGroupName,
                  let frame = expandedPanelFrames[name],
                  !frame.contains(value.location) else { return }
            dismissExpandedGroup(name)
        }
    }

    private func toggleGridGroup(_ name: String,
                                 rowIndex: Int,
                                 viewportHeight: CGFloat) {
        guard normalizedSearch.isEmpty else {
            searchText = ""
            openGridGroup(name)
            return
        }

        if expanded.contains(name) {
            dismissExpandedGroup(name)
            return
        }

        saveGridRestoreAnchor(for: name,
                              rowIndex: rowIndex,
                              viewportHeight: viewportHeight)
        withAnimation(.easeOut(duration: 0.18)) {
            // A grid row has room for one detail panel. Keeping one explicit expansion
            // also avoids Set ordering from choosing an unrelated scroll target.
            expanded = [name]
        }
        // Scroll to the panel itself. This is important for the final rows: their
        // panel is rendered above the cards, so anchoring the row leaves the panel
        // partially behind the navigation/tab bars.
        gridScrollRequest = GridScrollRequest(targetID: expandedPanelID(for: name),
                                              anchor: .top)
    }

    private func openGridGroup(_ name: String) {
        guard controller.groups.contains(where: { $0.name == name }) else {
            expanded = [name]
            return
        }
        expanded = [name]
        gridScrollRequest = GridScrollRequest(targetID: expandedPanelID(for: name),
                                              anchor: .top)
    }

    private func saveGridRestoreAnchor(for name: String,
                                       rowIndex: Int,
                                       viewportHeight: CGFloat) {
        guard let frame = gridRowFrames[rowIndex], viewportHeight > frame.height else {
            gridRestoreAnchors[name] = .center
            return
        }
        let availableTravel = viewportHeight - frame.height
        let relativeY = min(max(frame.minY / availableTravel, 0), 1)
        gridRestoreAnchors[name] = UnitPoint(x: 0.5, y: relativeY)
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

private struct GridScrollRequest: Hashable {
    let id = UUID()
    let targetID: String
    let anchor: UnitPoint

    static func == (lhs: GridScrollRequest, rhs: GridScrollRequest) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private enum GridCoordinateSpace {
    static let name = "proxy-grid-viewport"
}

private enum StrategyCoordinateSpace {
    static let name = "proxy-strategy-viewport"
}

private struct GridRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct ExpandedPanelFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect],
                       nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct DisplayedProxyGroup: Identifiable {
    let group: ProxyGroup
    let nodes: [ProxyGroupNode]
    let isExpanded: Bool

    var id: String { group.id }
}

private struct StrategyGroupListPanel: View {
    let group: ProxyGroup
    let allGroups: [ProxyGroup]
    let visibleNodes: [ProxyGroupNode]
    let isExpanded: Bool
    let isInteractionLocked: Bool
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
    let onRandomizeAll: () -> Void
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                GroupExpandedHeader(group: group,
                                    isTesting: isTesting,
                                    canTest: canTest,
                                    onToggle: onToggle,
                                    onTest: onTest)
            } else {
                GroupCompactHeader(group: group, onToggle: onToggle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contextMenu {
                GradientMenu(selected: gradientIndex,
                             onSelect: onGradient,
                             onRandomizeAll: onRandomizeAll)
            }

            if isExpanded {
                Divider().overlay(Color.primary.opacity(0.10))
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
                            referencedGroup: allGroups.first {
                                $0.name == item.name && $0.name != group.name
                            },
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
        }
        .background(GroupGradient.background(for: gradientIndex))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeOut(duration: 0.16), value: isExpanded)
        .allowsHitTesting(!isInteractionLocked)
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
    let referencedGroup: ProxyGroup?
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
        ZStack {
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
                    .onTapGesture { }
            } else {
                row
                    .onTapGesture { }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: onTestDelay) {
                Label(isTestingDelay ? "正在测速" : "测试此节点延迟",
                      systemImage: isTestingDelay ? "hourglass" : "speedometer")
            }
            .disabled(!canTest || isTestingDelay)
        }
        .contentShape(Rectangle())
    }

    private var row: some View {
        ProxyNodeRow(
            node: node,
            isCurrent: isCurrent,
            isSelecting: isSelecting,
            subtitle: referencedGroup.map {
                $0.now.isEmpty ? "未选择" : $0.now
            },
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
    let isInteractionLocked: Bool
    let onToggle: () -> Void
    let onGradient: (Int) -> Void
    let onRandomizeAll: (() -> Void)?

    var body: some View {
        GroupCompactHeader(group: group, onToggle: onToggle)
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(GroupGradient.background(for: gradientIndex))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            GradientMenu(selected: gradientIndex, onSelect: onGradient,
                         onRandomizeAll: onRandomizeAll)
        }
        .allowsHitTesting(!isInteractionLocked)
    }
}

private struct GroupExpandedPanel: View {
    let group: ProxyGroup
    let allGroups: [ProxyGroup]
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
    let onRandomizeAll: (() -> Void)?
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupExpandedHeader(group: group,
                                isTesting: isTesting,
                                canTest: canTest,
                                onToggle: onToggle,
                                onTest: onTest)
            .contextMenu {
                GradientMenu(selected: gradientIndex,
                             onSelect: onGradient,
                             onRandomizeAll: onRandomizeAll)
            }

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ], spacing: 8) {
                ForEach(group.nodes) { item in
                    GroupNodeGridCell(node: item,
                                      referencedGroup: allGroups.first {
                                          $0.name == item.name && $0.name != group.name
                                      },
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
        .padding(8)
        .background(GroupGradient.background(for: gradientIndex))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeOut(duration: 0.16), value: group.id)
    }
}

private struct GroupCompactHeader: View {
    let group: ProxyGroup
    let onToggle: () -> Void
    var compact = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 9) {
                GroupIcon(url: group.icon)
                VStack(alignment: .leading, spacing: compact ? 1 : 3) {
                    Text(group.name).font(.headline).lineLimit(1)
                    Text(group.now.isEmpty ? "未选择" : group.now)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
                        .frame(minHeight: compact ? 17 : 30, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 44 : 54, alignment: .leading)
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
            GroupCompactHeader(group: group, onToggle: onToggle, compact: true)
            Button(action: onTest) {
                Image(systemName: isTesting ? "hourglass" : "speedometer")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(SpeedTestButtonStyle())
            .foregroundStyle(Color.accentColor)
            .disabled(isTesting || !canTest)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .zIndex(2)
            .accessibilityLabel("测试\(group.name)延迟")
        }
    }
}

private struct GroupNodeGridCell: View {
    let node: ProxyGroupNode
    let referencedGroup: ProxyGroup?
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
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(referencedGroup?.name ?? node.name)
                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .lineLimit(referencedGroup == nil ? 2 : 1)
                        .frame(minHeight: referencedGroup == nil ? 34 : 18,
                               alignment: .topLeading)
                    if let referencedGroup {
                        Text(referencedGroup.now.isEmpty ? "未选择" : referencedGroup.now)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelecting {
                    ProgressView().controlSize(.mini)
                } else if isCurrent {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
            }
            HStack {
                Spacer()
                if isTestingDelay {
                    ProgressView().controlSize(.mini)
                } else {
                    DelayBadge(delay: delay, compact: true)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
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
    let onRandomizeAll: (() -> Void)?

    var body: some View {
        Menu("分组背景") {
            ForEach(Array(GroupGradient.palettes.enumerated()), id: \.offset) { index, _ in
                Button { onSelect(index) } label: {
                    Label(GroupGradient.name(for: index),
                          systemImage: index == selected ? "checkmark" : "paintpalette")
                }
            }
            if let onRandomizeAll {
                Divider()
                Button(action: onRandomizeAll) {
                    Label("全部随机图案", systemImage: "shuffle")
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
    let subtitle: String?
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
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
    let compact: Bool

    init(delay: Int?, compact: Bool = false) {
        self.delay = delay
        self.compact = compact
    }

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
        .padding(.vertical, compact ? 1 : 3)
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
