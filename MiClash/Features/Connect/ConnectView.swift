import SwiftUI

/// Phase 0 的唯一界面：一个连接开关 + 状态显示。
///
/// 它只读 CoreStateManager 的状态、调它的方法，自身不持有业务逻辑——
/// 这是后续四大页面（Dashboard/Proxies/Profiles/Settings）统一遵循的 MVVM 范式雏形。
struct ConnectView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Text("MiClash")
                .font(.largeTitle.bold())

            Text(core.statusText)
                .font(.title3)
                .foregroundStyle(core.isActive ? .green : .secondary)

            // 连接按钮：圆形大开关，状态驱动颜色
            Button {
                Task { await core.toggleConnection() }
            } label: {
                ZStack {
                    Circle()
                        .fill(core.isActive ? Color.green.opacity(0.15) : Color.gray.opacity(0.12))
                        .frame(width: 160, height: 160)
                    if core.isBusy {
                        ProgressView()
                            .scaleEffect(1.4)
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 56, weight: .bold))
                            .foregroundStyle(core.isActive ? .green : .secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(core.isBusy)

            if let err = core.lastError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // 排查入口：探测 NE 内 mihomo external-controller 是否可达
            Button("内核状态") { showLog = true }
                .font(.footnote)

            Spacer()
            VStack(spacing: 2) {
                // Phase 1：显示 mihomo 内核版本，证明核心已加载
                Text(core.coreVersion)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(subscriptions.selected.map { "当前订阅：\($0.name)" } ?? "无订阅 · DIRECT 直连模式")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 8)
        }
        .task {
            // 视图出现时同步一次真实状态（冷启动场景）
            await core.refreshStatus()
        }
        .sheet(isPresented: $showLog) {
            LogView()
        }
    }
}

/// 内核状态页：探测 NE 内 mihomo external-controller 是否可达（GET /version + /proxies 计数）。
/// 这条本地 HTTP 通道取代了已失效的 sendProviderMessage IPC。
private struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = "探测中…"

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle("内核状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新") { Task { await reload() } }
                }
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

            请确认 VPN 已连接（状态「已连接」）后再探测。
            """
        }
    }
}
