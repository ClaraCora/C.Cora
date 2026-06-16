import SwiftUI

/// 连接页：Form 风格（参考旧版 HomeView）——连接开关、实时流量、模式、当前订阅、内核状态。
struct ConnectView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @StateObject private var kernel = KernelController()

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

                if core.isActive {
                    Section("实时流量") {
                        HStack {
                            Label(ByteFormat.rate(kernel.down), systemImage: "arrow.down")
                                .foregroundStyle(.blue)
                            Spacer()
                            Label(ByteFormat.rate(kernel.up), systemImage: "arrow.up")
                                .foregroundStyle(.orange)
                        }
                        .font(.callout.monospacedDigit())
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

                Section("当前订阅") {
                    if let sub = subscriptions.selected {
                        HStack {
                            Text(sub.name)
                            Spacer()
                            if sub.hasUsage {
                                Text("剩 \(ByteFormat.size(sub.remaining))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("未选择订阅（直连兜底）").foregroundStyle(.secondary)
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
            .navigationTitle("MiClash")
            .task { await core.refreshStatus() }
            .onChange(of: core.isActive) { _, active in
                if active {
                    Task { await kernel.loadMode() }
                    kernel.startTraffic()
                } else {
                    kernel.stopTraffic()
                }
            }
            .onAppear {
                if core.isActive {
                    Task { await kernel.loadMode() }
                    kernel.startTraffic()
                }
            }
            .onDisappear { kernel.stopTraffic() }
        }
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
