import SwiftUI

/// mihomo 当前活动会话。页面可见时每秒读取一次 `/connections`。
struct ConnectionsView: View {
    @EnvironmentObject private var core: CoreStateManager
    @StateObject private var controller = ConnectionsController()
    @State private var searchText = ""
    @State private var showingCloseAllConfirmation = false

    var body: some View {
        content
            .navigationTitle("活动连接")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索目标、规则或链路")
            .toolbar {
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
            connectionList
        }
    }

    private var connectionList: some View {
        let visibleConnections = filteredConnections
        return List {
            Section {
                ConnectionSummary(snapshot: controller.snapshot ?? ConnectionsSnapshot())
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }

            if let error = controller.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .listRowBackground(Color.orange.opacity(0.08))
                }
            }

            Section {
                if visibleConnections.isEmpty {
                    if normalizedSearch.isEmpty {
                        Label("暂无活动连接", systemImage: "network.slash")
                            .foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                } else {
                    ForEach(visibleConnections) { connection in
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
                    }
                }
            } header: {
                Text("连接 · \(visibleConnections.count)")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await controller.refresh(showLoading: false) }
    }

    private var connections: [ActiveConnection] {
        controller.snapshot?.connections ?? []
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredConnections: [ActiveConnection] {
        let query = normalizedSearch
        let result = query.isEmpty
            ? connections
            : connections.filter { $0.searchableText.contains(query) }
        return result
    }
}

private struct ConnectionSummary: View {
    let snapshot: ConnectionsSnapshot

    var body: some View {
        HStack(spacing: 8) {
            SummaryValue(title: "连接", value: String(snapshot.connections.count),
                         systemImage: "link", tint: .green)
            Divider().frame(height: 30)
            SummaryValue(title: "下行", value: ByteFormat.size(snapshot.downloadTotal),
                         systemImage: "arrow.down", tint: .blue)
            Divider().frame(height: 30)
            SummaryValue(title: "上行", value: ByteFormat.size(snapshot.uploadTotal),
                         systemImage: "arrow.up", tint: .orange)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SummaryValue: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(tint.opacity(0.12))
                    )
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConnectionRow: View {
    let connection: ActiveConnection
    let isClosing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(connection.metadata.network.uppercased().isEmpty
                 ? "IP" : connection.metadata.network.uppercased())
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(connection.metadata.network.lowercased() == "udp" ? .orange : .blue)
                .frame(width: 34, height: 20)
                .background(Capsule().fill(
                    (connection.metadata.network.lowercased() == "udp" ? Color.orange : Color.blue)
                        .opacity(0.12)))

            VStack(alignment: .leading, spacing: 4) {
                Text(connection.destinationTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                if !connection.destinationAddress.isEmpty,
                   connection.destinationAddress != connection.destinationTitle {
                    Text(connection.destinationAddress)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Label(connection.routeText, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !connection.ruleText.isEmpty {
                    Text(connection.ruleText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if isClosing {
                ProgressView().controlSize(.small)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Label(ByteFormat.size(connection.download), systemImage: "arrow.down")
                        .foregroundStyle(.blue)
                    Label(ByteFormat.size(connection.upload), systemImage: "arrow.up")
                        .foregroundStyle(.orange)
                }
                .font(.caption2.monospacedDigit())
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
