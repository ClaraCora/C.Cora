import SwiftUI
import UIKit

/// 策略/节点页：按固定类别展示分组，展开后可搜索、切换并比较节点延迟。
struct ProxiesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var core: CoreStateManager
    @ObservedObject var controller: ProxyController
    let category: ProxyGroupCategory
    @State private var expanded: Set<String> = []
    @State private var geometryCache = ProxyGeometryCache()
    @State private var gridScrollRequest: GridScrollRequest?
    @State private var gridExpansion: GridExpansionState?
    @State private var pendingGridGroupName: String?
    @State private var gridColumnCount = ProxyGridLayout.defaultColumnCount
    @State private var toolbarControlsVisible = true
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var groupGradients: [String: Int] = [:]
    @State private var activeNodeTestTarget: ProxyNodeTestTarget?
    @StateObject private var unlockTests = UnlockTestController.shared
    @ObservedObject private var detectionScripts = ExternalScriptStore.shared
    @AppStorage("proxyNodeLayout") private var layoutRawValue = ProxyNodeLayout.grid.rawValue
    @AppStorage("proxyGroupGradients") private var gradientStorage = "{}"
    @AppStorage("proxyShowHiddenGroups") private var showHiddenGroups = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppAmbientBackground()
                navigationContent

                if unlockTests.isRunning || unlockTests.result != nil {
                    UnlockTestOverlay(
                        isRunning: unlockTests.isRunning,
                        nodeName: unlockTests.runningNodeName ?? unlockTests.result?.nodeName ?? "",
                        groupName: unlockTests.runningGroupName ?? unlockTests.result?.groupName ?? "",
                        scriptName: unlockTests.runningScriptName ?? unlockTests.result?.scriptName ?? "检测",
                        result: unlockTests.result,
                        onDismiss: { unlockTests.result = nil })
                        .transition(.opacity)
                        .zIndex(20)
                }
            }
            .animation(.easeOut(duration: 0.18), value: unlockTests.isRunning)
            .animation(.easeOut(duration: 0.18), value: unlockTests.result?.id)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    HStack(spacing: 4) {
                        if hasHiddenGroups {
                            hiddenGroupsToggle
                        }
                        if showsSearch {
                            layoutMenu

                            Button {
                                toggleSearchPresentation()
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .accessibilityLabel("搜索节点")
                            .help("搜索节点")
                        }
                        if showsCurrentSelectionTest {
                            currentSelectionTestControl
                        }
                    }
                    .opacity(toolbarControlsVisible ? 1 : 0)
                    .allowsHitTesting(toolbarControlsVisible)
                    .accessibilityHidden(!toolbarControlsVisible)
                    .frame(width: toolbarControlsVisible &&
                        (hasHiddenGroups || showsSearch || showsCurrentSelectionTest) ? nil : 0,
                           height: 44,
                           alignment: .trailing)
                    .clipped()
                    .animation(.easeOut(duration: 0.16), value: toolbarControlsVisible)
                }
            }
            .alert("解锁测试", isPresented: Binding(
                get: { unlockTests.error != nil },
                set: { if !$0 { unlockTests.error = nil } }
            )) {
                Button("好") { unlockTests.error = nil }
            } message: {
                Text(unlockTests.error ?? "")
            }
            .onAppear {
                toolbarControlsVisible = true
            }
            .onChange(of: core.status) { status in
                switch status {
                case .connecting, .disconnected, .invalid:
                    resetDisplayedGroupState()
                default:
                    break
                }
            }
            .task {
                loadGroupGradients()
                assignMissingGradients()
                if !detectionScripts.hasManifest {
                    try? await detectionScripts.refreshManifest()
                }
            }
            .onChange(of: controller.catalogRevision) { _ in
                assignMissingGradients()
                synchronizeDisplayedGroups()
            }
            .onChange(of: gradientStorage) { _ in
                loadGroupGradients()
            }
            .onChange(of: isSearchPresented) { presented in
                if !presented { searchText = "" }
                toolbarControlsVisible = true
                activeNodeTestTarget = nil
            }
            .onChange(of: searchText) { value in
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      gridExpansion != nil else { return }
                gridExpansion = nil
                gridScrollRequest = nil
                expanded = []
                activeNodeTestTarget = nil
                geometryCache.expandedPanelFrames.removeAll()
            }
            .onChange(of: layoutRawValue) { value in
                // Both layouts share one expansion model. Keep a single valid group
                // when switching layouts so neither view inherits stale open rows.
                let retained = visibleGroups.first(where: { expanded.contains($0.name) })?.name
                expanded = retained.map { [$0] } ?? []
                gridScrollRequest = nil
                geometryCache.expandedPanelFrames.removeAll()
                gridExpansion = nil
                pendingGridGroupName = ProxyNodeLayout(rawValue: value) == .grid ? retained : nil
                toolbarControlsVisible = true
                activeNodeTestTarget = nil
            }
            .onChange(of: gridColumnCount) { _ in
                synchronizeDisplayedGroups()
            }
            .onChange(of: showHiddenGroups) { _ in
                resetDisplayedGroupState()
            }
            .onDisappear { activeNodeTestTarget = nil }
        }
    }

    @ViewBuilder private var navigationContent: some View {
        if showsSearch && isSearchPresented {
            content
                .coraDrawerSearchable(text: $searchText,
                                      isPresented: $isSearchPresented,
                                      prompt: "搜索策略组或节点")
        } else {
            content
        }
    }

    private func toggleSearchPresentation() {
        if #available(iOS 17.0, *) {
            isSearchPresented = true
        } else {
            isSearchPresented.toggle()
        }
    }

    private var showsSearch: Bool {
        !visibleGroups.isEmpty
    }

    private var showsCurrentSelectionTest: Bool {
        !visibleGroups.isEmpty
    }

    private var hasHiddenGroups: Bool {
        let allGroupNames = controller.resolutionIndex.groupNames
        return controller.groups.contains { group in
            group.hidden && groupCategory(for: group, groupNames: allGroupNames) == category
        }
    }

    private var selectedGroupCategory: ProxyGroupCategory {
        category
    }

    private var nodeLayout: ProxyNodeLayout {
        ProxyNodeLayout(rawValue: layoutRawValue) ?? .list
    }

    private var expansionAnimation: Animation? {
        guard !reduceMotion else { return nil }
        if #available(iOS 17.0, *) {
            return .snappy(duration: 0.18, extraBounce: 0)
        }
        return .easeInOut(duration: 0.18)
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

    private var hiddenGroupsToggle: some View {
        Toggle(isOn: $showHiddenGroups) {
            Image(systemName: showHiddenGroups ? "eye" : "eye.slash")
        }
        .toggleStyle(.button)
        .accessibilityLabel(showHiddenGroups ? "隐藏分组已显示" : "显示隐藏分组")
        .help(showHiddenGroups ? "隐藏分组已显示" : "显示隐藏分组")
        .frame(width: 44, height: 44)
    }

    @ViewBuilder private var emptyGroupView: some View {
        if normalizedSearch.isEmpty {
            CoraUnavailableState(
                "没有\(selectedGroupCategory.title)",
                systemImage: selectedGroupCategory.systemImage,
                description: emptyGroupDescription)
        } else {
            CoraSearchUnavailableState(query: searchText)
        }
    }

    private var emptyGroupDescription: String {
        if category == .node && controller.mode == "global" {
            return "全局模式仅使用 GLOBAL 策略组，请在策略页面选择出口"
        }
        guard hasHiddenGroups, !showHiddenGroups else {
            return "当前配置没有可显示的\(selectedGroupCategory.title)"
        }
        return "当前没有可显示的\(selectedGroupCategory.title)，隐藏分组可通过右上角眼睛按钮显示"
    }

    @ViewBuilder private var content: some View {
        if let err = controller.error, controller.groups.isEmpty {
            CoraUnavailableState("拿不到节点",
                                 systemImage: "exclamationmark.triangle",
                                 description: err,
                                 actionTitle: "重试") {
                Task { await reload() }
            }
        } else if controller.mode == "direct" && controller.isRuntimeAvailable {
            CoraUnavailableState("直连模式",
                                 systemImage: "arrow.up.forward",
                                 description: "当前为直连模式，不经过代理节点")
        } else if controller.groups.isEmpty && (!controller.hasLoaded || controller.isLoading) {
            ProgressView("加载\(selectedGroupCategory.title)…")
        } else if controller.groups.isEmpty {
            CoraUnavailableState("没有\(selectedGroupCategory.title)",
                                 systemImage: selectedGroupCategory.systemImage,
                                 description: "当前配置没有可显示的\(selectedGroupCategory.title)")
        } else {
            groupList
        }
    }

    private var currentSelectionTestControl: some View {
        Group {
            if !controller.testingCurrentSelectionKeys.isEmpty {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    let targets = currentSelectionTargets
                    Task { await controller.testCurrentSelections(targets) }
                } label: {
                    Image(systemName: "speedometer")
                }
                .disabled(!canTestCurrentSelections)
                .accessibilityLabel("测试本页当前节点延迟")
                .help("测试本页当前节点延迟")
            }
        }
        .frame(width: 44, height: 44)
    }

    private var canTestCurrentSelections: Bool {
        controller.isRuntimeAvailable &&
            !currentSelectionTargets.isEmpty &&
            controller.testing.isEmpty &&
            controller.testingNodes.isEmpty
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
                    emptyGroupView
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
        }
        .coordinateSpace(name: StrategyCoordinateSpace.name)
        .simultaneousGesture(listDismissGesture(activeGroupName))
        .simultaneousGesture(strategyToolbarGesture())
        .onPreferenceChange(ExpandedPanelFramePreferenceKey.self) { frames in
            geometryCache.expandedPanelFrames = frames
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
            groupIndex: controller.resolutionIndex,
            visibleNodes: result.nodes,
            isExpanded: result.isExpanded,
            isInteractionLocked: activeGroupName != nil && activeGroupName != group.name,
            isTesting: controller.testing.contains(group.name),
            canTest: controller.isRuntimeAvailable &&
                controller.testingCurrentSelectionKeys.isEmpty,
            selecting: controller.selecting[group.name],
            testingNodes: controller.testingNodes,
            delays: controller.delays,
            currentSelectionDelay: currentSelectionDelay(for: group),
            isTestingCurrentSelection: isTestingCurrentSelection(for: group),
             gradientIndex: groupGradient(for: group.name),
             onToggle: { toggleListGroup(group.name) },
             onTest: { Task { await controller.testGroup(group.name) } },
             onTestActiveNodeDelay: testActiveNodeDelay,
             onPrepareTestTarget: prepareNodeTestTarget,
            onGradient: { setGradient($0, for: group.name) },
            onRandomizeAll: randomizeAllGradients,
            onSelect: { name in selectNode(name, in: group.name) })
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
        let activeGroupName = gridExpansion?.groupName
        return GeometryReader { viewport in
            let rows = gridRows(results, columnCount: gridColumnCount)
            let upwardExpansionStart = max(0, rows.count - 3)
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
                            emptyGroupView
                        } else {
                            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                                gridRow(row,
                                        rowIndex: rowIndex,
                                        searchExpandsUpward: rowIndex >= upwardExpansionStart,
                                        viewportSize: viewport.size,
                                        activeGroupName: activeGroupName)
                                    .id(gridRowID(rowIndex))
                            }
                        }
                        Color.clear
                            .frame(height: gridFooterHeight(viewport: viewport))
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                .background(Color.clear)
                .refreshable { await reload() }
                .onPreferenceChange(GridCardFramePreferenceKey.self) { frames in
                    geometryCache.gridCardFrames = frames
                    openPendingGridGroupIfPossible(frames: frames,
                                                   viewportSize: viewport.size)
                }
                .onPreferenceChange(ExpandedPanelFramePreferenceKey.self) { frames in
                    geometryCache.expandedPanelFrames = frames
                }
                .onAppear {
                    updateGridColumnCount(for: viewport.size.width)
                }
                .onChange(of: viewport.size.width) { width in
                    updateGridColumnCount(for: width)
                }
                .task(id: gridScrollRequest) {
                    guard let request = gridScrollRequest else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    withAnimation(expansionAnimation) {
                        proxy.scrollTo(request.targetID, anchor: request.anchor)
                    }
                }
            }
        }
        .frame(minHeight: 0)
        .coordinateSpace(name: StrategyCoordinateSpace.name)
        .contentShape(Rectangle())
        .simultaneousGesture(gridDismissGesture(activeGroupName))
        .simultaneousGesture(strategyToolbarGesture())
    }

    private func gridFooterHeight(viewport: GeometryProxy) -> CGFloat {
        guard let expansion = gridExpansion else {
            return 24
        }
        let panelHeight = expansion.estimatedPanelHeight
        let safeAreaClearance = viewport.safeAreaInsets.bottom + 72
        let minimumClearance = max(120, safeAreaClearance)
        // Keep enough trailing content for a single expanded GLOBAL row to move
        // above the tab bar, while avoiding a full-screen spacer for normal rows.
        return max(minimumClearance,
                   viewport.size.height - panelHeight + minimumClearance)
    }

    private func gridRow(_ row: [DisplayedProxyGroup],
                         rowIndex: Int,
                         searchExpandsUpward: Bool,
                         viewportSize: CGSize,
                         activeGroupName: String?) -> some View {
        let activeExpansion = gridExpansion.flatMap { expansion in
            expansion.rowIndex == rowIndex ? expansion : nil
        }
        let activeResult = activeExpansion.flatMap { expansion in
            row.first { $0.group.name == expansion.groupName }
        }
        let searchResult = normalizedSearch.isEmpty
            ? nil
            : row.first(where: { $0.isExpanded })

        return VStack(alignment: .leading, spacing: 12) {
            if let expansion = activeExpansion, let activeResult {
                expandedPanel(for: activeResult,
                              animated: true) {
                    toggleGridGroup(activeResult.group.name,
                                    rowIndex: rowIndex,
                                    viewportSize: viewportSize)
                }
                .id(expandedPanelID(for: activeResult.group.name))
            } else {
                if searchExpandsUpward, let searchResult {
                    expandedPanel(for: searchResult) {
                        toggleGridGroup(searchResult.group.name,
                                        rowIndex: rowIndex,
                                        viewportSize: viewportSize)
                    }
                    .id(expandedPanelID(for: searchResult.group.name))
                }

                gridCardsRow(row,
                             rowIndex: rowIndex,
                             viewportSize: viewportSize,
                             activeGroupName: activeGroupName)

                if !searchExpandsUpward, let searchResult {
                    expandedPanel(for: searchResult) {
                        toggleGridGroup(searchResult.group.name,
                                        rowIndex: rowIndex,
                                        viewportSize: viewportSize)
                    }
                    .id(expandedPanelID(for: searchResult.group.name))
                }
            }
        }
    }

    private func gridCardsRow(_ row: [DisplayedProxyGroup],
                              rowIndex: Int,
                              viewportSize: CGSize,
                              activeGroupName: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(row) { result in
                GroupGridCard(
                    group: result.group,
                    groupIndex: controller.resolutionIndex,
                    canTest: controller.isRuntimeAvailable &&
                        controller.testingCurrentSelectionKeys.isEmpty,
                    currentSelectionDelay: currentSelectionDelay(for: result.group),
                    isTestingCurrentSelection: isTestingCurrentSelection(for: result.group),
                    gradientIndex: groupGradient(for: result.group.name),
                    isInteractionLocked: activeGroupName != nil &&
                        activeGroupName != result.group.name,
                    onToggle: {
                        toggleGridGroup(result.group.name,
                                        rowIndex: rowIndex,
                                        viewportSize: viewportSize)
                    },
                    onGradient: { setGradient($0, for: result.group.name) },
                    onRandomizeAll: randomizeAllGradients)
                    .frame(maxWidth: .infinity)
            }
            if gridColumnCount > 1, row.count == 1 {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .accessibilityHidden(true)
            }
        }
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
                               animated: Bool = false,
                               onToggle: @escaping () -> Void) -> some View {
        let panel = GroupExpandedPanel(
            group: result.group,
            groupIndex: controller.resolutionIndex,
            isTesting: controller.testing.contains(result.group.name),
            canTest: controller.isRuntimeAvailable &&
                controller.testingCurrentSelectionKeys.isEmpty,
            selecting: controller.selecting[result.group.name],
            testingNodes: controller.testingNodes,
            delays: controller.delays,
             gradientIndex: groupGradient(for: result.group.name),
             onToggle: onToggle,
             onTest: { Task { await controller.testGroup(result.group.name) } },
             onTestActiveNodeDelay: testActiveNodeDelay,
             onPrepareTestTarget: prepareNodeTestTarget,
            onGradient: { setGradient($0, for: result.group.name) },
            onRandomizeAll: randomizeAllGradients,
            onSelect: { name in selectNode(name, in: result.group.name) })
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ExpandedPanelFramePreferenceKey.self,
                    value: [result.group.name: geometry.frame(
                        in: .named(StrategyCoordinateSpace.name))])
            }
        }

        if animated {
            panel.transition(reduceMotion ? .identity : .opacity)
        } else {
            panel
        }
    }

    private func prepareNodeTestTarget(_ target: ProxyNodeTestTarget) {
        guard activeNodeTestTarget != target else { return }
        activeNodeTestTarget = target
    }

    private func selectNode(_ name: String, in group: String) {
        activeNodeTestTarget = nil
        Task { await controller.select(group: group, name: name) }
    }

    private func consumeNodeTestTarget() -> ProxyNodeTestTarget? {
        defer { activeNodeTestTarget = nil }
        guard let target = activeNodeTestTarget,
              let group = controller.groups.first(where: { $0.name == target.groupName }),
              group.nodes.contains(where: {
                  $0.id == target.nodeID && $0.name == target.nodeName
              }) else { return nil }
        return target
    }

    private func testActiveNodeDelay() {
        guard let target = consumeNodeTestTarget() else { return }
        Task {
            await controller.testNode(target.nodeName, in: target.groupName)
        }
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A node group contains only concrete proxy nodes; a strategy group points
    /// at one or more other groups. Empty groups stay in the strategy category
    /// until their provider members are available, avoiding category flicker.
    private var visibleGroups: [ProxyGroup] {
        let allGroupNames = controller.resolutionIndex.groupNames
        return controller.groups.filter { group in
            (showHiddenGroups || !group.hidden) &&
                groupCategory(for: group, groupNames: allGroupNames) == selectedGroupCategory
        }
    }

    /// Batch-test scope follows the cards in this tab and the hidden-group toggle.
    /// Search is presentation-only and does not silently narrow a page-wide action.
    private var currentSelectionTargets: [ProxyDelayBatchTarget] {
        var seen = Set<String>()
        return visibleGroups.compactMap { group in
            guard let target = currentSelectionTarget(for: group),
                  seen.insert(target.key).inserted else { return nil }
            return target
        }
    }

    private func currentSelectionTarget(for group: ProxyGroup) -> ProxyDelayBatchTarget? {
        guard let resolution = ProxySelectionResolver.resolve(
            group: group, index: controller.resolutionIndex) else { return nil }
        let groupNames = controller.resolutionIndex.groupNames
        guard !groupNames.contains(resolution.finalNode) else { return nil }

        let parent = resolution.path.dropLast().last.flatMap { name in
            groupNames.contains(name) ? name : nil
        } ?? group.name
        let key = ProxyDelayResolver.storageKey(
            for: group.now, index: controller.resolutionIndex)
        guard !key.isEmpty else { return nil }
        return ProxyDelayBatchTarget(key: key,
                                     node: resolution.finalNode,
                                     group: parent)
    }

    private func currentSelectionDelay(for group: ProxyGroup) -> Int? {
        ProxyDelayResolver.delay(for: group.now,
                                 index: controller.resolutionIndex,
                                 delays: controller.delays)
    }

    private func isTestingCurrentSelection(for group: ProxyGroup) -> Bool {
        guard let target = currentSelectionTarget(for: group) else { return false }
        return controller.testingCurrentSelectionKeys.contains(target.key)
    }

    private func groupCategory(for group: ProxyGroup,
                               groupNames: Set<String>) -> ProxyGroupCategory {
        if group.name.caseInsensitiveCompare("GLOBAL") == .orderedSame || group.all.isEmpty {
            return .strategy
        }
        return group.all.contains { member in
            member != group.name && groupNames.contains(member)
        } ? .strategy : .node
    }

    private var displayedGroups: [DisplayedProxyGroup] {
        let query = normalizedSearch
        guard !query.isEmpty else {
            return visibleGroups.map { group in
                let isExpanded = expanded.contains(group.name)
                return DisplayedProxyGroup(
                    group: group,
                    nodes: isExpanded ? group.nodes : [],
                    isExpanded: isExpanded)
            }
        }

        return visibleGroups.compactMap { group in
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
        let finalNode = ProxySelectionResolver.resolve(group: group,
                                                       index: controller.resolutionIndex)?.finalNode ?? ""
        return "\(group.name) \(group.now) \(finalNode) \(group.type) \(group.displayType)"
            .lowercased()
    }

    private func toggleListGroup(_ name: String) {
        guard normalizedSearch.isEmpty else { return }
        activeNodeTestTarget = nil
        withAnimation(expansionAnimation) {
            expanded = expanded.contains(name) ? [] : [name]
        }
        gridScrollRequest = nil
        geometryCache.expandedPanelFrames.removeAll()
    }

    private func resetDisplayedGroupState() {
        activeNodeTestTarget = nil
        expanded = []
        gridScrollRequest = nil
        gridExpansion = nil
        pendingGridGroupName = nil
        geometryCache.reset()
    }

    private func dismissExpandedGroup(_ name: String) {
        guard expanded.contains(name) else { return }
        activeNodeTestTarget = nil
        let restoreRequest = gridRestoreRequest(for: name)
        let closesGridExpansion = gridExpansion?.groupName == name
        withAnimation(expansionAnimation) {
            _ = expanded.remove(name)
            if closesGridExpansion {
                gridExpansion = nil
            }
            gridScrollRequest = restoreRequest
        }
        geometryCache.gridRestoreAnchors.removeValue(forKey: name)
        pendingGridGroupName = nil
        geometryCache.expandedPanelFrames.removeAll()
    }

    private func gridDismissGesture(_ activeGroupName: String?) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            guard let name = activeGroupName,
                  let frame = geometryCache.expandedPanelFrames[name],
                  !frame.contains(value.location) else { return }
            dismissExpandedGroup(name)
        }
    }

    private func listDismissGesture(_ activeGroupName: String?) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            guard let name = activeGroupName,
                  let frame = geometryCache.expandedPanelFrames[name],
                  !frame.contains(value.location) else { return }
            dismissExpandedGroup(name)
        }
    }

    private func toggleGridGroup(_ name: String,
                                 rowIndex: Int,
                                 viewportSize: CGSize) {
        activeNodeTestTarget = nil
        guard normalizedSearch.isEmpty else {
            pendingGridGroupName = name
            gridExpansion = nil
            expanded = []
            searchText = ""
            return
        }

        if gridExpansion?.groupName == name || expanded.contains(name) {
            dismissExpandedGroup(name)
            return
        }

        guard let cardFrame = geometryCache.gridCardFrames[name] else {
            pendingGridGroupName = name
            return
        }

        activateGridGroup(name,
                          rowIndex: rowIndex,
                          cardFrame: cardFrame,
                          viewportSize: viewportSize)
    }

    private func activateGridGroup(_ name: String,
                                   rowIndex: Int,
                                   cardFrame: CGRect,
                                   viewportSize: CGSize) {
        guard let group = controller.groups.first(where: { $0.name == name }) else { return }
        activeNodeTestTarget = nil
        saveGridRestoreAnchor(for: name,
                              cardFrame: cardFrame,
                              viewportHeight: viewportSize.height)
        let expansion = GridExpansionState(groupName: name,
                                           rowIndex: rowIndex,
                                           cardFrame: cardFrame,
                                           viewportSize: viewportSize,
                                           nodeCount: group.nodes.count)
        geometryCache.expandedPanelFrames.removeAll()
        pendingGridGroupName = nil
        withAnimation(expansionAnimation) {
            gridExpansion = expansion
            expanded = [name]
            gridScrollRequest = GridScrollRequest(
                targetID: expandedPanelID(for: name),
                anchor: expansion.scrollAnchor(viewportHeight: viewportSize.height))
        }
    }

    private func openPendingGridGroupIfPossible(frames: [String: CGRect],
                                                viewportSize: CGSize) {
        guard let name = pendingGridGroupName,
              normalizedSearch.isEmpty,
              let cardFrame = frames[name],
              let rowIndex = gridRowIndex(for: name) else { return }
        activateGridGroup(name,
                          rowIndex: rowIndex,
                          cardFrame: cardFrame,
                          viewportSize: viewportSize)
    }

    private func saveGridRestoreAnchor(for name: String,
                                       cardFrame: CGRect,
                                       viewportHeight: CGFloat) {
        guard viewportHeight > cardFrame.height else {
            geometryCache.gridRestoreAnchors[name] = .center
            return
        }
        let availableTravel = viewportHeight - cardFrame.height
        let relativeY = min(max(cardFrame.minY / availableTravel, 0), 1)
        geometryCache.gridRestoreAnchors[name] = UnitPoint(x: 0.5, y: relativeY)
    }

    private func gridRestoreRequest(for name: String) -> GridScrollRequest? {
        guard nodeLayout == .grid,
              let rowIndex = gridRowIndex(for: name),
              let anchor = geometryCache.gridRestoreAnchors[name] else { return nil }
        return GridScrollRequest(targetID: gridRowID(rowIndex), anchor: anchor)
    }

    private func gridRowIndex(for name: String) -> Int? {
        guard let index = displayedGroups.firstIndex(where: { $0.group.name == name }) else {
            return nil
        }
        return index / gridColumnCount
    }

    private func gridRows(_ groups: [DisplayedProxyGroup],
                          columnCount: Int) -> [[DisplayedProxyGroup]] {
        stride(from: 0, to: groups.count, by: columnCount).map { index in
            Array(groups[index..<min(index + columnCount, groups.count)])
        }
    }

    private func updateGridColumnCount(for viewportWidth: CGFloat) {
        let resolvedCount = ProxyGridLayout.columnCount(for: viewportWidth)
        guard gridColumnCount != resolvedCount else { return }
        gridColumnCount = resolvedCount
    }

    private func strategyToolbarGesture() -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard !isSearchPresented else { return }
                let vertical = value.translation.height
                let horizontal = value.translation.width
                guard abs(vertical) >= 12,
                      abs(vertical) > abs(horizontal) else { return }

                let shouldShow = vertical > 0
                guard shouldShow != toolbarControlsVisible else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    toolbarControlsVisible = shouldShow
                }
            }
    }

    private func reload() async {
        await controller.load()
        assignMissingGradients()
        synchronizeDisplayedGroups()
    }

    private func synchronizeDisplayedGroups() {
        guard expanded.allSatisfy({ name in
            visibleGroups.contains(where: { $0.name == name })
        }) else {
            resetDisplayedGroupState()
            return
        }
        if let expansion = gridExpansion {
            guard visibleGroups.contains(where: { $0.name == expansion.groupName }),
                  let index = visibleGroups.firstIndex(where: {
                $0.name == expansion.groupName
            }) else {
                gridExpansion = nil
                expanded = []
                activeNodeTestTarget = nil
                geometryCache.expandedPanelFrames.removeAll()
                return
            }
            let updatedRowIndex = index / gridColumnCount
            if updatedRowIndex != expansion.rowIndex {
                gridExpansion = nil
                expanded = []
                activeNodeTestTarget = nil
                pendingGridGroupName = expansion.groupName
                geometryCache.expandedPanelFrames.removeAll()
            }
        }
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

enum ProxyGroupCategory: String, CaseIterable, Identifiable {
    case strategy
    case node

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strategy: return "策略组"
        case .node: return "节点组"
        }
    }

    var systemImage: String {
        switch self {
        case .strategy: return "square.stack.3d.up"
        case .node: return "server.rack"
        }
    }
}

private enum ProxyNodeLayout: String {
    case list
    case grid

    var systemImage: String {
        self == .list ? "list.bullet" : "square.grid.2x2"
    }
}

/// A two-column grid is only useful while each card can preserve its title,
/// selected-node summary, and delay badge. On narrower phones the same grid
/// naturally becomes a single-column card layout instead of truncating its
/// primary information.
private enum ProxyGridLayout {
    static let horizontalInset: CGFloat = 14
    static let cardSpacing: CGFloat = 12
    static let minimumCardWidth: CGFloat = 168
    static let defaultColumnCount = 2

    static func columnCount(for viewportWidth: CGFloat) -> Int {
        let contentWidth = max(0, viewportWidth - horizontalInset * 2)
        let twoColumnWidth = minimumCardWidth * 2 + cardSpacing
        return contentWidth >= twoColumnWidth ? 2 : 1
    }

    static var expandedNodeColumns: [GridItem] {
        [GridItem(.adaptive(minimum: minimumCardWidth), spacing: cardSpacing)]
    }
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

/// Geometry preferences change continuously while a scroll view moves. Keeping
/// them in a non-observable reference avoids invalidating the whole strategy page
/// on every frame while preserving fresh coordinates for hit testing and restore.
private final class ProxyGeometryCache {
    var gridCardFrames: [String: CGRect] = [:]
    var gridRestoreAnchors: [String: UnitPoint] = [:]
    var expandedPanelFrames: [String: CGRect] = [:]

    func reset() {
        // Card frames stay valid until the next preference delivery. Retaining
        // them avoids a dead first tap when presentation state resets but the
        // visible grid geometry itself has not changed.
        gridRestoreAnchors.removeAll()
        expandedPanelFrames.removeAll()
    }
}

private struct GridExpansionState {
    enum VerticalDirection {
        case down
        case up
    }

    let groupName: String
    let rowIndex: Int
    let cardFrame: CGRect
    let verticalDirection: VerticalDirection
    let estimatedPanelHeight: CGFloat

    init(groupName: String,
         rowIndex: Int,
         cardFrame: CGRect,
         viewportSize: CGSize,
         nodeCount: Int) {
        self.groupName = groupName
        self.rowIndex = rowIndex
        self.cardFrame = cardFrame
        self.verticalDirection = cardFrame.midY <= viewportSize.height / 2
            ? .down
            : .up
        let nodeRowCount = (nodeCount + 1) / 2
        self.estimatedPanelHeight = nodeRowCount == 0
            ? 72
            : 62 + CGFloat(nodeRowCount) * 72
    }

    func scrollAnchor(viewportHeight: CGFloat) -> UnitPoint {
        let availableTravel = viewportHeight - estimatedPanelHeight
        guard availableTravel > 1 else {
            return verticalDirection == .down ? .top : .bottom
        }

        let relativeY: CGFloat
        switch verticalDirection {
        case .down:
            relativeY = cardFrame.minY / availableTravel
        case .up:
            relativeY = (cardFrame.maxY - estimatedPanelHeight) / availableTravel
        }
        return UnitPoint(x: 0.5, y: min(max(relativeY, 0), 1))
    }
}

private enum StrategyCoordinateSpace {
    static let name = "proxy-strategy-viewport"
}

private struct GridCardFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect],
                       nextValue: () -> [String: CGRect]) {
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

private struct ProxyNodeTestTarget: Hashable {
    let groupName: String
    let nodeName: String
    let nodeID: ProxyGroupNode.ID
}

private struct ProxyNodeTestTargetModifier: ViewModifier {
    private static let maximumTapDuration: TimeInterval = 0.22
    private static let maximumTapMovement: CGFloat = 10

    let onTouchBegan: () -> Void
    let onTap: () -> Void

    // Gesture callbacks can fire dozens of times during one scroll. Keep the
    // transient bookkeeping in a reference object so those updates do not
    // invalidate the row view on every pointer sample.
    @State private var tracker = ProxyTouchTracker()

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if tracker.touchStartedAt == nil {
                        tracker.touchStartedAt = value.time
                        tracker.maximumMovement = 0
                        onTouchBegan()
                    }
                    tracker.maximumMovement = max(
                        tracker.maximumMovement,
                        hypot(value.translation.width, value.translation.height))
                }
                .onEnded { value in
                    guard let startedAt = tracker.touchStartedAt else { return }
                    let duration = value.time.timeIntervalSince(startedAt)
                    let movement = max(
                        tracker.maximumMovement,
                        hypot(value.translation.width, value.translation.height))
                    let shouldTap = duration <= Self.maximumTapDuration &&
                        movement <= Self.maximumTapMovement

                    tracker.touchStartedAt = nil
                    tracker.maximumMovement = 0
                    if shouldTap { onTap() }
                }
        )
    }
}

/// Mutable gesture bookkeeping intentionally has no publisher. Mutating it
/// must not trigger a SwiftUI body pass while a finger is moving.
private final class ProxyTouchTracker {
    var touchStartedAt: Date?
    var maximumMovement: CGFloat = 0
}

private extension View {
    func proxyNodeInteraction(onTouchBegan: @escaping () -> Void,
                              onTap: @escaping () -> Void) -> some View {
        modifier(ProxyNodeTestTargetModifier(onTouchBegan: onTouchBegan,
                                             onTap: onTap))
    }
}

private struct StrategyGroupListPanel: View {
    let group: ProxyGroup
    let groupIndex: ProxyGroupIndex
    let visibleNodes: [ProxyGroupNode]
    let isExpanded: Bool
    let isInteractionLocked: Bool
    let isTesting: Bool
    let canTest: Bool
    let selecting: String?
    let testingNodes: Set<ProxyNodeTestKey>
    let delays: [String: Int]
    let currentSelectionDelay: Int?
    let isTestingCurrentSelection: Bool
    let gradientIndex: Int
    let onToggle: () -> Void
    let onTest: () -> Void
    let onTestActiveNodeDelay: () -> Void
    let onPrepareTestTarget: (ProxyNodeTestTarget) -> Void
    let onGradient: (Int) -> Void
    let onRandomizeAll: () -> Void
    let onSelect: (String) -> Void

    var body: some View {
        // Keep expanded node rows lazy as a group can contain many providers;
        // this prevents a large expansion from materializing every row at once.
        LazyVStack(spacing: 0) {
            Group {
                if isExpanded {
                    GroupExpandedHeader(group: group,
                                        groupIndex: groupIndex,
                                        isTesting: isTesting,
                                        canTest: canTest,
                                        onToggle: onToggle,
                                        onTest: onTest)
                } else {
                    GroupCompactHeader(group: group,
                                       groupIndex: groupIndex,
                                       delay: currentSelectionDelay,
                                       isTestingDelay: isTestingCurrentSelection,
                                       onToggle: onToggle)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contextMenu {
                ExternalDetectionMenu(nodeName: group.now,
                                      groupName: group.name,
                                      canTest: canTest)
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
                    ForEach(visibleNodes.indices, id: \.self) { index in
                        let item = visibleNodes[index]
                        let testTarget = ProxyNodeTestTarget(groupName: group.name,
                                                             nodeName: item.name,
                                                             nodeID: item.id)
                        ProxyNodeListRow(
                            node: item.name,
                            referencedGroup: item.name == group.name
                                ? nil
                                : groupIndex.group(named: item.name),
                            isCurrent: item.name == group.now,
                            isSelecting: selecting == item.name,
                            isSelectionBlocked: selecting != nil,
                            selectable: group.selectable,
                            isReadOnly: !canTest && !group.selectable,
                            canTest: canTest,
                            testTarget: testTarget,
                            isTestingDelay: testingNodes.contains(
                                ProxyNodeTestKey(group: group.name, node: item.name)),
                            delay: ProxyDelayResolver.delay(for: item.name,
                                                             index: groupIndex,
                                                             delays: delays),
                            onTestDelay: onTestActiveNodeDelay,
                            onPrepareTestTarget: { onPrepareTestTarget(testTarget) },
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
    let testTarget: ProxyNodeTestTarget
    let isTestingDelay: Bool
    let delay: Int?
    let onTestDelay: () -> Void
    let onPrepareTestTarget: () -> Void
    let onSelect: () -> Void

    var body: some View {
        row
            .contentShape(Rectangle())
            .accessibilityAddTraits(selectable && !isCurrent ? .isButton : [])
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .accessibilityHint(selectable && !isCurrent ? "双击切换到此节点" : "")
            .accessibilityAction { selectIfAllowed() }
            .contextMenu {
                Button(action: onTestDelay) {
                    Label(isTestingDelay ? "正在测速" : "测试此节点延迟",
                          systemImage: isTestingDelay ? "hourglass" : "speedometer")
                }
                .disabled(!canTest || isTestingDelay)
                ExternalDetectionMenu(nodeName: node,
                                      groupName: testTarget.groupName,
                                      canTest: canTest)
            }
            .proxyNodeInteraction(onTouchBegan: onPrepareTestTarget,
                                  onTap: selectIfAllowed)
            .id(testTarget)
    }

    private var canSelect: Bool {
        selectable && !isCurrent && !isSelectionBlocked
    }

    private func selectIfAllowed() {
        guard canSelect else { return }
        onSelect()
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
    let groupIndex: ProxyGroupIndex
    let canTest: Bool
    let currentSelectionDelay: Int?
    let isTestingCurrentSelection: Bool
    let gradientIndex: Int
    let isInteractionLocked: Bool
    let onToggle: () -> Void
    let onGradient: (Int) -> Void
    let onRandomizeAll: (() -> Void)?

    var body: some View {
        GroupCompactHeader(group: group,
                           groupIndex: groupIndex,
                           delay: currentSelectionDelay,
                           isTestingDelay: isTestingCurrentSelection,
                           onToggle: onToggle)
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(GroupGradient.background(for: gradientIndex))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            ExternalDetectionMenu(nodeName: group.now,
                                  groupName: group.name,
                                  canTest: canTest)
            GradientMenu(selected: gradientIndex, onSelect: onGradient,
                         onRandomizeAll: onRandomizeAll)
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: GridCardFramePreferenceKey.self,
                    value: [group.name: geometry.frame(
                        in: .named(StrategyCoordinateSpace.name))])
            }
        }
        .allowsHitTesting(!isInteractionLocked)
    }
}

private struct GroupExpandedPanel: View {
    let group: ProxyGroup
    let groupIndex: ProxyGroupIndex
    let isTesting: Bool
    let canTest: Bool
    let selecting: String?
    let testingNodes: Set<ProxyNodeTestKey>
    let delays: [String: Int]
    let gradientIndex: Int
    let onToggle: () -> Void
    let onTest: () -> Void
    let onTestActiveNodeDelay: () -> Void
    let onPrepareTestTarget: (ProxyNodeTestTarget) -> Void
    let onGradient: (Int) -> Void
    let onRandomizeAll: (() -> Void)?
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupExpandedHeader(group: group,
                                groupIndex: groupIndex,
                                isTesting: isTesting,
                                canTest: canTest,
                                onToggle: onToggle,
                                onTest: onTest)
            .contextMenu {
                ExternalDetectionMenu(nodeName: group.now,
                                      groupName: group.name,
                                      canTest: canTest)
                GradientMenu(selected: gradientIndex,
                             onSelect: onGradient,
                             onRandomizeAll: onRandomizeAll)
            }

            LazyVGrid(columns: ProxyGridLayout.expandedNodeColumns, spacing: 8) {
                ForEach(group.nodes) { item in
                    let testTarget = ProxyNodeTestTarget(groupName: group.name,
                                                         nodeName: item.name,
                                                         nodeID: item.id)
                    GroupNodeGridCell(node: item,
                                      referencedGroup: item.name == group.name
                                          ? nil
                                          : groupIndex.group(named: item.name),
                                      isCurrent: item.name == group.now,
                                      isSelecting: selecting == item.name,
                                      isSelectionBlocked: selecting != nil,
                                      selectable: group.selectable,
                                      canTest: canTest,
                                      testTarget: testTarget,
                                      isTestingDelay: testingNodes.contains(
                                          ProxyNodeTestKey(group: group.name, node: item.name)),
                                      delay: ProxyDelayResolver.delay(for: item.name,
                                                                      index: groupIndex,
                                                                      delays: delays),
                                      onTestDelay: onTestActiveNodeDelay,
                                      onPrepareTestTarget: { onPrepareTestTarget(testTarget) },
                                      onSelect: { onSelect(item.name) })
                }
            }
        }
        .padding(8)
        .background(GroupGradient.background(for: gradientIndex))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct GroupCompactHeader: View {
    let group: ProxyGroup
    let groupIndex: ProxyGroupIndex
    let delay: Int?
    let isTestingDelay: Bool
    let onToggle: () -> Void
    var compact = false

    private func immediateReference(
        for resolution: ProxySelectionResolution?
    ) -> String? {
        guard let resolution, resolution.hasDistinctFinalNode else { return nil }
        return resolution.immediateSelection
    }

    private func finalSelection(
        for resolution: ProxySelectionResolution?
    ) -> String {
        resolution?.finalNode ?? "未选择"
    }

    private func accessibilityValue(
        for resolution: ProxySelectionResolution?
    ) -> String {
        var values: [String] = []
        if let immediateReference = immediateReference(for: resolution) {
            values.append("当前分组 \(immediateReference)")
        }
        values.append("当前节点 \(finalSelection(for: resolution))")
        if !compact {
            values.append(isTestingDelay
                          ? "正在测试延迟"
                          : DelayBadge.accessibilityText(delay))
        }
        return values.joined(separator: "，")
    }

    var body: some View {
        let resolution = ProxySelectionResolver.resolve(group: group, index: groupIndex)
        Button(action: onToggle) {
            if compact {
                compactContent(resolution: resolution)
            } else {
                collapsedContent(resolution: resolution)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.name)
        .accessibilityValue(accessibilityValue(for: resolution))
    }

    private func compactContent(
        resolution: ProxySelectionResolution?
    ) -> some View {
        HStack(spacing: 9) {
            GroupIcon(url: group.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(resolution?.immediateSelection ?? "未选择")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minHeight: 17, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func collapsedContent(
        resolution: ProxySelectionResolution?
    ) -> some View {
        let immediateReference = immediateReference(for: resolution)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 9) {
                GroupIcon(url: group.icon)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(group.name)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .allowsTightening(true)
                            .minimumScaleFactor(0.72)
                        Spacer(minLength: 2)
                        GroupHeaderDelayBadge(delay: delay,
                                              isTesting: isTestingDelay)
                    }
                    if let immediateReference {
                        Text(immediateReference)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .allowsTightening(true)
                            .minimumScaleFactor(0.72)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(finalSelection(for: resolution))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsTightening(true)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct GroupHeaderDelayBadge: View {
    let delay: Int?
    let isTesting: Bool

    private var tint: Color {
        isTesting ? .secondary : DelayBadge.tint(delay)
    }

    var body: some View {
        HStack(spacing: 4) {
            if isTesting {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
            }
            Text(isTesting ? "测速" : DelayBadge.shortText(delay))
        }
        .font(.caption2.monospacedDigit().weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.10)))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
    }
}

private struct GroupExpandedHeader: View {
    let group: ProxyGroup
    let groupIndex: ProxyGroupIndex
    let isTesting: Bool
    let canTest: Bool
    let onToggle: () -> Void
    let onTest: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            GroupCompactHeader(group: group,
                               groupIndex: groupIndex,
                               delay: nil,
                               isTestingDelay: false,
                               onToggle: onToggle,
                               compact: true)
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
    let testTarget: ProxyNodeTestTarget
    let isTestingDelay: Bool
    let delay: Int?
    let onTestDelay: () -> Void
    let onPrepareTestTarget: () -> Void
    let onSelect: () -> Void

    var body: some View {
        card
            .contentShape(Rectangle())
            .accessibilityAddTraits(canSelect ? .isButton : [])
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .accessibilityHint(canSelect ? "双击切换到此节点" : "")
            .accessibilityAction { selectIfAllowed() }
            .contextMenu {
                Button(action: onTestDelay) {
                    Label(isTestingDelay ? "正在测速" : "测试此节点延迟",
                          systemImage: isTestingDelay ? "hourglass" : "speedometer")
                }
                .disabled(!canTest || isTestingDelay)
                ExternalDetectionMenu(nodeName: node.name,
                                      groupName: testTarget.groupName,
                                      canTest: canTest)
            }
            .proxyNodeInteraction(onTouchBegan: onPrepareTestTarget,
                                  onTap: selectIfAllowed)
            .id(testTarget)
    }

    private var canSelect: Bool {
        selectable && !isCurrent && !isSelectionBlocked
    }

    private func selectIfAllowed() {
        guard canSelect else { return }
        onSelect()
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

/// Context-menu entries are driven by the signed Cora script manifest. The
/// app only supplies the node/group identity; detection logic stays external.
private struct ExternalDetectionMenu: View {
    @ObservedObject private var scripts = ExternalScriptStore.shared
    let nodeName: String
    let groupName: String
    let canTest: Bool

    var body: some View {
        ForEach(orderedScripts) { script in
            Button {
                Task {
                    await UnlockTestController.shared.run(nodeName: nodeName,
                                                          groupName: groupName,
                                                          scriptID: script.id)
                }
            } label: {
                Label(script.name, systemImage: script.icon)
            }
            .disabled(!canTest || scripts.isUpdating ||
                      nodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var orderedScripts: [ExternalDetectionScript] {
        scripts.availableScripts.sorted { lhs, rhs in
            let leftRank = rank(for: lhs.id)
            let rightRank = rank(for: rhs.id)
            if leftRank == rightRank {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return leftRank < rightRank
        }
    }

    private func rank(for scriptID: String) -> Int {
        switch scriptID {
        case "network-entry-exit":
            return 0
        case "ip-quality-detection":
            return 1
        case "node-unlock-detection":
            return 2
        default:
            return 100
        }
    }
}

private struct UnlockTestOverlay: View {
    let isRunning: Bool
    let nodeName: String
    let groupName: String
    let scriptName: String
    let result: UnlockTestResult?
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isRunning, result != nil else { return }
                    onDismiss()
                }

            dialog
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityAddTraits(.isModal)
    }

    private var dialog: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isRunning {
                runningContent
            } else if let result {
                resultContent(result)
            }
        }
        .padding(20)
        .frame(maxWidth: dialogWidth)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.2), radius: 24, y: 10)
    }

    private var dialogWidth: CGFloat {
        guard let result, !isRunning else { return 360 }
        return isCompactResult(result) ? 300 : 360
    }

    private var runningContent: some View {
        VStack(spacing: 16) {
            UnlockTestRunningIndicator(reduceMotion: reduceMotion)

            VStack(spacing: 5) {
                Text("正在\(scriptName)")
                    .font(.headline)
                Text(nodeName.isEmpty ? "当前节点" : nodeName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在检测节点能力，最多需要约 45 秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在\(scriptName)节点 \(nodeName)")
    }

    private func resultContent(_ result: UnlockTestResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: result.scriptIcon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(result.nodeName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("关闭解锁测试结果")
            }

            VStack(alignment: .leading, spacing: 4) {
                if !result.groupName.isEmpty {
                    Label(result.groupName, systemImage: "square.stack.3d.up")
                }
                Label("\(result.scriptName) · \(result.scriptVersion)", systemImage: "doc.text")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Divider()

            resultMessage(result)
        }
    }

    @ViewBuilder
    private func resultMessage(_ result: UnlockTestResult) -> some View {
        if isCompactResult(result) {
            Text(result.message)
                .font(.body.weight(.medium))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                Text(result.message)
                    .font(.callout)
                    .lineSpacing(1)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        }
    }

    private func isCompactResult(_ result: UnlockTestResult) -> Bool {
        let lines = result.message
            .split(separator: "\n", omittingEmptySubsequences: false)
        return result.message.count <= 160 && lines.count <= 6
    }
}

private struct UnlockTestRunningIndicator: View {
    let reduceMotion: Bool
    @State private var isPulsing = false

    var body: some View {
        Image(systemName: "lock.shield.fill")
            .font(.system(size: 36, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 56, height: 56)
            .background(Color.accentColor.opacity(0.12), in: Circle())
            .scaleEffect(isPulsing ? 1.06 : 0.96)
            .onAppear {
                guard !reduceMotion else {
                    isPulsing = false
                    return
                }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isPulsing = true
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
                HStack(spacing: 8) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    DelayBadge(delay: delay)
                }
            } else {
                HStack(spacing: 8) {
                    Spacer(minLength: 4)
                    DelayBadge(delay: delay)
                }
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
