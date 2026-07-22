import AppIntents
import NetworkExtension
import SwiftUI
import WidgetKit

// 控制中心小组件（iOS 18+）：一个「代理开关」磁贴，长按控制中心即可添加。
// 点一下直接启停 NE 隧道——不传 options，NE 会用上次缓存的配置启动
// （见 PacketTunnelProvider 的 resolveCached 兜底），所以从控制中心拉起也能用上最近的订阅。
//
// 进程：磁贴的状态读取（ControlValueProvider）与点击动作（AppIntent）都跑在本扩展进程里，
// 需要与主 App 同样的 networkextension(packet-tunnel-provider) 权限才能 load/启停 NETunnelProviderManager。

@main
struct MiClashControlBundle: WidgetBundle {
    var body: some Widget {
        VPNControlWidget()
    }
}

/// NE 隧道的 providerBundleIdentifier，用来在多个 VPN 配置里认出我们自己的那个。
private let tunnelBundleID = "com.miclash.app.tunnel"

/// 找到 MiClash 自己的 VPN 管理对象，不能退回其它陈旧配置。
private func miclashManager() async throws -> NETunnelProviderManager? {
    let all = try await NETunnelProviderManager.loadAllFromPreferences()
    return all.first {
        ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == tunnelBundleID
    }
}

/// 覆盖安装后系统可能吞掉第一次启动请求；只在未进入运行态时刷新配置并补试一次。
private func startVPN(_ manager: NETunnelProviderManager) async throws {
    try await manager.loadFromPreferences()
    do {
        try manager.connection.startVPNTunnel()
    } catch {
        try await manager.loadFromPreferences()
        try manager.connection.startVPNTunnel()
        return
    }

    for _ in 0..<6 {
        switch manager.connection.status {
        case .connected, .connecting, .reasserting:
            return
        case .invalid, .disconnected, .disconnecting:
            break
        @unknown default:
            break
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    for _ in 0..<8 {
        guard manager.connection.status == .disconnecting else { break }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
    try await manager.loadFromPreferences()
    try manager.connection.startVPNTunnel()
}

/// 控制中心「代理开关」磁贴。
struct VPNControlWidget: ControlWidget {
    static let kind = ControlWidgetKind.vpn

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: VPNStatusProvider()) { isOn in
            ControlWidgetToggle(
                "MiClash",
                isOn: isOn,
                action: ToggleVPNIntent()
            ) { on in
                Label(on ? "已连接" : "未连接",
                      systemImage: on ? "shield.lefthalf.filled" : "shield.slash")
            }
            .tint(.green)
        }
        .displayName("MiClash 代理")
        .description("一键开关 MiClash 代理")
    }
}

/// 提供磁贴当前状态：优先读 NETunnelProviderManager 的真实连接状态（不依赖 App Group，
/// 反映 App 内/系统设置里的任何来源），读不到再退回 App Group 共享值。
struct VPNStatusProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        if let mgr = try? await miclashManager() {
            switch mgr.connection.status {
            case .connected, .connecting, .reasserting:
                return true
            case .disconnected, .disconnecting, .invalid:
                return false
            @unknown default:
                break
            }
        }
        return AppGroupState.vpnConnected
    }
}

/// 磁贴点击动作：按目标状态启停隧道。
struct ToggleVPNIntent: SetValueIntent {
    static let title: LocalizedStringResource = "切换 MiClash 代理"

    @Parameter(title: "开启")
    var value: Bool

    func perform() async throws -> some IntentResult {
        guard let mgr = try await miclashManager() else {
            throw VPNControlError.notConfigured
        }
        // 配置可能被系统标记为 disabled，启动前确保启用。
        if !mgr.isEnabled {
            mgr.isEnabled = true
            try? await mgr.saveToPreferences()
            try? await mgr.loadFromPreferences()
        }
        if value {
            try await startVPN(mgr)
        } else {
            mgr.connection.stopVPNTunnel()
        }
        // 乐观写入共享状态并刷新磁贴，让开关立刻翻到目标态（NE 启停后会再写一次确认）。
        AppGroupState.vpnConnected = value
        ControlCenter.shared.reloadControls(ofKind: VPNControlWidget.kind)
        return .result()
    }
}

/// 还没在 App 内授权过 VPN 配置时给出的可读错误。
enum VPNControlError: Error, CustomLocalizedStringResourceConvertible {
    case notConfigured

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConfigured: return "请先打开 MiClash 连接一次，授权 VPN 配置后再用控制中心开关"
        }
    }
}
