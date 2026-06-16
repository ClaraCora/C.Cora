import SwiftUI

/// Phase 0 的唯一界面：一个连接开关 + 状态显示。
///
/// 它只读 CoreStateManager 的状态、调它的方法，自身不持有业务逻辑——
/// 这是后续四大页面（Dashboard/Proxies/Profiles/Settings）统一遵循的 MVVM 范式雏形。
struct ConnectView: View {
    @EnvironmentObject private var core: CoreStateManager
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

            // 排查入口：读取 NE/mihomo 落盘日志，定位 tun 启动失败在哪一步
            Button("查看日志") { showLog = true }
                .font(.footnote)

            Spacer()
            VStack(spacing: 2) {
                // Phase 1：显示 mihomo 内核版本，证明核心已加载
                Text(core.coreVersion)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("Phase 2 · DIRECT 模式 tun 接管流量")
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
            LogView().environmentObject(core)
        }
    }
}

/// 日志查看页：经 sendProviderMessage 向运行中的 NE 索取日志（不依赖 App Group）。
private struct LogView: View {
    @EnvironmentObject private var core: CoreStateManager
    @Environment(\.dismiss) private var dismiss
    @State private var text = "加载中…"

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle("NE 运行日志")
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
        text = "拉取中…"
        text = await core.fetchLogs()
    }
}
