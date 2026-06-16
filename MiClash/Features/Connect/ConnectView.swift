import SwiftUI

/// Phase 0 的唯一界面：一个连接开关 + 状态显示。
///
/// 它只读 CoreStateManager 的状态、调它的方法，自身不持有业务逻辑——
/// 这是后续四大页面（Dashboard/Proxies/Profiles/Settings）统一遵循的 MVVM 范式雏形。
struct ConnectView: View {
    @EnvironmentObject private var core: CoreStateManager

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

            Spacer()
            VStack(spacing: 2) {
                // Phase 1：显示 mihomo 内核版本，证明核心已加载
                Text(core.coreVersion)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("Phase 1 · 验证 mihomo 内核加载")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 8)
        }
        .task {
            // 视图出现时同步一次真实状态（冷启动场景）
            await core.refreshStatus()
        }
    }
}
