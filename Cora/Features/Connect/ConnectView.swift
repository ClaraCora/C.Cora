import SwiftUI
import Charts

/// 主页：连接控制 + 紧凑运行指标 + 实时流量曲线。
/// 内核状态等诊断信息移到设置页，这里只保留最常用的连接与模式。
struct ConnectView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var kernel: KernelController

    var body: some View {
        ZStack {
            AppAmbientBackground()
            NavigationStack {
                ScrollView {
                    VStack(spacing: 14) {
                        ConnectionCard()
                        if core.isActive {
                            RuntimeMetricsGrid(up: kernel.up,
                                               down: kernel.down,
                                               memoryFootprint: kernel.memoryFootprint,
                                               uptime: kernel.uptime,
                                               totalDownload: kernel.totalDownload,
                                               totalUpload: kernel.totalUpload)
                            TrafficChart(samples: kernel.samples)
                        }
                        if !core.configNotices.isEmpty {
                            NoticesCard(notices: core.configNotices)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                }
                .scrollIndicators(.hidden)
                .background(Color.clear)
                .navigationTitle("总览")
                .task { await core.refreshStatus() }
            }
        }
    }
}

/// 连接卡片：电源开关 + 状态文案 + 代理模式，集中在一张卡里。
private struct ConnectionCard: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var kernel: KernelController

    var body: some View {
        VStack(spacing: 14) {
            Button {
                Task { await core.toggleConnection() }
            } label: {
                ZStack {
                    Circle()
                        .fill(buttonGradient)
                        .frame(width: 98, height: 98)
                        .shadow(color: glowColor.opacity(0.34), radius: 10, x: 0, y: 4)
                    if core.isBusy {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(core.isBusy)

            VStack(spacing: 5) {
                ViewThatFits(in: .horizontal) {
                    statusLine
                    VStack(spacing: 4) {
                        statusIdentity
                        RuntimeInlineMetric(title: "运行",
                                            value: RuntimeMetricsGrid.duration(kernel.uptime),
                                            systemImage: "timer")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.thinMaterial))

                Text(core.isActive ? "点按断开" : "点按连接")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let err = core.lastError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            OverviewModeControl()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private var statusLine: some View {
        HStack(spacing: 7) {
            statusIdentity
            RuntimeInlineMetric(title: "运行",
                                value: RuntimeMetricsGrid.duration(kernel.uptime),
                                systemImage: "timer")
        }
    }

    private var statusIdentity: some View {
        HStack(spacing: 7) {
            RuntimeInlineMetric(title: "内存",
                                value: kernel.memoryFootprint.map(ByteFormat.size) ?? "—",
                                systemImage: "memorychip")
            Circle().fill(glowColor).frame(width: 8, height: 8)
            Text(core.statusText).font(.subheadline.weight(.semibold))
        }
    }

    private var glowColor: Color {
        switch core.status {
        case .connected:               return .green
        case .connecting, .reasserting: return .orange
        default:                        return .gray
        }
    }

    private var buttonGradient: LinearGradient {
        let c: [Color]
        switch core.status {
        case .connected:                c = [.green, .green.opacity(0.7)]
        case .connecting, .reasserting: c = [.orange, .orange.opacity(0.7)]
        default:                        c = [Color(uiColor: .systemGray3), Color(uiColor: .systemGray2)]
        }
        return LinearGradient(colors: c, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct OverviewModeControl: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var kernel: KernelController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("代理模式", systemImage: "switch.2")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Picker("代理模式", selection: Binding(
                get: { kernel.mode },
                set: { mode in Task { await kernel.setMode(mode) } }
            )) {
                ForEach(KernelController.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!core.isActive)
        }
        .padding(.top, 2)
    }
}

/// 配置提示卡片：列出被忽略的不适用内容（geo 剔除、进程规则等）。
private struct NoticesCard: View {
    let notices: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("配置提示", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(notices, id: \.self) { n in
                Text("• \(n)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
    }
}

/// 当前运行指标：固定两列，避免四项数据在窄屏上挤压。
private struct RuntimeMetricsGrid: View {
    let up: Int64
    let down: Int64
    let memoryFootprint: Int64?
    let uptime: Int64
    let totalDownload: Int64
    let totalUpload: Int64

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            MetricWidget(title: "下行", value: ByteFormat.rate(down),
                         systemImage: "arrow.down", tint: .blue)
            MetricWidget(title: "上行", value: ByteFormat.rate(up),
                         systemImage: "arrow.up", tint: .orange)
            MetricWidget(title: "累计下行", value: ByteFormat.size(totalDownload),
                         systemImage: "arrow.down.circle", tint: .blue)
            MetricWidget(title: "累计上行", value: ByteFormat.size(totalUpload),
                         systemImage: "arrow.up.circle", tint: .orange)
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

private struct RuntimeInlineMetric: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        Label("\(title) \(value)", systemImage: systemImage)
            .font(.caption2.monospacedDigit().weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct MetricWidget: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tint.opacity(0.12))
                    )
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 66)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
        .accessibilityElement(children: .combine)
    }
}

/// 图表图例：彩色圆点 + 标签。
private struct TrafficLegend: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

/// 只保留趋势信息，当前数值由上方紧凑组件显示。
private struct TrafficChart: View {
    let samples: [KernelController.TrafficSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("实时速率", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                TrafficLegend(color: .blue, title: "下行")
                TrafficLegend(color: .orange, title: "上行")
            }

            Chart {
                ForEach(samples) { s in
                    AreaMark(x: .value("t", s.id), y: .value("速率", Double(s.down)))
                        .foregroundStyle(.blue.opacity(0.1))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("t", s.id), y: .value("速率", Double(s.down)),
                             series: .value("方向", "下行"))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("t", s.id), y: .value("速率", Double(s.up)),
                             series: .value("方向", "上行"))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartXScale(domain: xDomain)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    if let v = value.as(Double.self) {
                        AxisValueLabel { Text(ByteFormat.rate(Int64(v))).font(.caption2) }
                    }
                }
            }
            .frame(height: 104)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private var xDomain: ClosedRange<Int> {
        let first = samples.first?.id ?? 0
        return first...max(samples.last?.id ?? 1, first + 1)
    }
}
