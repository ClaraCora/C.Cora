import SwiftUI

/// mihomo 当前活动会话。页面可见时每秒读取一次 `/connections`。
struct ConnectionsView: View {
    @EnvironmentObject private var core: CoreStateManager
    @StateObject private var controller = ConnectionsController()
    @State private var searchText = ""
    @State private var networkFilter: ConnectionNetworkFilter = .all
    @State private var sortOrder: ConnectionSortOrder = .newest
    @State private var showingCloseAllConfirmation = false

    var body: some View {
        content
            .navigationTitle("活动连接")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索目标、地址、规则或链路")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    sortMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCloseAllConfirmation = true
                    } label: {
                        if controller.isClosingAll {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "xmark.circle")
                        }
                    }
                    .disabled(connections.isEmpty || controller.isClosingAll)
                    .accessibilityLabel("关闭全部连接")
                    .help("关闭全部连接")
                }
            }
            .confirmationDialog("关闭全部活动连接？",
                                isPresented: $showingCloseAllConfirmation,
                                titleVisibility: .visible) {
                Button("关闭全部", role: .destructive) {
                    Task { await controller.closeAll() }
                }
                Button("取消", role: .cancel) {}
            }
            .task(id: core.isActive) {
                guard core.isActive else {
                    controller.reset()
                    return
                }
                await controller.poll()
            }
    }

    @ViewBuilder private var content: some View {
        if !core.isActive {
            ContentUnavailableView("VPN 未连接",
                systemImage: "bolt.horizontal.circle")
        } else if controller.isLoading && controller.snapshot == nil {
            ProgressView("读取活动连接…")
        } else if let error = controller.error, controller.snapshot == nil {
            ContentUnavailableView {
                Label("无法读取连接", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { Task { await controller.refresh() } }
            }
        } else {
            connectionWorkspace
        }
    }

    private var connectionWorkspace: some View {
        let visibleConnections = filteredConnections
        let allConnections = connections

        return VStack(spacing: 0) {
            ConnectionSummary(snapshot: controller.snapshot ?? ConnectionsSnapshot())
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemBackground))

            Divider()

            HStack(spacing: 12) {
                Picker("协议", selection: $networkFilter) {
                    ForEach(ConnectionNetworkFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                Text("\(visibleConnections.count) / \(allConnections.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(uiColor: .systemBackground))

            Divider()

            if let error = controller.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.08))
            }

            if visibleConnections.isEmpty {
                if normalizedSearch.isEmpty && networkFilter == .all {
                    ContentUnavailableView("暂无活动连接", systemImage: "network.slash")
                } else if !normalizedSearch.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ContentUnavailableView("没有 \(networkFilter.title) 连接",
                                           systemImage: "line.3.horizontal.decrease.circle")
                }
            } else {
                List(visibleConnections) { connection in
                    ConnectionRow(
                        connection: connection,
                        isClosing: controller.closingIDs.contains(connection.id))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await controller.close(connection) }
                            } label: {
                                Label("关闭", systemImage: "xmark")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 9, leading: 16,
                                                  bottom: 9, trailing: 16))
                }
                .listStyle(.plain)
                .refreshable { await controller.refresh(showLoading: false) }
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $sortOrder) {
                ForEach(ConnectionSortOrder.allCases) { order in
                    Label(order.title, systemImage: order.systemImage)
                        .tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .disabled(connections.isEmpty)
        .accessibilityLabel("连接排序：\(sortOrder.title)")
        .help("连接排序")
    }

    private var connections: [ActiveConnection] {
        controller.snapshot?.connections ?? []
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredConnections: [ActiveConnection] {
        let query = normalizedSearch
        let filtered = connections.filter { connection in
            networkFilter.matches(connection)
                && (query.isEmpty || connection.searchableText.contains(query))
        }
        if sortOrder == .newest { return filtered }
        return filtered.sorted { lhs, rhs in
            switch sortOrder {
            case .newest:
                return (lhs.startDate ?? .distantPast) > (rhs.startDate ?? .distantPast)
            case .download:
                return ordered(lhs.download, before: rhs.download, lhs: lhs, rhs: rhs)
            case .upload:
                return ordered(lhs.upload, before: rhs.upload, lhs: lhs, rhs: rhs)
            case .total:
                return ordered(lhs.transferred, before: rhs.transferred, lhs: lhs, rhs: rhs)
            }
        }
    }

    private func ordered(_ left: Int64, before right: Int64,
                         lhs: ActiveConnection, rhs: ActiveConnection) -> Bool {
        if left == right {
            return (lhs.startDate ?? .distantPast) > (rhs.startDate ?? .distantPast)
        }
        return left > right
    }
}

private enum ConnectionNetworkFilter: String, CaseIterable, Identifiable {
    case all
    case tcp
    case udp

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部"
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
        case .newest: return "最新建立"
        case .download: return "下载流量"
        case .upload: return "上传流量"
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

private struct ConnectionSummary: View {
    let snapshot: ConnectionsSnapshot

    var body: some View {
        HStack(spacing: 8) {
            SummaryValue(title: "活动", value: String(snapshot.connections.count),
                         detail: "TCP \(snapshot.tcpCount) · UDP \(snapshot.udpCount)",
                         systemImage: "link", tint: .green)
            Divider().frame(height: 42)
            SummaryValue(title: "下行", value: ByteFormat.size(snapshot.downloadTotal),
                         detail: "累计", systemImage: "arrow.down", tint: .blue)
            Divider().frame(height: 42)
            SummaryValue(title: "上行", value: ByteFormat.size(snapshot.uploadTotal),
                         detail: "累计", systemImage: "arrow.up", tint: .orange)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SummaryValue: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConnectionRow: View {
    let connection: ActiveConnection
    let isClosing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(connection.networkLabel)
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(networkTint)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(Capsule().fill(networkTint.opacity(0.12)))

                Text(connection.destinationTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if isClosing {
                    ProgressView().controlSize(.small)
                } else if !connection.durationText.isEmpty {
                    Label(connection.durationText, systemImage: "clock")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !connection.endpointText.isEmpty {
                Text(connection.endpointText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Label(connection.routeText,
                  systemImage: "point.3.connected.trianglepath.dotted")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if !connection.ruleText.isEmpty {
                    Label(connection.ruleText, systemImage: "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    Label(ByteFormat.size(connection.download), systemImage: "arrow.down")
                        .foregroundStyle(.blue)
                    Label(ByteFormat.size(connection.upload), systemImage: "arrow.up")
                        .foregroundStyle(.orange)
                }
                .font(.caption2.monospacedDigit())
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var networkTint: Color {
        switch connection.networkKey {
        case "udp": return .orange
        case "tcp": return .blue
        default: return .gray
        }
    }
}
