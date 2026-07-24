import SwiftUI
import Charts

/// 主页：连接控制 + 紧凑运行指标 + 实时流量曲线。
/// 内核状态等诊断信息移到设置页，这里只保留最常用的连接与模式。
struct ConnectView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var kernel: KernelController

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ConnectionCard()
                    if core.isActive {
                        RuntimeMetricsRow(up: kernel.up,
                                          down: kernel.down,
                                          memoryFootprint: kernel.memoryFootprint)
                        TrafficChart(samples: kernel.samples)
                    }
                    if !core.configNotices.isEmpty {
                        NoticesCard(notices: core.configNotices)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("MiClash")
            .task { await core.refreshStatus() }
        }
    }
}

/// 连接卡片：大圆形电源开关 + 状态文案 + 代理模式，集中在一张卡里。
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
                        .frame(width: 124, height: 124)
                        .shadow(color: glowColor.opacity(0.38), radius: 14, x: 0, y: 6)
                    if core.isBusy {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 42, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(core.isBusy)

            VStack(spacing: 4) {
                Text(core.statusText)
                    .font(.title3.weight(.semibold))
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

            Divider()

            // 代理模式
            HStack {
                Text("模式")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Picker("代理模式", selection: Binding(
                get: { kernel.mode },
                set: { m in Task { await kernel.setMode(m) } }
            )) {
                ForEach(KernelController.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!core.isActive)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }
}

/// 当前运行指标：上下行与内存各自独立，便于快速扫读。
private struct RuntimeMetricsRow: View {
    let up: Int64
    let down: Int64
    let memoryFootprint: Int64?

    var body: some View {
        HStack(spacing: 8) {
            MetricWidget(title: "下行", value: ByteFormat.rate(down),
                         systemImage: "arrow.down", tint: .blue)
            MetricWidget(title: "上行", value: ByteFormat.rate(up),
                         systemImage: "arrow.up", tint: .orange)
            MetricWidget(title: "内存",
                         value: memoryFootprint.map(ByteFormat.size) ?? "—",
                         systemImage: "memorychip", tint: .green)
        }
    }
}

private struct MetricWidget: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .accessibilityElement(children: .combine)
    }
}

/// 只保留趋势信息，当前数值由上方紧凑组件显示。
private struct TrafficChart: View {
    let samples: [KernelController.TrafficSample]

    var body: some View {
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
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private var xDomain: ClosedRange<Int> {
        let first = samples.first?.id ?? 0
        return first...max(samples.last?.id ?? 1, first + 1)
    }
}
