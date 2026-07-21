import SwiftUI
import Charts

/// 连接页：一张「连接卡片」（大圆形开关 + 状态 + 模式三合一）+ 实时流量卡片。
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
                        TrafficCard(samples: kernel.samples,
                                    up: kernel.up,
                                    down: kernel.down,
                                    memory: kernel.memory,
                                    connectionCount: kernel.connectionCount,
                                    uploadTotal: kernel.uploadTotal,
                                    downloadTotal: kernel.downloadTotal)
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
        VStack(spacing: 20) {
            // 大圆形电源按钮
            Button {
                Task { await core.toggleConnection() }
            } label: {
                ZStack {
                    Circle()
                        .fill(buttonGradient)
                        .frame(width: 150, height: 150)
                        .shadow(color: glowColor.opacity(0.45), radius: 20, x: 0, y: 8)
                    if core.isBusy {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 52, weight: .bold))
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
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
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
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }
}

/// 实时流量卡片：上/下行速率折线 + 当前数值。
private struct TrafficCard: View {
    let samples: [KernelController.TrafficSample]
    let up: Int64
    let down: Int64
    let memory: UInt64
    let connectionCount: Int
    let uploadTotal: Int64
    let downloadTotal: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Label(ByteFormat.rate(down), systemImage: "arrow.down")
                    .foregroundStyle(.blue)
                Label(ByteFormat.rate(up), systemImage: "arrow.up")
                    .foregroundStyle(.orange)
                Spacer()
            }
            .font(.callout.monospacedDigit().weight(.medium))

            HStack(spacing: 14) {
                Label(ByteFormat.size(Int64(memory)), systemImage: "memorychip")
                Label("\(connectionCount)", systemImage: "link")
                Label(ByteFormat.size(downloadTotal + uploadTotal), systemImage: "sum")
                Spacer()
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            Chart {
                ForEach(Array(samples.enumerated()), id: \.element.id) { idx, s in
                    AreaMark(x: .value("t", idx), y: .value("速率", Double(s.down)))
                        .foregroundStyle(.blue.opacity(0.12))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("t", idx), y: .value("速率", Double(s.down)),
                             series: .value("方向", "下行"))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("t", idx), y: .value("速率", Double(s.up)),
                             series: .value("方向", "上行"))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartXScale(domain: 0...Double(max(samples.count - 1, 1)))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    if let v = value.as(Double.self) {
                        AxisValueLabel { Text(ByteFormat.rate(Int64(v))).font(.caption2) }
                    }
                }
            }
            .frame(height: 140)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }
}
