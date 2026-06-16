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

/// 找到 MiClash 自己的 VPN 管理对象（按 provider bundle id 过滤，认不出就退回第一个）。
private func miclashManager() async throws -> NETunnelProviderManager? {
    let all = try await NETunnelProviderManager.loadAllFromPreferences()
    return all.first {
        ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == tunnelBundleID
    } ?? all.first
}

/// 控制中心「代理开关」磁贴。
struct VPNControlWidget: ControlWidget {
    static let kind = "com.miclash.app.control.vpn"

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

/// 提供磁贴当前状态：VPN 已连接/连接中 → 开。
struct VPNStatusProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        guard let mgr = try await miclashManager() else { return false }
        switch mgr.connection.status {
        case .connected, .connecting, .reasserting:
            return true
        default:
            return false
        }
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
            try mgr.connection.startVPNTunnel()
        } else {
            mgr.connection.stopVPNTunnel()
        }
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
