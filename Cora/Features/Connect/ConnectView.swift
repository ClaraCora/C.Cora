import SwiftUI
import Charts

/// 总览：以连接控制为中心，运行状态与流量指标围绕主操作展开。
struct ConnectView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var kernel: KernelController
    @ObservedObject var connections: ConnectionsController

    var body: some View {
        NavigationStack {
            ZStack {
                AppAmbientBackground()

                ScrollView {
                    VStack(spacing: 18) {
                        ConnectionHero()

                        if core.isActive {
                            RuntimeMetricsGrid(up: kernel.up,
                                               down: kernel.down,
                                               totalDownload: kernel.totalDownload,
                                               totalUpload: kernel.totalUpload,
                                               samples: kernel.samples,
                                               connections: connections)
                        }

                        OverviewConnectionLinks(controller: connections)

                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 28)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .background(Color.clear)
            }
            .navigationBarTitleDisplayMode(.inline)
            .task { await core.refreshStatus() }
        }
    }
}

private struct OverviewConnectionLinks: View {
    @ObservedObject var controller: ConnectionsController

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ], spacing: 10) {
            NavigationLink {
                ConnectionListView(title: "全部连接",
                                   entries: controller.history,
                                   controller: controller,
                                   showsRetentionNote: true)
            } label: {
                OverviewConnectionCard(title: "全部连接",
                                        value: controller.historySummary.recordCount,
                                        symbol: "point.3.connected.trianglepath.dotted",
                                        tint: .blue)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ConnectionListView(title: "活跃连接",
                                   entries: controller.history.filter(\.isActive),
                                   controller: controller,
                                   initialStatus: .active)
            } label: {
                OverviewConnectionCard(title: "活跃连接",
                                        value: controller.historySummary.activeCount,
                                        symbol: "bolt.horizontal.circle",
                                        tint: .green)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct OverviewConnectionCard: View {
    let title: String
    let value: Int
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value.formatted())
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .padding(14)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct ConnectionHero: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var kernel: KernelController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ripple = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 5) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(core.statusText)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.secondary)

                Text(RuntimeMetricsGrid.duration(kernel.uptime))
                    .font(.system(size: 34, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .accessibilityLabel("运行时间 \(RuntimeMetricsGrid.duration(kernel.uptime))")
            }

            Button {
                Task { await core.toggleConnection() }
            } label: {
                ZStack {
                    if core.status == .connected && !reduceMotion {
                        rippleRings
                    }

                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 142, height: 142)
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(0.46), lineWidth: 1)
                        }
                        .shadow(color: statusColor.opacity(0.26), radius: 22, x: 0, y: 12)

                    Circle()
                        .fill(buttonGradient)
                        .frame(width: 104, height: 104)
                        .overlay {
                            Circle().stroke(Color.white.opacity(0.52), lineWidth: 1)
                        }

                    if core.isBusy {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 39, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 196, height: 196)
                .contentShape(Circle())
            }
            .buttonStyle(PowerButtonStyle())
            .disabled(core.isBusy)
            .accessibilityLabel(core.isActive ? "断开 VPN" : "连接 VPN")

            VStack(spacing: 10) {
                Label(kernel.memoryFootprint.map(ByteFormat.size) ?? "—",
                      systemImage: "memorychip")
                    .font(.footnote.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(Capsule().fill(.thinMaterial))
                    .accessibilityLabel("内存 \(kernel.memoryFootprint.map(ByteFormat.size) ?? "未知")")

                OverviewModeMenu()
            }

            if let error = core.lastError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .onAppear { updateRipple() }
        .onChange(of: core.status) { _, _ in updateRipple() }
        .onChange(of: reduceMotion) { _, _ in updateRipple() }
    }

    private var rippleRings: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(statusColor.opacity(0.34), lineWidth: 1.5)
                    .frame(width: 150, height: 150)
                    .scaleEffect(ripple ? 1.28 : 0.72)
                    .opacity(ripple ? 0 : 0.72)
                    .animation(
                        .easeOut(duration: 2.4)
                            .repeatForever(autoreverses: false)
                            .delay(Double(index) * 0.56),
                        value: ripple
                    )
            }
        }
    }

    private var statusColor: Color {
        switch core.status {
        case .connected: return .cyan
        case .connecting, .reasserting: return .orange
        default: return .secondary
        }
    }

    private var buttonGradient: LinearGradient {
        let colors: [Color]
        switch core.status {
        case .connected:
            colors = [.cyan, .blue]
        case .connecting, .reasserting:
            colors = [.orange, .pink]
        default:
            colors = [Color(uiColor: .systemGray2), Color(uiColor: .systemGray3)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func updateRipple() {
        guard core.status == .connected, !reduceMotion else {
            ripple = false
            return
        }
        ripple = false
        DispatchQueue.main.async { ripple = true }
    }
}

private struct PowerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct OverviewModeMenu: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var kernel: KernelController

    var body: some View {
        Menu {
            ForEach(KernelController.Mode.allCases) { mode in
                Button {
                    Task { await kernel.setMode(mode) }
                } label: {
                    Label(mode.menuLabel,
                          systemImage: mode == kernel.mode ? "checkmark.circle.fill" : mode.systemImage)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                Text("出站模式 · \(kernel.mode.menuLabel)")
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(core.isActive ? Color.primary : Color.secondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Capsule().fill(.regularMaterial))
            .contentShape(Capsule())
        }
        .disabled(!core.isActive)
        .accessibilityLabel("出站模式，当前为 \(kernel.mode.menuLabel)")
    }
}

private extension KernelController.Mode {
    var menuLabel: String {
        switch self {
        case .rule: return "规则模式"
        case .global: return "全局模式"
        case .direct: return "直连模式"
        }
    }

    var systemImage: String {
        switch self {
        case .rule: return "list.bullet.rectangle"
        case .global: return "globe"
        case .direct: return "arrow.up.forward"
        }
    }
}

private struct RuntimeMetricsGrid: View {
    let up: Int64
    let down: Int64
    let totalDownload: Int64
    let totalUpload: Int64
    let samples: [KernelController.TrafficSample]
    let connections: ConnectionsController

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ], spacing: 10) {
            RateMetricWidget(title: "下行", value: ByteFormat.rate(down),
                             systemImage: "arrow.down", tint: .blue,
                             samples: samples, direction: .down)
            RateMetricWidget(title: "上行", value: ByteFormat.rate(up),
                             systemImage: "arrow.up", tint: .orange,
                             samples: samples, direction: .up)
            NavigationLink {
                NodeTrafficRankingView(controller: connections,
                                       initialMetric: .download)
            } label: {
                MetricWidget(title: "累计下行", value: ByteFormat.size(totalDownload),
                             systemImage: "arrow.down.circle", tint: .blue)
            }
            .buttonStyle(.plain)
            .accessibilityHint("查看节点下行流量排行")

            NavigationLink {
                NodeTrafficRankingView(controller: connections,
                                       initialMetric: .upload)
            } label: {
                MetricWidget(title: "累计上行", value: ByteFormat.size(totalUpload),
                             systemImage: "arrow.up.circle", tint: .orange)
            }
            .buttonStyle(.plain)
            .accessibilityHint("查看节点上行流量排行")
        }
    }

    static func duration(_ seconds: Int64) -> String {
        let value = max(0, seconds)
        let days = value / 86_400
        let hours = (value % 86_400) / 3_600
        let minutes = (value % 3_600) / 60
        let remainingSeconds = value % 60
        let clock = String(format: "%02lld:%02lld:%02lld", hours, minutes, remainingSeconds)
        return days > 0 ? "\(days)天 \(clock)" : clock
    }
}

private enum TrafficDirection {
    case up
    case down
}

private struct RateMetricWidget: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color
    let samples: [KernelController.TrafficSample]
    let direction: TrafficDirection

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            metricHeader
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.64)
            miniChart
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .background(metricSurface)
        .accessibilityElement(children: .combine)
    }

    private var metricHeader: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
    }

    private var miniChart: some View {
        Chart {
            ForEach(samples) { sample in
                AreaMark(x: .value("时间", sample.id),
                         y: .value("速率", value(for: sample)))
                    .foregroundStyle(tint.opacity(0.13))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("时间", sample.id),
                         y: .value("速率", value(for: sample)))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...upperBound)
        .frame(height: 34)
        .accessibilityHidden(true)
    }

    private var metricSurface: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.regularMaterial)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(tint.opacity(0.72))
                    .frame(height: 2)
                    .clipShape(Capsule())
                    .padding(.horizontal, 12)
            }
    }

    private func value(for sample: KernelController.TrafficSample) -> Double {
        Double(direction == .up ? sample.up : sample.down)
    }

    private var xDomain: ClosedRange<Int> {
        let first = samples.first?.id ?? 0
        return first...max(samples.last?.id ?? 1, first + 1)
    }

    private var upperBound: Double {
        max(samples.map { value(for: $0) }.max() ?? 0, 1)
    }
}

private struct MetricWidget: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .foregroundStyle(.primary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
