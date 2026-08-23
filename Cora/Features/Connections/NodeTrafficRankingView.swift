import SwiftUI

struct NodeTrafficRankingView: View {
    @EnvironmentObject private var kernel: KernelController
    @ObservedObject var controller: ConnectionsController

    @State private var metric: ConnectionTrafficRankingMetric
    @State private var rankings: [ConnectionHistoryTrafficVolume] = []
    @State private var hasLoaded = false

    init(controller: ConnectionsController,
         initialMetric: ConnectionTrafficRankingMetric) {
        self._controller = ObservedObject(wrappedValue: controller)
        self._metric = State(initialValue: initialMetric)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label(metric.summaryTitle, systemImage: metric.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(metric.tint)
                    Text(ByteFormat.size(sessionTotal))
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .contentTransition(.numericText())

                    Picker("排行方式", selection: $metric) {
                        ForEach(ConnectionTrafficRankingMetric.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(AppListRowBackground())

            Section("流量 TOP 5") {
                if !hasLoaded {
                    HStack {
                        Spacer()
                        ProgressView("读取节点流量...")
                        Spacer()
                    }
                } else if rankings.isEmpty {
                    ContentUnavailableView("暂无节点流量",
                                           systemImage: "server.rack")
                } else {
                    ForEach(Array(rankings.enumerated()), id: \.element.name) { index, volume in
                        NavigationLink {
                            ConnectionListView(
                                title: volume.name,
                                entries: [],
                                controller: controller,
                                historyQuery: ConnectionHistoryQuery(
                                    proxyNodeName: volume.name))
                        } label: {
                            NodeTrafficRankingRow(rank: index + 1,
                                                  volume: volume,
                                                  metric: metric,
                                                  sessionTotal: sessionTotal)
                        }
                    }
                }
            }
            .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("节点流量")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: refreshKey) {
            rankings = controller.nodeTrafficRanking(metric: metric)
            hasLoaded = true
        }
    }

    private var sessionTotal: Int64 {
        switch metric {
        case .total: return kernel.totalDownload + kernel.totalUpload
        case .download: return kernel.totalDownload
        case .upload: return kernel.totalUpload
        }
    }

    private var refreshKey: NodeTrafficRefreshKey {
        NodeTrafficRefreshKey(metric: metric,
                              upload: controller.historySummary.uploadTotal,
                              download: controller.historySummary.downloadTotal)
    }
}

struct NodeTrafficTopCard: View {
    let volumes: [ConnectionHistoryTrafficVolume]
    let controller: ConnectionsController

    var body: some View {
        VStack(spacing: 0) {
            if volumes.isEmpty {
                ContentUnavailableView("暂无节点流量", systemImage: "server.rack")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                ForEach(Array(volumes.prefix(5).enumerated()), id: \.element.name) { index, volume in
                    NavigationLink {
                        ConnectionListView(
                            title: volume.name,
                            entries: [],
                            controller: controller,
                            historyQuery: ConnectionHistoryQuery(
                                proxyNodeName: volume.name))
                    } label: {
                        NodeTrafficCompactRow(rank: index + 1,
                                              volume: volume,
                                              maximum: volumes.first?.total ?? volume.total)
                    }
                    .buttonStyle(.plain)

                    if index < min(volumes.count, 5) - 1 {
                        Divider().padding(.leading, 48)
                    }
                }
            }
        }
        .padding(10)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct NodeTrafficRankingRow: View {
    let rank: Int
    let volume: ConnectionHistoryTrafficVolume
    let metric: ConnectionTrafficRankingMetric
    let sessionTotal: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                NodeTrafficRankBadge(rank: rank)
                Text(displayNodeName(volume.name))
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(ByteFormat.size(metric.value(from: volume)))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            NodeTrafficProgress(value: metric.value(from: volume),
                                maximum: max(sessionTotal, metric.value(from: volume)),
                                color: NodeTrafficPalette.color(for: rank))
                .frame(height: 7)
                .padding(.leading, 36)

            HStack(spacing: 12) {
                Label(ByteFormat.size(volume.download), systemImage: "arrow.down")
                Label(ByteFormat.size(volume.upload), systemImage: "arrow.up")
                Spacer(minLength: 0)
                Text("合计 \(ByteFormat.size(volume.total))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.leading, 36)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(rank) 名，\(displayNodeName(volume.name))，\(metric.title) \(ByteFormat.size(metric.value(from: volume)))")
    }
}

private struct NodeTrafficCompactRow: View {
    let rank: Int
    let volume: ConnectionHistoryTrafficVolume
    let maximum: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                NodeTrafficRankBadge(rank: rank)
                Text(displayNodeName(volume.name))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(ByteFormat.size(volume.total))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            NodeTrafficProgress(value: volume.total,
                                maximum: max(maximum, volume.total),
                                color: NodeTrafficPalette.color(for: rank))
                .frame(height: 6)
                .padding(.leading, 36)
            HStack(spacing: 10) {
                Label(ByteFormat.size(volume.download), systemImage: "arrow.down")
                Label(ByteFormat.size(volume.upload), systemImage: "arrow.up")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.leading, 36)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct NodeTrafficRankBadge: View {
    let rank: Int

    var body: some View {
        Text(rank.formatted())
            .font(.caption.monospacedDigit().weight(.bold))
            .foregroundStyle(.primary)
            .frame(width: 26, height: 26)
            .background(NodeTrafficPalette.color(for: rank).opacity(0.20), in: Circle())
            .overlay {
                Circle().stroke(NodeTrafficPalette.color(for: rank).opacity(0.45), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

private struct NodeTrafficProgress: View {
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
        .accessibilityHidden(true)
    }
}

private struct NodeTrafficRefreshKey: Hashable {
    let metric: ConnectionTrafficRankingMetric
    let upload: Int64
    let download: Int64
}

private enum NodeTrafficPalette {
    private static let colors: [Color] = [.cyan, .green, .yellow, .orange, .pink]

    static func color(for rank: Int) -> Color {
        colors[max(0, rank - 1) % colors.count]
    }
}

private extension ConnectionTrafficRankingMetric {
    var title: String {
        switch self {
        case .total: return "总计"
        case .download: return "下行"
        case .upload: return "上行"
        }
    }

    var summaryTitle: String {
        switch self {
        case .total: return "本次连接累计流量"
        case .download: return "本次连接累计下行"
        case .upload: return "本次连接累计上行"
        }
    }

    var systemImage: String {
        switch self {
        case .total: return "sum"
        case .download: return "arrow.down.circle"
        case .upload: return "arrow.up.circle"
        }
    }

    var tint: Color {
        switch self {
        case .total: return .purple
        case .download: return .blue
        case .upload: return .orange
        }
    }

    func value(from volume: ConnectionHistoryTrafficVolume) -> Int64 {
        switch self {
        case .total: return volume.total
        case .download: return volume.download
        case .upload: return volume.upload
        }
    }
}

private func displayNodeName(_ name: String) -> String {
    name == "DIRECT" ? "DIRECT（直连）" : name
}
