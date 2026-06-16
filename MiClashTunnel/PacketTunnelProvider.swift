import NetworkExtension
import os.log

/// Network Extension 的 Packet Tunnel 实现。
///
/// Phase 0 是「空壳」：只把隧道拉起来（设置一个占位的网络配置），
/// 不接管真实流量、不接 mihomo 核心——目的是验证 entitlements / App Group /
/// VPN 权限链路是否打通（系统出现 VPN 图标、NE 进程被成功拉起）。
///
/// ⚠️ 内存约束：Packet Tunnel 扩展有严格内存上限（现代 iOS 约 50MB，历史 15MB）。
/// Phase 2 接入 mihomo 时务必用 system 协议栈、精简配置，避免 OOM 被系统杀。
class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: "com.miclash.app.tunnel", category: "PacketTunnel")

    /// 系统调用此方法启动隧道。
    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        log.info("startTunnel 被调用，配置占位网络设置（Phase 0 空壳）")

        // 占位的隧道网络设置。Phase 2 会替换为真实的 IP/路由/DNS，
        // 并且路由要用「8 段子网」而非 0.0.0.0/0，以保留系统默认路由防止黑洞断网。
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        // 给隧道分配一个私有 IPv4 地址（占位，不实际承载流量）
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        // Phase 0 不接管任何流量 → 不下发 includedRoutes，避免误伤系统网络
        ipv4.includedRoutes = []
        settings.ipv4Settings = ipv4

        applyTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                self?.log.error("应用网络设置失败：\(error.localizedDescription, privacy: .public)")
            } else {
                self?.log.info("隧道已就绪（空壳）")
            }
            completionHandler(error)
        }
    }

    /// 系统调用此方法停止隧道。
    override func stopTunnel(with reason: NEProviderStopReason,
                            completionHandler: @escaping () -> Void) {
        log.info("stopTunnel，原因：\(reason.rawValue, privacy: .public)")
        completionHandler()
    }

    /// 主 App 通过 sendProviderMessage 发来的消息（Phase 2+ 用于传配置、查状态）。
    override func handleAppMessage(_ messageData: Data,
                                  completionHandler: ((Data?) -> Void)?) {
        // Phase 0 暂不处理，原样回个 ack
        completionHandler?(messageData)
    }
}
