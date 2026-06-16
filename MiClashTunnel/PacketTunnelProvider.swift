import NetworkExtension
import Mihomo // gomobile 生成的 mihomo 内核框架（含 with_gvisor）
import Darwin
import os.log

/// Network Extension 的 Packet Tunnel 实现（Phase 2：真正接管流量）。
///
/// 流程：
/// 1. 下发 NEPacketTunnelNetworkSettings（IP/路由/DNS），iOS 据此创建 utun 接口；
/// 2. 扫描进程内的 utun 文件描述符（fd）；
/// 3. 把 fd + DIRECT 配置交给 mihomo，由内核接管这块网卡的收发。
///
/// ⚠️ 内存约束：Packet Tunnel 扩展约 50MB 上限。gVisor 栈本身吃内存，所以配置里
/// 严禁加载 geo 数据库（DIRECT 测试用 MATCH 规则），否则极易 OOM 被系统杀。
class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: "com.miclash.app.tunnel", category: "PacketTunnel")

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        log.info("startTunnel：开始配置网络设置")

        let settings = makeNetworkSettings()
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                self.log.error("应用网络设置失败：\(error.localizedDescription, privacy: .public)")
                completionHandler(error)
                return
            }

            // 网络设置生效后，iOS 才创建好 utun 接口，此时扫描 fd
            guard let fd = self.findTunnelFileDescriptor() else {
                self.log.error("未找到 utun 文件描述符")
                completionHandler(NSError(domain: "MiClashTunnel", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "未找到 utun fd"]))
                return
            }
            self.log.info("拿到 utun fd = \(fd, privacy: .public)，启动 mihomo 内核")

            // mihomo 工作目录设为 App Group 容器（可写，且与主 App 共享）
            guard let home = self.appGroupContainerPath() else {
                self.log.error("无法获取 App Group 容器路径")
                completionHandler(NSError(domain: "MiClashTunnel", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "App Group 容器不可用"]))
                return
            }
            MihomoSetup(home)

            // gomobile 把带 error 返回的 Go 函数生成为「返回 BOOL + NSError** 出参」的 C 函数，
            // 不会自动桥接成 Swift throws，所以用经典 NSError 指针写法：成功返回 true。
            var startError: NSError?
            let ok = MihomoStartWithFd(Int(fd), MihomoConfig.directModeYAML(), &startError)
            if ok {
                self.log.info("mihomo 启动成功（DIRECT 模式）")
                completionHandler(nil)
            } else {
                let err = startError ?? NSError(domain: "MiClashTunnel", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "mihomo 启动失败（未知错误）"])
                self.log.error("mihomo 启动失败：\(err.localizedDescription, privacy: .public)")
                completionHandler(err)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                            completionHandler: @escaping () -> Void) {
        log.info("stopTunnel，原因：\(reason.rawValue, privacy: .public)")
        MihomoStop()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data,
                                  completionHandler: ((Data?) -> Void)?) {
        completionHandler?(messageData)
    }

    // MARK: - 网络设置

    /// 构建隧道网络设置。地址与 mihomo 配置严格对齐（198.18.0.x）。
    private func makeNetworkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: MihomoConfig.tunGatewayIP)

        // IPv4：网关 198.18.0.1/16，默认路由全量接管。
        // 注：字面默认路由 0.0.0.0/0 经真机验证可用——核心 DIRECT 出站靠系统真实
        // 默认路由走物理网卡，不回环（早期「8 段子网」方案已被推翻）。
        let ipv4 = NEIPv4Settings(addresses: [MihomoConfig.tunGatewayIP],
                                  subnetMasks: [MihomoConfig.tunSubnetMask])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        // DNS：指向 mihomo 的 fake-ip 网关，matchDomains=[""] 强制所有查询进 tunnel
        let dns = NEDNSSettings(servers: [MihomoConfig.dnsServerIP])
        dns.matchDomains = [""]
        dns.matchDomainsNoSearch = true
        settings.dnsSettings = dns

        settings.mtu = NSNumber(value: MihomoConfig.mtu)
        return settings
    }

    // MARK: - utun fd 获取

    /// 扫描本进程的文件描述符，找出 iOS 为本隧道创建的 utun 接口的 fd。
    ///
    /// 原理：utun 接口底层是 SYSPROTO_CONTROL 类型的 socket，对其用
    /// getsockopt(UTUN_OPT_IFNAME) 能取到接口名（utunN）。遍历 fd 命中即得。
    /// 这是 sing-box / clashmi 等在 iOS 上的通用做法，比 KVC 取私有属性更稳。
    private func findTunnelFileDescriptor() -> Int32? {
        let SYSPROTO_CONTROL: Int32 = 2 // <sys/sys_domain.h>
        let UTUN_OPT_IFNAME: Int32 = 2  // <net/if_utun.h>

        var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        for fd in Int32(0)..<1024 {
            var nameLength = socklen_t(nameBuffer.count)
            let result = getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME,
                                    &nameBuffer, &nameLength)
            if result == 0 {
                let name = nameBuffer.withUnsafeBufferPointer { ptr in
                    String(cString: ptr.baseAddress!)
                }
                if name.hasPrefix("utun") {
                    return fd
                }
            }
        }
        return nil
    }

    // MARK: - App Group

    /// App Group 共享容器路径，作为 mihomo 的 home dir。
    private func appGroupContainerPath() -> String? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.miclash.app")?
            .path
    }
}
