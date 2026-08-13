import SwiftUI

struct ConnectionsView: View {
    @EnvironmentObject private var core: CoreStateManager
    @ObservedObject var controller: ConnectionsController

    var body: some View {
        Group {
            if !core.isActive {
                ContentUnavailableView("VPN 未连接", systemImage: "bolt.horizontal.circle")
            } else if controller.isLoading && controller.snapshot == nil {
                ProgressView("读取连接记录...")
            } else if let error = controller.error, controller.snapshot == nil {
                ContentUnavailableView {
                    Label("无法读取连接", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { Task { await controller.refresh() } }
                }
            } else {
                ConnectionOverview(controller: controller,
                                   history: controller.history,
                                   isRefreshing: controller.isLoading,
                                   error: controller.error,
                                   onRefresh: { await controller.refresh(showLoading: false) })
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ConnectionOverview: View {
    @ObservedObject var controller: ConnectionsController
    let history: [ConnectionHistoryEntry]
    let isRefreshing: Bool
    let error: String?
    let onRefresh: () async -> Void

    private var activeCount: Int { controller.sessionSummary.activeConnectionCount }
    private var strategyTotals: [TrafficAggregate] {
        trafficTotals(from: controller.sessionSummary.strategyVolumes)
    }
    private var hostTotals: [TrafficAggregate] {
        Array(trafficTotals(from: controller.sessionSummary.hostVolumes).prefix(5))
    }
    private var totalTraffic: Int64 {
        controller.sessionSummary.totalTraffic
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    NavigationLink {
                        ConnectionListView(title: "全部连接",
                                           entries: history,
                                           controller: controller,
                                           showsSessionLimitNote: true)
                    } label: {
                        ConnectionCountCard(title: "全部连接",
                                            value: controller.sessionSummary.totalConnectionCount,
                                            symbol: "point.3.connected.trianglepath.dotted",
                                            tint: .blue)
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        ConnectionListView(title: "活跃连接",
                                           entries: history.filter(\.isActive),
                                           controller: controller,
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
                        .background(Color.orange.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                NavigationLink {
                    StrategyTrafficListView(entries: history,
                                            totals: strategyTotals,
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
                                    allEntries: history,
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
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
    }
}

private struct ConnectionCountCard: View {
    let title: String
    let value: Int
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(value.formatted())
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .padding(16)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        .padding(16)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct HostTrafficCard: View {
    let totals: [TrafficAggregate]
    let allEntries: [ConnectionHistoryEntry]
    @ObservedObject var controller: ConnectionsController
    let totalTraffic: Int64

    var body: some View {
        VStack(spacing: 0) {
            if totals.isEmpty {
                ContentUnavailableView("暂无连接记录", systemImage: "network.slash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                ForEach(Array(totals.enumerated()), id: \.element.id) { index, total in
                    NavigationLink {
                        HostTrafficDetailView(host: total.name,
                                              entries: allEntries.filter {
                                                  $0.connection.destinationTitle == total.name
                                              },
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
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct HostTrafficRow: View {
    let total: TrafficAggregate
    let totalTraffic: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(total.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(ByteFormat.size(total.total))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
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
    let entries: [ConnectionHistoryEntry]
    let totals: [TrafficAggregate]
    @ObservedObject var controller: ConnectionsController

    var body: some View {
        List(totals) { total in
            NavigationLink {
                ConnectionListView(title: total.name,
                                   entries: entries.filter { $0.connection.strategyName == total.name },
                                   controller: controller,
                                   initialStrategy: total.name)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(total.name)
                        Spacer()
                        Text(ByteFormat.size(total.total))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Label(ByteFormat.size(total.upload), systemImage: "arrow.up")
                        Label(ByteFormat.size(total.download), systemImage: "arrow.down")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("策略")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HostTrafficDetailView: View {
    let host: String
    let entries: [ConnectionHistoryEntry]
    let volume: TrafficAggregate
    @ObservedObject var controller: ConnectionsController

    private var total: Int64 { volume.total }
    private var strategyTotals: [TrafficAggregate] {
        trafficTotals(for: entries) { $0.connection.strategyName }
    }

    var body: some View {
        List {
            Section {
                ConnectionTrafficHeader(title: host, total: total, volume: volume)
            }
            .listRowBackground(AppListRowBackground())

            Section("策略") {
                ForEach(strategyTotals) { item in
                    NavigationLink {
                        ConnectionListView(title: item.name,
                                           entries: entries.filter { $0.connection.strategyName == item.name },
                                           controller: controller,
                                           initialStrategy: item.name)
                    } label: {
                        TrafficAggregateRow(item: item)
                    }
                }
            }
            .listRowBackground(AppListRowBackground())

            Section("连接") {
                ForEach(entries) { entry in
                    ConnectionRecordRow(entry: entry, controller: controller)
                }
            }
            .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("主机名")
        .navigationBarTitleDisplayMode(.inline)
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
        .padding(.vertical, 4)
    }
}

private struct ConnectionListView: View {
    let title: String
    let entries: [ConnectionHistoryEntry]
    @ObservedObject var controller: ConnectionsController
    var initialStatus: ConnectionStatusFilter = .all
    var initialStrategy: String? = nil
    var showsSessionLimitNote = false

    @State private var query = ""
    @State private var status: ConnectionStatusFilter = .all
    @State private var network: ConnectionNetworkFilter = .all
    @State private var strategy = ""
    @State private var sortOrder: ConnectionSortOrder = .newest

    var body: some View {
        List {
            Section {
                filterBar
            } footer: {
                if showsSessionLimitNote {
                    Text("记录会跨 App 重启保留；已结束连接最多保留最近 120 条。")
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)

            if filteredEntries.isEmpty {
                ContentUnavailableView(query.isEmpty ? "没有匹配的连接" : "没有搜索结果",
                                       systemImage: "line.3.horizontal.decrease.circle")
                    .listRowBackground(Color.clear)
            } else {
                ForEach(filteredEntries) { entry in
                    ConnectionRecordRow(entry: entry, controller: controller)
                        .listRowBackground(AppListRowBackground())
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索主机、策略或地址")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
            .padding(.horizontal, 16)
        }
    }

    private var availableStrategies: [String] {
        Array(Set(entries.map { $0.connection.strategyName })).sorted()
    }

    private var filteredEntries: [ConnectionHistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = entries.filter { entry in
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
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
        }
    }
}

private struct ConnectionRecordRow: View {
    let entry: ConnectionHistoryEntry
    @ObservedObject var controller: ConnectionsController

    var body: some View {
        NavigationLink {
            ConnectionDetailView(entry: entry, controller: controller)
        } label: {
            ConnectionRecordContent(entry: entry)
        }
        .buttonStyle(.plain)
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
        .padding(.vertical, 6)
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
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(connection.recordTimeText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(AppListRowBackground())

            Section("路由") {
                ConnectionDetailValue(title: "策略组",
                                      value: connection.strategyName,
                                      systemImage: "slider.horizontal.3")
                ConnectionDetailValue(title: "出口节点",
                                      value: connection.proxyNodeName,
                                      systemImage: "point.3.connected.trianglepath.dotted")
                if connection.chains.count > 1 {
                    ConnectionDetailValue(title: "完整链路",
                                          value: connection.routeText,
                                          systemImage: "arrow.triangle.branch")
                }
                if !connection.ruleText.isEmpty {
                    ConnectionDetailValue(title: "命中规则",
                                          value: connection.ruleText,
                                          systemImage: "list.bullet.rectangle")
                }
            }
            .listRowBackground(AppListRowBackground())

            Section("连接信息") {
                if !connection.sourceAddress.isEmpty {
                    ConnectionDetailValue(title: "来源", value: connection.sourceAddress,
                                          systemImage: "iphone")
                }
                if !connection.destinationAddress.isEmpty {
                    ConnectionDetailValue(title: "目标地址", value: connection.destinationAddress,
                                          systemImage: "network")
                }
                if !connection.metadata.process.isEmpty {
                    ConnectionDetailValue(title: "进程", value: connection.metadata.process,
                                          systemImage: "app.dashed")
                }
                if !connection.durationText.isEmpty {
                    ConnectionDetailValue(title: "持续时间", value: connection.durationText,
                                          systemImage: "clock")
                }
            }
            .listRowBackground(AppListRowBackground())

            Section("流量") {
                ConnectionDetailValue(title: "上行", value: ByteFormat.size(connection.upload),
                                      systemImage: "arrow.up")
                ConnectionDetailValue(title: "下行", value: ByteFormat.size(connection.download),
                                      systemImage: "arrow.down")
                ConnectionDetailValue(title: "合计", value: ByteFormat.size(connection.transferred),
                                      systemImage: "sum")
            }
            .listRowBackground(AppListRowBackground())

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
                    }
                    .disabled(controller.closingIDs.contains(connection.id))
                }
                .listRowBackground(AppListRowBackground())
            }
        }
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
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

private struct TrafficAggregateRow: View {
    let item: TrafficAggregate

    var body: some View {
        HStack {
            Circle().fill(item.color).frame(width: 9, height: 9)
            Text(item.name)
            Spacer()
            Text(ByteFormat.size(item.total))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
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
                         color: TrafficColor.color(for: name))
    }
    .sorted { $0.total > $1.total }
}

private func trafficTotals(from volumes: [String: ConnectionTrafficVolume]) -> [TrafficAggregate] {
    volumes.map { name, value in
        TrafficAggregate(name: name,
                         upload: value.upload,
                         download: value.download,
                         color: TrafficColor.color(for: name))
    }
    .sorted { left, right in
        left.total == right.total ? left.name.localizedStandardCompare(right.name) == .orderedAscending
            : left.total > right.total
    }
}

private enum TrafficColor {
    private static let palette: [Color] = [.blue, .green, .orange, .purple, .red, .cyan, .pink, .teal]

    static func color(for value: String) -> Color {
        let hash = value.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
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

private enum ConnectionStatusFilter: String, CaseIterable, Identifiable {
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
