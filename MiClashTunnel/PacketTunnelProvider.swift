import NetworkExtension
import Mihomo // gomobile 生成的 mihomo 内核框架（含 with_gvisor）
import Network
import Darwin
import os.log
import WidgetKit

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

    /// 当前 mihomo 工作目录（含 run.log）。供 handleAppMessage 回传内核日志用。
    private var homeDir: String?

    // 物理接口监控：把真实出站接口（en0/pdp_ip0）显式喂给内核，取代 mihomo 自带的不可靠监控。
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.miclash.tunnel.pathmonitor", qos: .utility)
    private var pendingPathUpdate: DispatchWorkItem?
    private var lastInterfaceName: String?

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        // 每次启动清空 ne.log，避免历史残留干扰排查
        FileLog.reset()
        FileLog.write("startTunnel：开始配置网络设置")
        log.info("startTunnel：开始配置网络设置")

        // 配置经 startVPNTunnel(options:) 下发（不依赖 App Group）。手动连接时主 App 会带 "config" 和 "settings"。
        let incomingConfig = (options?["config"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let settingsJSON = (options?["settings"] as? String) ?? ""
        FileLog.write("收到配置：\(incomingConfig != nil ? "来自 options(\(incomingConfig!.count) 字节)" : "无（将用缓存/DIRECT 兜底）")，settings=\(settingsJSON.count)字节")

        let settings = makeNetworkSettings()
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                FileLog.write("应用网络设置失败：\(error.localizedDescription)")
                self.log.error("应用网络设置失败：\(error.localizedDescription, privacy: .public)")
                completionHandler(error)
                return
            }
            FileLog.write("网络设置已生效")

            // 网络设置生效后，iOS 才创建好 utun 接口，此时定位 fd
            guard let fd = self.findTunnelFileDescriptor() else {
                FileLog.write("未找到 utun fd（getifaddrs/getsockopt 都没命中网关 IP）")
                self.log.error("未找到 utun 文件描述符")
                completionHandler(NSError(domain: "MiClashTunnel", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "未找到 utun fd"]))
                return
            }
            FileLog.write("拿到 utun fd = \(fd)")
            self.log.info("拿到 utun fd = \(fd, privacy: .public)，启动 mihomo 内核")

            // mihomo 工作目录：优先 App Group 容器（与主 App 共享，日志可被读取）；
            // App Group 不可用时回退到 NE 自己的沙盒目录——保证代理仍能跑起来，
            // App Group 只影响“日志/配置共享”，不该卡死整个 VPN。
            let home = self.appGroupContainerPath() ?? self.fallbackHomePath()
            let usingShared = self.appGroupContainerPath() != nil
            self.homeDir = home
            FileLog.write("home dir = \(home)（\(usingShared ? "App Group 共享" : "NE 沙盒回退")），调用 MihomoSetup")
            MihomoSetup(home)

            // 确定最终配置/设置：options → 缓存文件 → 兜底。
            // 收到 options 时写入缓存，供系统重连（startTunnel 无 options）复用。
            let configYAML = self.resolveCached(incoming: incomingConfig, home: home,
                                                file: "config.yaml") ?? MihomoConfig.directModeYAML()
            let settings = self.resolveCached(incoming: settingsJSON.isEmpty ? nil : settingsJSON,
                                              home: home, file: "settings.json") ?? ""

            // gomobile 把带 error 返回的 Go 函数生成为「返回 BOOL + NSError** 出参」的 C 函数，
            // 不会自动桥接成 Swift throws，所以用经典 NSError 指针写法：成功返回 true。
            FileLog.write("调用 MihomoStartWithConfig…")
            var startError: NSError?
            let ok = MihomoStartWithConfig(Int(fd), configYAML, settings, &startError)
            if ok {
                FileLog.write("MihomoStartWithConfig 返回成功")
                self.log.info("mihomo 启动成功")
                AppGroupState.vpnConnected = true // 共享给控制中心磁贴显示
                ControlCenter.shared.reloadControls(ofKind: ControlWidgetKind.vpn)
                self.startPathMonitor() // 开始把真实出站接口喂给内核
                completionHandler(nil)
            } else {
                let err = startError ?? NSError(domain: "MiClashTunnel", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "mihomo 启动失败（未知错误）"])
                FileLog.write("MihomoStartWithConfig 失败：\(err.localizedDescription)")
                self.log.error("mihomo 启动失败：\(err.localizedDescription, privacy: .public)")
                completionHandler(err)
            }
        }
    }

    /// 取值优先级：options 传入（并写缓存）→ 缓存文件 → nil。
    private func resolveCached(incoming: String?, home: String, file: String) -> String? {
        let cachePath = (home as NSString).appendingPathComponent(file)
        if let value = incoming {
            try? value.write(toFile: cachePath, atomically: true, encoding: .utf8)
            FileLog.write("使用 options \(file)（\(value.count) 字节，已缓存）")
            return value
        }
        if let cached = try? String(contentsOfFile: cachePath, encoding: .utf8), !cached.isEmpty {
            FileLog.write("使用缓存 \(file)（\(cached.count) 字节）")
            return cached
        }
        return nil
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                            completionHandler: @escaping () -> Void) {
        FileLog.write("stopTunnel，原因 rawValue=\(reason.rawValue)")
        log.info("stopTunnel，原因：\(reason.rawValue, privacy: .public)")
        AppGroupState.vpnConnected = false // 同步给控制中心磁贴
        ControlCenter.shared.reloadControls(ofKind: ControlWidgetKind.vpn)
        stopPathMonitor()
        MihomoStop()
        completionHandler()
    }

    // MARK: - 物理接口监控

    /// 监控网络路径，把真实出站接口名喂给 mihomo（取代其自带的 iOS 下不可靠的接口监控）。
    /// 出站绑对物理网卡才不会被默认路由兜回 tun → 这是吞吐能跑满的关键。
    private func startPathMonitor() {
        stopPathMonitor()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.schedulePathUpdate(path)
        }
        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pendingPathUpdate?.cancel()
        pendingPathUpdate = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    /// 首次立即应用（缩短启动时「出站未绑接口」的窗口）；之后变化用防抖。
    private func schedulePathUpdate(_ path: Network.NWPath) {
        pendingPathUpdate?.cancel()
        if lastInterfaceName == nil {
            applyInterface(from: path)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.applyInterface(from: path)
        }
        pendingPathUpdate = work
        pathMonitorQueue.asyncAfter(deadline: .now() + .milliseconds(800), execute: work)
    }

    private func applyInterface(from path: Network.NWPath) {
        guard path.status == .satisfied,
              let iface = path.availableInterfaces.first(where: { $0.type != .other }) ?? path.availableInterfaces.first else {
            return
        }
        guard iface.name != lastInterfaceName else { return }
        lastInterfaceName = iface.name
        FileLog.write("出站接口切到 \(iface.name)")
        MihomoSetDefaultInterface(iface.name)
    }

    /// 主 App 经 sendProviderMessage 发来的请求（不依赖 App Group 的官方 IPC）。
    /// JSON 命令协议：{"cmd":"getLogs"|"queryProxies"|"selectProxy","group":..,"name":..}。
    /// 关键：completionHandler 必须**非 nil 回调**，否则主 App 侧 resp 为 nil。
    override func handleAppMessage(_ messageData: Data,
                                  completionHandler: ((Data?) -> Void)?) {
        let obj = (try? JSONSerialization.jsonObject(with: messageData)) as? [String: Any]
        let cmd = (obj?["cmd"] as? String) ?? String(data: messageData, encoding: .utf8) ?? ""
        FileLog.write("handleAppMessage：cmd=\(cmd)")

        switch cmd {
        case "queryProxies":
            // 直接回传 mihomo 的 proxies JSON
            completionHandler?(Data(MihomoQueryProxies().utf8))
        case "selectProxy":
            let group = (obj?["group"] as? String) ?? ""
            let name = (obj?["name"] as? String) ?? ""
            var err: NSError?
            let ok = MihomoSelectProxy(group, name, &err)
            let resp: [String: Any] = ok ? ["ok": true]
                                         : ["ok": false, "error": err?.localizedDescription ?? "未知错误"]
            completionHandler?((try? JSONSerialization.data(withJSONObject: resp)) ?? Data())
        case "groupDelay":
            let group = (obj?["group"] as? String) ?? ""
            let url = (obj?["url"] as? String) ?? ""
            let timeout = (obj?["timeout"] as? Int) ?? 5000
            completionHandler?(Data(MihomoGroupDelay(group, url, timeout).utf8))
        case "traffic":
            completionHandler?(Data(MihomoTrafficNow().utf8))
        case "proxyDetails":
            completionHandler?(Data(MihomoProxyDetails().utf8))
        case "configNotices":
            completionHandler?(Data(MihomoConfigNotices().utf8))
        case "getMode":
            completionHandler?(Data(MihomoMode().utf8))
        case "setMode":
            MihomoSetMode((obj?["mode"] as? String) ?? "rule")
            completionHandler?(Data(#"{"ok":true}"#.utf8))
        default: // getLogs 及未知命令都回传日志，便于排查
            // 日志可能很大，IPC 响应有体积上限 → 只回传末尾约 24KB，取最新内容。
            let body = "[cmd=\(cmd)]\n" + collectLogs()
            completionHandler?(Self.tailData(body, maxBytes: 24 * 1024))
        }
    }

    /// 取字符串末尾不超过 maxBytes 的 UTF-8 数据（避免 IPC 响应超限被丢成空响应）。
    private static func tailData(_ s: String, maxBytes: Int) -> Data {
        let data = Data(s.utf8)
        guard data.count > maxBytes else { return data }
        return Data("…（已截断，仅显示最新 \(maxBytes / 1024)KB）\n".utf8) + data.suffix(maxBytes)
    }

    /// 汇总 NE 步骤日志（内存）+ mihomo 内核 run.log（home 目录）。
    private func collectLogs() -> String {
        var out = "===== ne（NE 启动步骤，内存）=====\n" + FileLog.dump()
        if let home = homeDir {
            let runPath = (home as NSString).appendingPathComponent("run.log")
            let run = (try? String(contentsOfFile: runPath, encoding: .utf8)) ?? "(run.log 不存在)"
            out += "\n\n===== run.log（mihomo 内核）=====\n" + (run.isEmpty ? "(空)" : run)
        } else {
            out += "\n\n(home 未设置，mihomo 尚未启动)"
        }
        return out
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
    //
    // ⚠️ 设计依据与取舍（已查 Apple 官方文档确认）：
    // Apple 对 NEPacketTunnelProvider 文档化的唯一数据通道是 `packetFlow`
    // （NEPacketTunnelFlow，read/writePackets 收发 Data 包），**官方不暴露 utun 的 fd**。
    // 但 mihomo（底层 sing-tun）原生按「给我一个 fd，我接管这块网卡」设计，要的是 fd。
    // 经与用户确认，本项目走「A. fd 直喂」：性能最好、Go 胶水最少，是 clash/sing-box
    // iOS 的事实标准做法；自签/个人用无 App Store 审核风险。fd 获取属文档外技巧，
    // 故下面用「网关 IP 锁定接口名」把它做成确定性的，避免盲扫选错 utun。

    /// 找出 iOS 为本隧道创建的 utun 接口的 fd（确定性版本）。
    ///
    /// 两步：
    /// 1. getifaddrs 找出「IPv4 地址 == 我们网关 198.18.0.1」的那块 utun 接口名——
    ///    网络设置生效后该 IP 已绑到我们自己的 utun 上，能唯一区分于别的 VPN 的 utun；
    /// 2. 遍历 fd，用 getsockopt(UTUN_OPT_IFNAME) 取名，精确匹配第 1 步的接口名。
    private func findTunnelFileDescriptor() -> Int32? {
        guard let wantName = tunnelInterfaceName() else {
            log.error("getifaddrs 未找到 IP=\(MihomoConfig.tunGatewayIP, privacy: .public) 的 utun 接口")
            return nil
        }
        log.info("目标 utun 接口名：\(wantName, privacy: .public)")

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
                if name == wantName {
                    return fd
                }
            }
        }
        return nil
    }

    /// 用 getifaddrs 找到绑定了我们网关 IP 的 utun 接口名。
    private func tunnelInterfaceName() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor = ifaddrPtr
        while let cur = cursor {
            defer { cursor = cur.pointee.ifa_next }
            let ifa = cur.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }
            let ifName = String(cString: ifa.ifa_name)
            guard ifName.hasPrefix("utun") else { continue }

            var sin = sockaddr_in()
            memcpy(&sin, sa, Int(MemoryLayout<sockaddr_in>.size))
            let ip = String(cString: inet_ntoa(sin.sin_addr))
            if ip == MihomoConfig.tunGatewayIP {
                return ifName
            }
        }
        return nil
    }

    // MARK: - App Group

    /// App Group 共享容器路径，作为 mihomo 的 home dir。
    /// 用 AppGroup 动态解析实际被授予的 group（兼容重签工具改写 group id 的情况）。
    private func appGroupContainerPath() -> String? {
        AppGroup.containerURL?.path
    }

    /// 回退 home：NE 进程自己的 Library 目录，永远可写、无需任何 entitlement。
    /// 仅在 App Group 不可用时用，确保 mihomo 仍有可写工作目录、代理能跑。
    private func fallbackHomePath() -> String {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("mihomo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}
