import SwiftUI
import Charts

/// 连接页：Form 风格——连接开关、实时流量曲线、模式、内核状态。
struct ConnectView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var kernel: KernelController

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { core.isActive },
                        set: { _ in Task { await core.toggleConnection() } }
                    )) {
                        HStack {
                            Image(systemName: core.isActive ? "shield.fill" : "shield.slash")
                                .foregroundStyle(core.isActive ? .green : .secondary)
                            Text(core.statusText)
                        }
                    }
                    .disabled(core.isBusy)
                } footer: {
                    if let err = core.lastError {
                        Text(err).foregroundStyle(.red)
                    }
                }

                Section("模式") {
                    Picker("代理模式", selection: Binding(
                        get: { kernel.mode },
                        set: { m in Task { await kernel.setMode(m) } }
                    )) {
                        ForEach(KernelController.Mode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!core.isActive)
                }

                if core.isActive {
                    Section("实时流量") {
                        TrafficChart(samples: kernel.samples, up: kernel.up, down: kernel.down)
                    }
                }

                Section {
                    NavigationLink {
                        KernelStatusView()
                    } label: {
                        Label("内核状态", systemImage: "stethoscope")
                    }
                } footer: {
                    Text("内核：\(core.coreVersion)")
                }
            }
            .floatingTabBarInset()
            .navigationTitle("MiClash")
            .task { await core.refreshStatus() }
        }
    }
}

/// 实时流量曲线：上/下行速率折线 + 当前数值。
private struct TrafficChart: View {
    let samples: [KernelController.TrafficSample]
    let up: Int64
    let down: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Label(ByteFormat.rate(down), systemImage: "arrow.down")
                    .foregroundStyle(.blue)
                Label(ByteFormat.rate(up), systemImage: "arrow.up")
                    .foregroundStyle(.orange)
            }
            .font(.callout.monospacedDigit())

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
            .frame(height: 120)
        }
        .padding(.vertical, 4)
    }
}

/// 内核状态页：探测 external-controller 是否可达。
private struct KernelStatusView: View {
    @State private var text = "探测中…"

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle("内核状态")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("刷新") { Task { await reload() } } }
        .task { await reload() }
    }

    private func reload() async {
        text = "探测 \(MihomoAPI.base.absoluteString) …"
        do {
            let version = try await MihomoAPI.version()
            let obj = try await MihomoAPI.proxiesJSON()
            let proxies = (obj["proxies"] as? [String: Any]) ?? [:]
            let groupCount = proxies.values.compactMap { ($0 as? [String: Any])?["all"] }.count
            text = """
            ✅ external-controller 可达
            版本：\(version)
            代理/组总数：\(proxies.count)
            策略组数：\(groupCount)
            """
        } catch {
            text = """
            ❌ 连不上内核 \(MihomoAPI.base.absoluteString)
            \(error.localizedDescription)

            请确认 VPN 已连接后再探测。
            """
        }
    }
}
