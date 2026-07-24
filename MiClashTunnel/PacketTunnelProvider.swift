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

    /// 当前运行中的 utun fd。配置重载只复用它，不重建系统隧道。
    private var tunnelFileDescriptor: Int32?
    private var tunnelMTU: Int?
    private var configuredTunnelMTU: Int?
    private var isStopping = false
    private let reloadQueue = DispatchQueue(label: "com.miclash.tunnel.reload", qos: .userInitiated)

    // 物理接口监控：把真实出站接口（en0/pdp_ip0）显式喂给内核，取代 mihomo 自带的不可靠监控。
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.miclash.tunnel.pathmonitor", qos: .utility)
    private var pendingPathUpdate: DispatchWorkItem?
    private var lastInterfaceName: String?

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        reloadQueue.sync {
            isStopping = false
            tunnelFileDescriptor = nil
            tunnelMTU = nil
            configuredTunnelMTU = nil
        }
        // 每次启动清空 ne.log，避免历史残留干扰排查
        FileLog.reset()
        FileLog.write("startTunnel：开始配置网络设置")
        log.info("startTunnel：开始配置网络设置")

        // App 主动连接始终带 config：非空=订阅，空串=明确 DIRECT；系统重连无此 key，复用缓存。
        let hasConfigOption = options?["config"] != nil
        let incomingConfig = options?["config"] as? String
        let settingsJSON = (options?["settings"] as? String) ?? ""
        let configSource = hasConfigOption
            ? ((incomingConfig?.isEmpty == false) ? "来自 options(\(incomingConfig!.count) 字节)" : "App 明确 DIRECT")
            : "无 options（系统重连，将用缓存/DIRECT 兜底）"
        FileLog.write("收到配置：\(configSource)，settings=\(settingsJSON.count)字节")

        // 在创建 utun 前先解析配置，只有显式 tun.mtu 才固定接口 MTU；否则交给 iOS 计算。
        let sharedHome = appGroupContainerPath()
        let home = sharedHome ?? fallbackHomePath()
        homeDir = home
        FileLog.write("home dir = \(home)（\(sharedHome != nil ? "App Group 共享" : "NE 沙盒回退")），调用 MihomoSetup")
        MihomoSetup(home)

        let configYAML = resolveConfig(incoming: incomingConfig,
                                       hasOption: hasConfigOption, home: home)
        let resolvedSettings = resolveCached(incoming: settingsJSON.isEmpty ? nil : settingsJSON,
                                             home: home, file: "settings.json") ?? ""

        // GEO / ASN 文件必须由主 App 预先写入共享 home；NE 启动阶段不再联网下载。
        if let geoError = Self.validateGeoAssets(configYAML: configYAML,
                                                  settingsJSON: resolvedSettings,
                                                  home: home) {
            FileLog.write("GEO / ASN 数据检查失败：\(geoError.localizedDescription)")
            completionHandler(geoError)
            return
        }

        let configuredMTUValue = Int(MihomoConfiguredTunMTU(configYAML))
        let configuredMTU: Int? = configuredMTUValue > 0 ? configuredMTUValue : nil
        FileLog.write(configuredMTU.map { "MTU 使用配置值：\($0)" }
            ?? "配置未设置 tun.mtu，由 iOS 选择系统 MTU")

        let networkSettings = makeNetworkSettings(configuredMTU: configuredMTU)
        setTunnelNetworkSettings(networkSettings) { [weak self] error in
            guard let self else { return }
            if let error {
                FileLog.write("应用网络设置失败：\(error.localizedDescription)")
                self.log.error("应用网络设置失败：\(error.localizedDescription, privacy: .public)")
                completionHandler(error)
                return
            }
            FileLog.write("网络设置已生效")

            // 网络设置生效后，iOS 才创建好 utun 接口，此时读取系统选定的 MTU 并定位 fd。
            guard let interface = self.tunnelInterfaceInfo(),
                  let fd = self.findTunnelFileDescriptor(named: interface.name) else {
                FileLog.write("未找到 utun fd（getifaddrs/getsockopt 都没命中网关 IP）")
                self.log.error("未找到 utun 文件描述符")
                completionHandler(NSError(domain: "MiClashTunnel", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "未找到 utun fd"]))
                return
            }
            if let configuredMTU,
               let systemMTU = interface.mtu,
               configuredMTU != systemMTU {
                let message = "iOS 创建的 MTU（\(systemMTU)）与配置 tun.mtu（\(configuredMTU)）不一致"
                FileLog.write("MTU 应用失败：\(message)")
                self.log.error("MTU 应用失败：\(message, privacy: .public)")
                completionHandler(NSError(
                    domain: "MiClashTunnel",
                    code: -6,
                    userInfo: [NSLocalizedDescriptionKey: message]))
                return
            }
            let actualMTU = interface.mtu ?? configuredMTU ?? MihomoConfig.fallbackMTU
            FileLog.write("拿到 \(interface.name) fd=\(fd)，实际 MTU=\(actualMTU)"
                + (interface.mtu == nil ? "（读取失败，已回退）" : ""))
            self.log.info("拿到 \(interface.name, privacy: .public) fd=\(fd, privacy: .public)，MTU=\(actualMTU, privacy: .public)，启动 mihomo 内核")

            // gomobile 把带 error 返回的 Go 函数生成为「返回 BOOL + NSError** 出参」的 C 函数，
            // 不会自动桥接成 Swift throws，所以用经典 NSError 指针写法：成功返回 true。
            FileLog.write("调用 MihomoStartWithConfig…")
            var startError: NSError?
            let startResult: Bool? = self.reloadQueue.sync {
                guard !self.isStopping else { return nil }
                let ok = MihomoStartWithConfig(
                    Int(fd), actualMTU, configYAML, resolvedSettings, &startError)
                if ok {
                    FileLog.write("MihomoStartWithConfig 返回成功")
                    self.log.info("mihomo 启动成功")
                    self.tunnelFileDescriptor = fd
                    self.tunnelMTU = actualMTU
                    self.configuredTunnelMTU = configuredMTU
                    AppGroupState.vpnConnected = true // 共享给控制中心磁贴显示
                    ControlCenter.shared.reloadControls(ofKind: ControlWidgetKind.vpn)
                    self.startPathMonitor() // 开始把真实出站接口喂给内核
                }
                return ok
            }
            guard let startResult else {
                completionHandler(NSError(
                    domain: "MiClashTunnel",
                    code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "VPN 启动已取消"]))
                return
            }
            guard startResult else {
                let error = startError ?? NSError(domain: "MiClashTunnel", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "mihomo 启动失败（未知错误）"])
                FileLog.write("MihomoStartWithConfig 失败：\(error.localizedDescription)")
                self.log.error("mihomo 启动失败：\(error.localizedDescription, privacy: .public)")
                completionHandler(error)
                return
            }

            let stillRunning = self.reloadQueue.sync {
                !self.isStopping && self.tunnelFileDescriptor == fd
            }
            if stillRunning {
                completionHandler(nil)
            } else {
                completionHandler(NSError(
                    domain: "MiClashTunnel",
                    code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "VPN 启动已取消"]))
            }
        }
    }

    /// 配置解析：App option 非空=订阅，显式空=内建 DIRECT；无 option=系统重连复用缓存。
    private func resolveConfig(incoming: String?, hasOption: Bool, home: String) -> String {
        let cachePath = (home as NSString).appendingPathComponent("config.yaml")
        if hasOption {
            let value = (incoming?.isEmpty == false) ? incoming! : MihomoConfig.directModeYAML()
            try? value.write(toFile: cachePath, atomically: true, encoding: .utf8)
            FileLog.write(incoming?.isEmpty == false
                ? "使用 App options config.yaml（\(value.count) 字节，已缓存）"
                : "App 明确无活动配置：使用内建 DIRECT（已覆盖缓存）")
            return value
        }
        if let cached = try? String(contentsOfFile: cachePath, encoding: .utf8), !cached.isEmpty {
            if let migrated = MihomoConfig.migrateLegacyDirectModeYAML(cached) {
                try? migrated.write(toFile: cachePath, atomically: true, encoding: .utf8)
                FileLog.write("系统无 options 重连：已将旧版内建 DIRECT 缓存迁移为系统 MTU")
                return migrated
            }
            FileLog.write("系统无 options 重连：使用缓存 config.yaml（\(cached.count) 字节）")
            return cached
        }
        FileLog.write("系统无 options 重连且无缓存：使用内建 DIRECT")
        return MihomoConfig.directModeYAML()
    }

    /// 普通值优先级：options 传入（并写缓存）→ 缓存文件 → nil。
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
        reloadQueue.sync {
            isStopping = true
            tunnelFileDescriptor = nil
            tunnelMTU = nil
            configuredTunnelMTU = nil
            AppGroupState.vpnConnected = false // 同步给控制中心磁贴
            ControlCenter.shared.reloadControls(ofKind: ControlWidgetKind.vpn)
            stopPathMonitor()
            MihomoStop()
        }
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
    /// JSON 命令协议：{"cmd":"getLogs"|"queryProxies"|"selectProxy"|"traffic"|"memory",...}。
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
        case "memory":
            completionHandler?(Self.memoryFootprintData())
        case "proxyDetails":
            completionHandler?(Data(MihomoProxyDetails().utf8))
        case "configNotices":
            completionHandler?(Data(MihomoConfigNotices().utf8))
        case "getMode":
            completionHandler?(Data(MihomoMode().utf8))
        case "setMode":
            MihomoSetMode((obj?["mode"] as? String) ?? "rule")
            completionHandler?(Data(#"{"ok":true}"#.utf8))
        case "reloadConfig":
            reloadConfiguration(obj, completionHandler: completionHandler)
        default: // getLogs 及未知命令都回传日志，便于排查
            // 日志可能很大，IPC 响应有体积上限 → 只回传末尾约 24KB，取最新内容。
            let body = "[cmd=\(cmd)]\n" + collectLogs()
            completionHandler?(Self.tailData(body, maxBytes: 24 * 1024))
        }
    }

    private func reloadConfiguration(_ object: [String: Any]?,
                                     completionHandler: ((Data?) -> Void)?) {
        let transfer = object?["transfer"] as? String
        let token = object?["token"] as? String
        let inlineConfig = object?["config"] as? String
        let inlineSettings = object?["settings"] as? String

        reloadQueue.async { [weak self] in
            guard let self else {
                completionHandler?(Self.reloadResponse(error: "Tunnel 已停止"))
                return
            }
            guard !self.isStopping,
                  let fd = self.tunnelFileDescriptor,
                  let tunnelMTU = self.tunnelMTU,
                  let home = self.homeDir else {
                completionHandler?(Self.reloadResponse(error: "VPN 尚未完成启动"))
                return
            }

            let input: (config: String, settings: String)
            do {
                input = try Self.loadReloadInput(
                    transfer: transfer,
                    token: token,
                    inlineConfig: inlineConfig,
                    inlineSettings: inlineSettings)
            } catch {
                FileLog.write("读取重载配置失败：\(error.localizedDescription)")
                completionHandler?(Self.reloadResponse(
                    error: error.localizedDescription,
                    code: (error as? ReloadInputError)?.responseCode))
                return
            }

            let configYAML = input.config.isEmpty
                ? MihomoConfig.directModeYAML()
                : input.config
            let requestedMTUValue = Int(MihomoConfiguredTunMTU(configYAML))
            let requestedMTU: Int? = requestedMTUValue > 0 ? requestedMTUValue : nil
            guard requestedMTU == self.configuredTunnelMTU else {
                let oldValue = self.configuredTunnelMTU.map(String.init) ?? "系统"
                let newValue = requestedMTU.map(String.init) ?? "系统"
                let message = "tun.mtu 从 \(oldValue) 变为 \(newValue)，请断开并重新连接后生效"
                FileLog.write("拒绝热重载：\(message)")
                completionHandler?(Self.reloadResponse(error: message))
                return
            }
            if let geoError = Self.validateGeoAssets(configYAML: configYAML,
                                                      settingsJSON: input.settings,
                                                      home: home) {
                FileLog.write("重载前 GEO / ASN 数据检查失败：\(geoError.localizedDescription)")
                completionHandler?(Self.reloadResponse(error: geoError.localizedDescription))
                return
            }

            FileLog.write("调用 MihomoReloadConfig（config=\(configYAML.count) 字节）…")
            var reloadError: NSError?
            let ok = MihomoReloadConfig(Int(fd), tunnelMTU, configYAML, input.settings, &reloadError)
            guard ok else {
                let message = reloadError?.localizedDescription ?? "mihomo 重载失败（未知错误）"
                FileLog.write("MihomoReloadConfig 失败：\(message)")
                completionHandler?(Self.reloadResponse(error: message))
                return
            }

            // 只有应用成功才更新系统重连使用的缓存，避免坏配置污染下一次启动。
            let configPath = (home as NSString).appendingPathComponent("config.yaml")
            let settingsPath = (home as NSString).appendingPathComponent("settings.json")
            do {
                try configYAML.write(toFile: configPath, atomically: true, encoding: .utf8)
                try input.settings.write(toFile: settingsPath, atomically: true, encoding: .utf8)
            } catch {
                FileLog.write("配置已重载，但更新重连缓存失败：\(error.localizedDescription)")
            }
            FileLog.write("配置重载成功")
            completionHandler?(Self.reloadResponse())
        }
    }

    private static func loadReloadInput(transfer: String?,
                                        token: String?,
                                        inlineConfig: String?,
                                        inlineSettings: String?) throws -> (config: String, settings: String) {
        if transfer == "appGroup" {
            guard let token, UUID(uuidString: token) != nil,
                  let container = AppGroup.containerURL else {
                throw ReloadInputError.unavailableTransfer
            }
            let directory = container.appendingPathComponent("ReloadRequests", isDirectory: true)
            let configURL = directory.appendingPathComponent("\(token).yaml")
            let settingsURL = directory.appendingPathComponent("\(token).json")
            defer {
                try? FileManager.default.removeItem(at: configURL)
                try? FileManager.default.removeItem(at: settingsURL)
            }
            do {
                return (
                    try String(contentsOf: configURL, encoding: .utf8),
                    try String(contentsOf: settingsURL, encoding: .utf8)
                )
            } catch {
                throw ReloadInputError.readFailed(error.localizedDescription)
            }
        }

        guard let inlineConfig, let inlineSettings else {
            throw ReloadInputError.missingPayload
        }
        return (inlineConfig, inlineSettings)
    }

    private static func reloadResponse(error: String? = nil, code: String? = nil) -> Data {
        var response: [String: Any] = ["ok": error == nil]
        if let error { response["error"] = error }
        if let code { response["code"] = code }
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }

    private enum ReloadInputError: LocalizedError {
        case unavailableTransfer
        case missingPayload
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailableTransfer:
                return "App Group 重载通道不可用"
            case .missingPayload:
                return "重载配置内容缺失"
            case .readFailed(let reason):
                return "读取重载配置失败：\(reason)"
            }
        }

        var responseCode: String? {
            switch self {
            case .unavailableTransfer, .readFailed:
                return "reloadTransferUnavailable"
            case .missingPayload:
                return nil
            }
        }
    }

    /// 返回当前 Network Extension 进程的物理内存占用。
    /// `phys_footprint` 与系统内存压力/Jetsam 口径更接近，不能用 RSS 替代。
    private static func memoryFootprintData() -> Data {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        let footprint = result == KERN_SUCCESS ? info.phys_footprint : 0
        let payload: [String: NSNumber] = ["physFootprint": NSNumber(value: footprint)]
        return (try? JSONSerialization.data(withJSONObject: payload))
            ?? Data(#"{"physFootprint":0}"#.utf8)
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
    private func makeNetworkSettings(configuredMTU: Int?) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: MihomoConfig.tunGatewayIP)

        // IPv4：网关 198.18.0.1/16，默认路由全量接管。
        // 注：字面默认路由 0.0.0.0/0 经真机验证可用——核心 DIRECT 出站靠系统真实
        // 默认路由走物理网卡，不回环（早期「8 段子网」方案已被推翻）。
        let ipv4 = NEIPv4Settings(addresses: [MihomoConfig.tunGatewayIP],
                                  subnetMasks: [MihomoConfig.tunSubnetMask])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        // DNS：指向 mihomo 的隧道 DNS 网关，matchDomains=[""] 强制所有查询进 tunnel
        let dns = NEDNSSettings(servers: [MihomoConfig.dnsServerIP])
        dns.matchDomains = [""]
        dns.matchDomainsNoSearch = true
        settings.dnsSettings = dns

        if let configuredMTU {
            settings.mtu = NSNumber(value: configuredMTU)
        } else {
            // mtu 为 nil 时，iOS 会用物理接口 MTU 减去该开销计算 utun MTU。
            settings.tunnelOverheadBytes = NSNumber(value: 0)
        }
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
    private func findTunnelFileDescriptor(named wantName: String) -> Int32? {
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

    /// 用 getifaddrs 找到绑定了网关 IP 的 utun，并从 AF_LINK 记录读取 iOS 实际 MTU。
    private func tunnelInterfaceInfo() -> (name: String, mtu: Int?)? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var targetName: String?
        var interfaceMTUs: [String: Int] = [:]
        var cursor = ifaddrPtr
        while let cur = cursor {
            let ifa = cur.pointee
            cursor = ifa.ifa_next
            guard let sa = ifa.ifa_addr else { continue }

            let ifName = String(cString: ifa.ifa_name)
            guard ifName.hasPrefix("utun") else { continue }

            if sa.pointee.sa_family == sa_family_t(AF_LINK),
               let data = ifa.ifa_data {
                let linkData = data.assumingMemoryBound(to: if_data.self).pointee
                let mtu = Int(linkData.ifi_mtu)
                if mtu > 0 {
                    interfaceMTUs[ifName] = mtu
                }
                continue
            }

            guard sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var sin = sockaddr_in()
            memcpy(&sin, sa, Int(MemoryLayout<sockaddr_in>.size))
            let ip = String(cString: inet_ntoa(sin.sin_addr))
            if ip == MihomoConfig.tunGatewayIP {
                targetName = ifName
            }
        }
        guard let targetName else {
            log.error("getifaddrs 未找到 IP=\(MihomoConfig.tunGatewayIP, privacy: .public) 的 utun 接口")
            return nil
        }
        return (targetName, interfaceMTUs[targetName])
    }

    private static func validateGeoAssets(configYAML: String,
                                          settingsJSON: String,
                                          home: String) -> NSError? {
        let data = settingsJSON.data(using: .utf8) ?? Data()
        let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let geoEnabled = (settings["geoEnabled"] as? Bool) ?? true
        let geodataMode = (settings["geodataMode"] as? Bool) ?? true
        var required = geoEnabled
            ? [geodataMode ? "GeoIP.dat" : "geoip.metadb", "GeoSite.dat"]
            : []
        let resolvedJSON = MihomoResolveGeoDownloadURLs(configYAML, settingsJSON)
        if let resolvedData = resolvedJSON.data(using: .utf8),
           let resolved = (try? JSONSerialization.jsonObject(with: resolvedData)) as? [String: Any],
           (resolved["asnRequired"] as? Bool) == true {
            required.append("ASN.mmdb")
        }
        guard !required.isEmpty else { return nil }
        let missing = required.filter { name in
            let path = (home as NSString).appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return ((attributes?[.size] as? NSNumber)?.int64Value ?? 0) < 1_024
        }
        guard !missing.isEmpty else { return nil }
        return NSError(
            domain: "MiClashTunnel",
            code: -4,
            userInfo: [NSLocalizedDescriptionKey:
                "缺少 GEO / ASN 数据文件：\(missing.joined(separator: "、"))。请在主 App 设置中下载后重试。"]
        )
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
