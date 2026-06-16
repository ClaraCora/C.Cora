import SwiftUI

/// 连接页：连接开关 + 模式选择（规则/全局/直连）+ 实时速率。
struct ConnectView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @StateObject private var kernel = KernelController()
    @State private var showStatus = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer(minLength: 8)

                statusBadge

                toggleButton

                if core.isActive {
                    rateRow
                        .transition(.opacity)
                }

                modePicker
                    .padding(.horizontal)
                    .disabled(!core.isActive)
                    .opacity(core.isActive ? 1 : 0.4)

                if let err = core.lastError {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                footer
            }
            .padding(.top, 12)
            .navigationTitle("MiClash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("内核状态") { showStatus = true }.font(.footnote)
                }
            }
            .animation(.default, value: core.isActive)
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
            .sheet(isPresented: $showStatus) { KernelStatusView() }
        }
    }

    // MARK: - 子视图

    private var statusBadge: some View {
        Text(core.statusText)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(core.isActive ? .green : .secondary)
    }

    private var toggleButton: some View {
        Button {
            Task { await core.toggleConnection() }
        } label: {
            ZStack {
                Circle()
                    .fill(core.isActive ? Color.green.opacity(0.15) : Color.gray.opacity(0.12))
                    .frame(width: 110, height: 110)
                Circle()
                    .stroke(core.isActive ? Color.green : Color.gray.opacity(0.4), lineWidth: 2)
                    .frame(width: 110, height: 110)
                if core.isBusy {
                    ProgressView().scaleEffect(1.2)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(core.isActive ? .green : .secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(core.isBusy)
    }

    private var rateRow: some View {
        HStack(spacing: 24) {
            rateItem(icon: "arrow.down", color: .blue, value: kernel.down)
            rateItem(icon: "arrow.up", color: .orange, value: kernel.up)
        }
        .font(.callout.monospacedDigit())
    }

    private func rateItem(icon: String, color: Color, value: Int64) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text(ByteFormat.rate(value)).foregroundStyle(.primary)
        }
    }

    private var modePicker: some View {
        Picker("模式", selection: Binding(
            get: { kernel.mode },
            set: { newMode in Task { await kernel.setMode(newMode) } }
        )) {
            ForEach(KernelController.Mode.allCases) { m in
                Text(m.label).tag(m)
            }
        }
        .pickerStyle(.segmented)
    }

    private var footer: some View {
        VStack(spacing: 2) {
            Text(core.coreVersion)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(subscriptions.selected.map { "当前订阅：\($0.name)" } ?? "无订阅 · DIRECT 直连")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 8)
    }
}

/// 内核状态页：探测 external-controller 是否可达（GET /version + /proxies 计数）。
private struct KernelStatusView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = "探测中…"

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle("内核状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("刷新") { Task { await reload() } } }
            }
            .task { await reload() }
        }
    }

    private func reload() async {
        text = "探测 http://127.0.0.1:9090 …"
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
            ❌ 连不上内核 http://127.0.0.1:9090
            \(error.localizedDescription)

            请确认 VPN 已连接后再探测。
            """
        }
    }
}
