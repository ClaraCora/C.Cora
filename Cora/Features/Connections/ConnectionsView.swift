import SwiftUI

struct ConnectionsView: View {
    @EnvironmentObject private var core: CoreStateManager
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var controller: ConnectionsController

    var body: some View {
        Group {
            if !core.isActive {
                CoraUnavailableState("VPN 未连接", systemImage: "bolt.horizontal.circle")
            } else if controller.isLoading && controller.snapshot == nil {
                ProgressView("读取连接记录...")
            } else if let error = controller.error, controller.snapshot == nil {
                CoraUnavailableState("无法读取连接",
                                     systemImage: "exclamationmark.triangle",
                                     description: error,
                                     actionTitle: "重试") {
                    Task { await controller.refresh() }
                }
            } else {
                ConnectionOverview(controller: controller,
                                   isRefreshing: controller.isLoading,
                                   error: controller.error,
                                   onRefresh: { await controller.refresh(showLoading: false) })
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { controller.setFullSnapshotEnabled(true) }
        .onDisappear { controller.setFullSnapshotEnabled(false) }
        .onChange(of: scenePhase) { phase in
            controller.setFullSnapshotEnabled(phase == .active)
        }
    }
}

private struct ConnectionOverview: View {
    @ObservedObject var controller: ConnectionsController
    let isRefreshing: Bool
    let error: String?
    let onRefresh: () async -> Void

    private var activeCount: Int { controller.historySummary.activeCount }
    private var strategyTotals: [TrafficAggregate] {
        trafficTotals(from: controller.historySummary.strategyVolumes, role: .strategy)
    }
    private var hostTotals: [TrafficAggregate] {
        Array(trafficTotals(from: controller.historySummary.hostVolumes, role: .host).prefix(5))
    }
    private var totalTraffic: Int64 {
        controller.historySummary.uploadTotal + controller.historySummary.downloadTotal
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    NavigationLink {
                        ConnectionListView(title: "全部连接",
                                           controller: controller,
                                           historyQuery: .all)
                    } label: {
                        ConnectionCountCard(title: "全部连接",
                                            value: controller.historySummary.recordCount,
                                            symbol: "point.3.connected.trianglepath.dotted",
                                            tint: .blue)
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        ConnectionListView(title: "活跃连接",
                                           controller: controller,
                                           historyQuery: ConnectionHistoryQuery(isActive: true),
                                           initialStatus: .active)
                    } label: {
                        ConnectionCountCard(title: "活跃连接",
                                            value: activeCount,
                                            symbol: "bolt.horizontal.circle",
                                            tint: .green)
                    }
                    .buttonStyle(.plain)
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .coraGlassSurface(tint: .orange, cornerRadius: 14)
                }

                NavigationLink {
                    StrategyTrafficListView(totals: strategyTotals,
                                            controller: controller)
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeading("策略", symbol: "slider.horizontal.3")
                        StrategyTrafficCard(totals: strategyTotals, totalTraffic: totalTraffic)
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 10) {
                    sectionHeading("主机名", symbol: "network")
                    HostTrafficCard(totals: hostTotals,
                                    controller: controller,
                                    totalTraffic: totalTraffic)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .refreshable { await onRefresh() }
        .overlay(alignment: .topTrailing) {
            if isRefreshing {
                ProgressView().controlSize(.small).padding(18)
            }
        }
    }

    private func sectionHeading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.primary)
    }
}

private struct ConnectionCountCard: View {
    let title: String
    let value: Int
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(value.formatted())
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .padding(14)
        .coraGlassSurface(tint: tint)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct StrategyTrafficCard: View {
    let totals: [TrafficAggregate]
    let totalTraffic: Int64

    private var displayedTotals: [TrafficAggregate] {
        Array(totals.prefix(6))
    }
    private var displayedTraffic: Int64 {
        displayedTotals.reduce(0) { $0 + $1.total }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrafficDistributionBar(totals: displayedTotals, totalTraffic: displayedTraffic)
                .frame(height: 34)

            HStack {
                Text("策略流量分布")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.size(totalTraffic))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
            }

            FlowLegend(totals: displayedTotals)
        }
        .padding(14)
        .coraGlassSurface()
    }
}

private struct HostTrafficCard: View {
    let totals: [TrafficAggregate]
    @ObservedObject var controller: ConnectionsController
    let totalTraffic: Int64

    var body: some View {
        VStack(spacing: 0) {
            if totals.isEmpty {
                CoraUnavailableState("暂无连接记录", systemImage: "network.slash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                ForEach(Array(totals.enumerated()), id: \.element.id) { index, total in
                    NavigationLink {
                        HostTrafficDetailView(host: total.name,
                                              volume: total,
                                              controller: controller)
                    } label: {
                        HostTrafficRow(total: total, totalTraffic: totalTraffic)
                    }
                    .buttonStyle(.plain)

                    if index < totals.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
        }
        .padding(10)
        .coraGlassSurface()
    }
}

private struct HostTrafficRow: View {
    let total: TrafficAggregate
    let totalTraffic: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(total.color)
                    .frame(width: 8, height: 8)
                Text(total.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(ByteFormat.size(total.total))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            TrafficProgress(value: total.total,
                            maximum: max(totalTraffic, total.total),
                            color: total.color)
                .frame(height: 7)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

private struct StrategyTrafficListView: View {
    let totals: [TrafficAggregate]
    @ObservedObject var controller: ConnectionsController

    var body: some View {
        List(totals) { total in
            NavigationLink {
                ConnectionListView(title: total.name,
                                   entries: [],
                                   controller: controller,
                                   historyQuery: ConnectionHistoryQuery(strategyName: total.name))
            } label: {
                TrafficAggregateRow(item: total)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("策略")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HostTrafficDetailView: View {
    let host: String
    let volume: TrafficAggregate
    @ObservedObject var controller: ConnectionsController
    private let historyQuery: ConnectionHistoryQuery
    @State private var entries: [ConnectionHistoryEntry] = []
    @State private var strategyTotals: [TrafficAggregate] = []
    @State private var historyOffset = 0
    @State private var hasMoreHistory = true
    @State private var isLoadingHistory = false

    private var total: Int64 { volume.total }
    init(host: String, volume: TrafficAggregate, controller: ConnectionsController) {
        self.host = host
        self.volume = volume
        self._controller = ObservedObject(wrappedValue: controller)
        self.historyQuery = ConnectionHistoryQuery(hostName: host)
    }

    var body: some View {
        List {
            Section {
                ConnectionTrafficHeader(title: host, total: total, volume: volume)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Section("策略") {
                ForEach(strategyTotals) { item in
                    NavigationLink {
                        ConnectionListView(title: item.name,
                                           entries: [],
                                           controller: controller,
                                           historyQuery: ConnectionHistoryQuery(
                                               strategyName: item.name,
                                               hostName: host))
                    } label: {
                        TrafficAggregateRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }

            Section("连接") {
                if entries.isEmpty && isLoadingHistory {
                    ProgressView("读取连接记录...")
                        .listRowBackground(Color.clear)
                } else if entries.isEmpty {
                    CoraUnavailableState("暂无连接记录", systemImage: "network.slash")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(entries) { entry in
                        ConnectionRecordRow(entry: entry, controller: controller)
                            .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    if hasMoreHistory {
                        HStack {
                            Spacer()
                            if isLoadingHistory {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("加载更多") { loadMoreHistory() }
                            }
                            Spacer()
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("主机名")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            strategyTotals = trafficTotals(
                from: controller.historySummary(for: historyQuery).strategyVolumes,
                role: .strategy)
            loadMoreHistory(reset: true)
        }
    }

    private func loadMoreHistory(reset: Bool = false) {
        guard !isLoadingHistory else { return }
        if reset {
            entries = []
            historyOffset = 0
            hasMoreHistory = true
        }
        guard hasMoreHistory else { return }
        isLoadingHistory = true
        let page = controller.historyPage(for: historyQuery,
                                          offset: historyOffset)
        entries.append(contentsOf: page)
        historyOffset += page.count
        hasMoreHistory = page.count == ConnectionHistoryStore.defaultFetchPageSize
        isLoadingHistory = false
    }
}

private struct ConnectionTrafficHeader: View {
    let title: String
    let total: Int64
    let volume: TrafficAggregate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: 12) {
                Label(ByteFormat.size(volume.upload), systemImage: "arrow.up")
                Label(ByteFormat.size(volume.download), systemImage: "arrow.down")
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            Text("总计 \(ByteFormat.size(total))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .coraGlassSurface()
    }
}

struct ConnectionListView: View {
    let title: String
    var entries: [ConnectionHistoryEntry] = []
    @ObservedObject var controller: ConnectionsController
    var historyQuery: ConnectionHistoryQuery? = nil
    var initialStatus: ConnectionStatusFilter = .all
    var initialStrategy: String? = nil

    @State private var query = ""
    @State private var status: ConnectionStatusFilter = .all
    @State private var network: ConnectionNetworkFilter = .all
    @State private var strategy = ""
    @State private var sortOrder: ConnectionSortOrder = .newest
    @State private var loadedEntries: [ConnectionHistoryEntry] = []
    @State private var historyOffset = 0
    @State private var hasMoreQueryHistory = false
    @State private var isLoadingQueryHistory = false

    var body: some View {
        List {
            Section {
                filterBar
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)

            if filteredEntries.isEmpty && isLoadingQueryHistory {
                ProgressView("读取连接记录...")
                    .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if filteredEntries.isEmpty {
                CoraUnavailableState(query.isEmpty ? "没有匹配的连接" : "没有搜索结果",
                                     systemImage: "line.3.horizontal.decrease.circle")
                    .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(filteredEntries) { entry in
                    ConnectionRecordRow(entry: entry, controller: controller)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                if query.isEmpty, status == .all, network == .all, strategy.isEmpty,
                   canLoadMoreHistory {
                    HStack {
                        Spacer()
                        if isLoadingQueryHistory || controller.isLoadingMoreHistory {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("加载更多") { loadMoreHistory() }
                        }
                        Spacer()
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索主机、策略、节点或地址")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("排序", selection: $sortOrder) {
                        ForEach(ConnectionSortOrder.allCases) { order in
                            Label(order.title, systemImage: order.systemImage).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .onAppear {
            status = initialStatus
            strategy = initialStrategy ?? ""
        }
        .task(id: databaseQuery) {
            guard databaseQuery != nil else { return }
            loadMoreHistory(reset: true)
        }
    }

    private var sourceEntries: [ConnectionHistoryEntry] {
        historyQuery == nil ? entries : loadedEntries
    }

    private var canLoadMoreHistory: Bool {
        historyQuery == nil ? controller.hasMoreHistory : hasMoreQueryHistory
    }

    private var databaseQuery: ConnectionHistoryQuery? {
        guard let historyQuery else { return nil }
        // A detail screen may provide a base status (for example, the
        // overview's active-connections link). Keep that constraint when the
        // user leaves the status filter at "全部", while still allowing an
        // explicit filter choice to override it.
        let activeFilter = status == .all ? historyQuery.isActive : status == .active
        return ConnectionHistoryQuery(
            strategyName: strategy.isEmpty ? historyQuery.strategyName : strategy,
            hostName: historyQuery.hostName,
            network: network == .all ? nil : network.rawValue,
            isActive: activeFilter,
            searchText: query)
    }

    private func loadMoreHistory(reset: Bool = false) {
        if historyQuery == nil {
            controller.loadMoreHistory()
            return
        }
        guard let databaseQuery, !isLoadingQueryHistory else { return }
        if reset {
            loadedEntries = []
            historyOffset = 0
            hasMoreQueryHistory = true
        }
        guard hasMoreQueryHistory else { return }
        isLoadingQueryHistory = true
        let page = controller.historyPage(for: databaseQuery,
                                          offset: historyOffset)
        loadedEntries.append(contentsOf: page)
        historyOffset += page.count
        hasMoreQueryHistory = page.count == ConnectionHistoryStore.defaultFetchPageSize
        isLoadingQueryHistory = false
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                MenuFilter(title: status.title) {
                    Picker("状态", selection: $status) {
                        ForEach(ConnectionStatusFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                }
                MenuFilter(title: network.title) {
                    Picker("协议", selection: $network) {
                        ForEach(ConnectionNetworkFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                }
                MenuFilter(title: strategy.isEmpty ? "策略" : strategy) {
                    Button("全部策略") { strategy = "" }
                    ForEach(availableStrategies, id: \.self) { name in
                        Button(name) { strategy = name }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .coraGlassSurface(cornerRadius: 14)
    }

    private var availableStrategies: [String] {
        Array(Set(sourceEntries.map { $0.connection.strategyName })).sorted()
    }

    private var filteredEntries: [ConnectionHistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = sourceEntries.filter { entry in
            status.matches(entry)
                && network.matches(entry.connection)
                && (strategy.isEmpty || entry.connection.strategyName == strategy)
                && (needle.isEmpty || entry.connection.searchableText.contains(needle))
        }
        return filtered.sorted { left, right in
            switch sortOrder {
            case .newest:
                return (left.connection.startDate ?? left.endedAt ?? .distantPast)
                    > (right.connection.startDate ?? right.endedAt ?? .distantPast)
            case .download:
                return left.connection.download > right.connection.download
            case .upload:
                return left.connection.upload > right.connection.upload
            case .total:
                return left.connection.transferred > right.connection.transferred
            }
        }
    }
}

private struct MenuFilter<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule().stroke(Color.primary.opacity(0.09), lineWidth: 1)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.78)
        }
    }
}

private struct ConnectionRecordRow: View {
    let entry: ConnectionHistoryEntry
    @ObservedObject var controller: ConnectionsController
    @State private var isShowingDetail = false

    var body: some View {
        Button {
            isShowingDetail = true
        } label: {
            ConnectionRecordContent(entry: entry)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .navigationDestination(isPresented: $isShowingDetail) {
            ConnectionDetailView(entry: entry, controller: controller)
        }
    }
}

private struct ConnectionRecordContent: View {
    let entry: ConnectionHistoryEntry

    private var connection: ActiveConnection { entry.connection }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(entry.isActive ? Color.green : Color.secondary.opacity(0.55))
                    .frame(width: 8, height: 8)
                Text(connection.recordTimeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(connection.networkLabel)
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(networkTint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(networkTint.opacity(0.12), in: Capsule())
                Spacer(minLength: 4)
                Image(systemName: entry.isActive ? "lock.open" : "lock")
                    .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Text(connection.destinationAddressOrTitle)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                Text(connection.strategyName)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                Text(connection.proxyNodeName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            HStack(spacing: 10) {
                Text(connection.networkLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(networkTint)
                if !connection.durationText.isEmpty {
                    Text(connection.durationText).font(.caption).foregroundStyle(.secondary)
                }
                Label(ByteFormat.size(connection.upload), systemImage: "arrow.up")
                Label(ByteFormat.size(connection.download), systemImage: "arrow.down")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .coraListRowSurface(tint: entry.isActive ? .green : nil)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var networkTint: Color {
        switch connection.networkKey {
        case "udp": return .purple
        case "tcp": return .blue
        default: return .gray
        }
    }
}

private struct ConnectionDetailView: View {
    let entry: ConnectionHistoryEntry
    @ObservedObject var controller: ConnectionsController

    private var connection: ActiveConnection { entry.connection }
    private var isActive: Bool {
        entry.isActive
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(isActive ? Color.green : Color.secondary.opacity(0.55))
                            .frame(width: 8, height: 8)
                        Text(isActive ? "活跃连接" : "已结束")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(connection.networkLabel)
                            .font(.caption.monospaced().weight(.bold))
                            .foregroundStyle(networkTint)
                    }
                    Text(connection.destinationAddressOrTitle)
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)
                    Text(connection.recordTimeText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .coraGlassSurface(tint: isActive ? .green : nil)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Section("路由") {
                VStack(spacing: 0) {
                    ConnectionDetailValue(title: "策略组", value: connection.strategyName, systemImage: "slider.horizontal.3")
                    Divider().opacity(0.35)
                    ConnectionDetailValue(title: "出口节点", value: connection.proxyNodeName, systemImage: "point.3.connected.trianglepath.dotted")
                    if connection.chains.count > 1 {
                        Divider().opacity(0.35)
                        ConnectionDetailValue(title: "完整链路", value: connection.routeText, systemImage: "arrow.triangle.branch")
                    }
                    if !connection.ruleText.isEmpty {
                        Divider().opacity(0.35)
                        ConnectionDetailValue(title: "命中规则", value: connection.ruleText, systemImage: "list.bullet.rectangle")
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .coraGlassSurface()
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Section("连接信息") {
                VStack(spacing: 0) {
                    if !connection.sourceAddress.isEmpty {
                        ConnectionDetailValue(title: "来源", value: connection.sourceAddress, systemImage: "iphone")
                    }
                    if !connection.destinationAddress.isEmpty {
                        if !connection.sourceAddress.isEmpty { Divider().opacity(0.35) }
                        ConnectionDetailValue(title: "目标地址", value: connection.destinationAddress, systemImage: "network")
                    }
                    if !connection.metadata.process.isEmpty {
                        if !connection.sourceAddress.isEmpty || !connection.destinationAddress.isEmpty { Divider().opacity(0.35) }
                        ConnectionDetailValue(title: "进程", value: connection.metadata.process, systemImage: "app.dashed")
                    }
                    if !connection.durationText.isEmpty {
                        if !connection.sourceAddress.isEmpty || !connection.destinationAddress.isEmpty || !connection.metadata.process.isEmpty { Divider().opacity(0.35) }
                        ConnectionDetailValue(title: "持续时间", value: connection.durationText, systemImage: "clock")
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .coraGlassSurface()
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Section("流量") {
                VStack(spacing: 0) {
                    ConnectionDetailValue(title: "上行", value: ByteFormat.size(connection.upload), systemImage: "arrow.up")
                    Divider().opacity(0.35)
                    ConnectionDetailValue(title: "下行", value: ByteFormat.size(connection.download), systemImage: "arrow.down")
                    Divider().opacity(0.35)
                    ConnectionDetailValue(title: "合计", value: ByteFormat.size(connection.transferred), systemImage: "sum")
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .coraGlassSurface()
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if isActive {
                Section {
                    Button(role: .destructive) {
                        Task { await controller.close(connection) }
                    } label: {
                        HStack {
                            Label("关闭此连接", systemImage: "xmark.circle")
                            Spacer()
                            if controller.closingIDs.contains(connection.id) {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .coraGlassSurface(tint: .red)
                    }
                    .disabled(controller.closingIDs.contains(connection.id))
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("连接详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var networkTint: Color {
        switch connection.networkKey {
        case "udp": return .purple
        case "tcp": return .blue
        default: return .gray
        }
    }
}

private struct ConnectionDetailValue: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .minimumScaleFactor(0.82)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct TrafficAggregateRow: View {
    let item: TrafficAggregate

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(item.color)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    Label(ByteFormat.size(item.upload), systemImage: "arrow.up")
                    Label(ByteFormat.size(item.download), systemImage: "arrow.down")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(ByteFormat.size(item.total))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .coraListRowSurface(tint: item.color)
        .contentShape(Rectangle())
    }
}

private struct TrafficDistributionBar: View {
    let totals: [TrafficAggregate]
    let totalTraffic: Int64

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                if totals.isEmpty || totalTraffic == 0 {
                    Color.secondary.opacity(0.16)
                } else {
                    ForEach(totals) { total in
                        total.color
                            .frame(width: max(3, geometry.size.width
                                * CGFloat(Double(total.total) / Double(totalTraffic))))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct TrafficProgress: View {
    let value: Int64
    let maximum: Int64
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.14))
                Capsule().fill(color)
                    .frame(width: maximum > 0
                           ? geometry.size.width * CGFloat(Double(value) / Double(maximum))
                           : 0)
            }
        }
    }
}

private struct FlowLegend: View {
    let totals: [TrafficAggregate]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(totals.chunked(into: 3).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    ForEach(row) { item in
                        HStack(spacing: 5) {
                            Circle().fill(item.color).frame(width: 8, height: 8)
                            Text(item.name).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TrafficAggregate: Identifiable {
    let name: String
    let upload: Int64
    let download: Int64
    let color: Color

    var id: String { name }
    var total: Int64 { upload + download }
}

private func trafficTotals(for entries: [ConnectionHistoryEntry],
                           role: TrafficColor.Role = .strategy,
                           key: (ConnectionHistoryEntry) -> String) -> [TrafficAggregate] {
    var values: [String: (upload: Int64, download: Int64)] = [:]
    for entry in entries {
        let name = key(entry).isEmpty ? "未知" : key(entry)
        let current = values[name, default: (0, 0)]
        values[name] = (current.upload + entry.connection.upload,
                        current.download + entry.connection.download)
    }
    return values.map { name, value in
        TrafficAggregate(name: name,
                         upload: value.upload,
                         download: value.download,
                         color: TrafficColor.color(for: name, role: role))
    }
    .sorted { $0.total > $1.total }
}

private func trafficTotals(from volumes: [String: ConnectionTrafficVolume],
                           role: TrafficColor.Role = .strategy) -> [TrafficAggregate] {
    volumes.map { name, value in
        TrafficAggregate(name: name,
                         upload: value.upload,
                         download: value.download,
                         color: TrafficColor.color(for: name, role: role))
    }
    .sorted { left, right in
        left.total == right.total ? left.name.localizedStandardCompare(right.name) == .orderedAscending
            : left.total > right.total
    }
}

private func trafficTotals(from volumes: [ConnectionHistoryTrafficVolume],
                           role: TrafficColor.Role = .strategy) -> [TrafficAggregate] {
    volumes.map { value in
        TrafficAggregate(name: value.name,
                         upload: value.upload,
                         download: value.download,
                         color: TrafficColor.color(for: value.name, role: role))
    }
}

private enum TrafficColor {
    enum Role: Equatable {
        case strategy
        case host
    }

    private static let strategyPalette: [Color] = [.blue, .indigo, .purple, .teal, .cyan, .green]
    private static let hostPalette: [Color] = [.orange, .red, .pink, .yellow, .brown, .mint]

    static func color(for value: String, role: Role = .strategy) -> Color {
        let hash = value.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        let palette = role == .host ? hostPalette : strategyPalette
        return palette[abs(hash) % palette.count]
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { index in
            Array(self[index..<Swift.min(index + size, count)])
        }
    }
}

enum ConnectionStatusFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case ended

    var id: Self { self }
    var title: String {
        switch self {
        case .all: return "全部"
        case .active: return "活跃"
        case .ended: return "已结束"
        }
    }

    func matches(_ entry: ConnectionHistoryEntry) -> Bool {
        switch self {
        case .all: return true
        case .active: return entry.isActive
        case .ended: return !entry.isActive
        }
    }
}

private enum ConnectionNetworkFilter: String, CaseIterable, Identifiable {
    case all
    case tcp
    case udp

    var id: Self { self }
    var title: String {
        switch self {
        case .all: return "协议"
        case .tcp: return "TCP"
        case .udp: return "UDP"
        }
    }

    func matches(_ connection: ActiveConnection) -> Bool {
        self == .all || connection.networkKey == rawValue
    }
}

private enum ConnectionSortOrder: String, CaseIterable, Identifiable {
    case newest
    case download
    case upload
    case total

    var id: Self { self }
    var title: String {
        switch self {
        case .newest: return "最新"
        case .download: return "下行流量"
        case .upload: return "上行流量"
        case .total: return "总流量"
        }
    }
    var systemImage: String {
        switch self {
        case .newest: return "clock"
        case .download: return "arrow.down"
        case .upload: return "arrow.up"
        case .total: return "sum"
        }
    }
}
