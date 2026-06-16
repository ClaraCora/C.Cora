import Foundation
import NetworkExtension

/// 负责与系统 VPN 子系统打交道：安装/加载 VPN 描述文件、启停隧道、上报状态。
///
/// Phase 0 只做最小闭环——把 NE 隧道拉起/停掉，验证权限链路与 VPN 图标。
/// Phase 2 起，这里会通过 `sendProviderMessage` 向 NE 传配置路径、查询运行态。
///
/// 设计上它是「控制面」的底层，不持有 UI 状态；UI 状态由 CoreStateManager 聚合。
final class TunnelManager {

    /// 当前使用的 provider 管理对象。懒加载/复用，避免重复创建系统描述文件。
    private var manager: NETunnelProviderManager?

    /// 加载（或创建）唯一的 VPN 描述文件。
    /// iOS 要求 VPN 配置先 saveToPreferences 落到「设置 > VPN」里，用户授权一次后方可启动。
    func loadOrCreateManager() async throws -> NETunnelProviderManager {
        // 先尝试读取已有配置，避免每次新建导致系统里堆叠多个 VPN 条目
        let existing = try await NETunnelProviderManager.loadAllFromPreferences()
        let mgr = existing.first ?? NETunnelProviderManager()

        // NETunnelProviderProtocol 指向我们的 NE 扩展
        let proto = (mgr.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppConstants.tunnelBundleID
        // serverAddress 仅用于系统 UI 展示，Phase 0 用占位串即可
        proto.serverAddress = "MiClash"

        mgr.protocolConfiguration = proto
        mgr.localizedDescription = AppConstants.vpnProfileName
        mgr.isEnabled = true

        // 落盘到系统偏好；首次会弹「允许 MiClash 添加 VPN 配置」
        try await mgr.saveToPreferences()
        // 存盘后需重新 load 一次，拿到系统补全后的对象（否则 startVPNTunnel 可能报错）
        try await mgr.loadFromPreferences()

        self.manager = mgr
        return mgr
    }

    /// 启动隧道。Phase 0 不带参数；后续可通过 options 把配置路径等传给 NE。
    func start() async throws {
        let mgr = try await loadOrCreateManager()
        try mgr.connection.startVPNTunnel()
    }

    /// 停止隧道。
    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    /// 读取当前连接状态（用于 UI 初始化时同步）。
    func currentStatus() async -> NEVPNStatus {
        guard let mgr = try? await loadOrCreateManager() else { return .invalid }
        return mgr.connection.status
    }
}
