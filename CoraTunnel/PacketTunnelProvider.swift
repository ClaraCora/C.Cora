import NetworkExtension
import Mihomo // gomobile 生成的 mihomo 内核框架（含 with_gvisor）
import Network
import Darwin
import os.log
import WidgetKit

private let tunnelMaximumGeoAssetBytes: Int64 = 64 * 1_024 * 1_024
private let minimumHotReloadAvailableMemory: UInt64 = 28 * 1_024 * 1_024

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

    private let log = Logger(subsystem: "com.cora.app.tunnel", category: "PacketTunnel")

    /// 当前 mihomo 工作目录（含 run.log）。供 handleAppMessage 回传内核日志用。
    private var homeDir: String?

    /// 当前运行中的 utun fd。配置重载只复用它，不重建系统隧道。
    private var tunnelFileDescriptor: Int32?
    private var tunnelMTU: Int?
    private var configuredTunnelMTU: Int?
    private var configuredIPv6: Bool?
    private var isStopping = false
    private struct ReloadJob {
        enum Phase: String {
            case queued
            case running
            case succeeded
            case failed
        }

        let token: String
        var phase: Phase
        var error: String?
        var updatedAt: TimeInterval
    }

    private let reloadQueue = DispatchQueue(label: "com.cora.tunnel.reload", qos: .userInitiated)
    private let reloadStateLock = NSLock()
    private var reloadJob: ReloadJob?
    private let ipcQueue = DispatchQueue(label: "com.cora.tunnel.ipc",
                                         qos: .userInitiated,
                                         attributes: .concurrent)
    private var trollStoreIPCServer: TrollStoreFileIPCServer?
    private let memoryDiagnostics = MemoryDiagnostics()

    /// 隧道建立前抓取的物理网络 DNS，供配置里的 `system` nameserver 替换用。
    private var systemDNSServers: [String] = []
    private let systemDNSLock = NSLock()

    /// 把抓取到的系统 DNS 注入 settings JSON（key: systemDNS），
    /// Go 侧 mergeConfig 据此把 DNS 配置里的 "system" 替换为实际 IP。无可用值时原样返回。
    private func injectingSystemDNS(into settingsJSON: String) -> String {
        let servers = currentSystemDNSServers()
        guard !servers.isEmpty else { return settingsJSON }
        var dict = ((try? JSONSerialization.jsonObject(with: Data(settingsJSON.utf8)))
                    as? [String: Any]) ?? [:]
        dict["systemDNS"] = servers
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return settingsJSON }
        return json
    }

    private func currentSystemDNSServers() -> [String] {
        systemDNSLock.lock()
        defer { systemDNSLock.unlock() }
        return systemDNSServers
    }

    private func replaceSystemDNSServers(_ servers: [String]) {
        systemDNSLock.lock()
        systemDNSServers = servers
        systemDNSLock.unlock()
    }

    @discardableResult
    private func updateSystemDNSServers(_ servers: [String]) -> Bool {
        guard !servers.isEmpty else { return false }
        systemDNSLock.lock()
        defer { systemDNSLock.unlock() }
        // dns_configuration_copy 的 resolver 顺序偶尔会抖动；相同地址集合不算 DNS 变化。
        guard Set(servers) != Set(systemDNSServers) else { return false }
        systemDNSServers = servers
        return true
    }

    // 物理接口监控：把真实出站接口（en0/pdp_ip0）显式喂给内核，取代 mihomo 自带的不可靠监控。
    private struct PhysicalPathSnapshot {
        let interfaceName: String
        let addresses: Set<String>
        let supportsIPv4: Bool
        let supportsIPv6: Bool
    }

    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.cora.tunnel.pathmonitor", qos: .utility)
    private var pendingPathUpdate: DispatchWorkItem?
    private var lastPhysicalPath: PhysicalPathSnapshot?
    private var hasAppliedPhysicalPath = false
    private var lastPathWasSatisfied: Bool?

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        reloadQueue.sync {
            isStopping = false
            tunnelFileDescriptor = nil
            tunnelMTU = nil
            configuredTunnelMTU = nil
            configuredIPv6 = nil
        }
        reloadStateLock.lock()
        reloadJob = nil
        reloadStateLock.unlock()
        stopTrollStoreIPC()
        // 每次启动清空 ne.log，避免历史残留干扰排查
        // 隧道建立前先抓物理网络 DNS；隧道起来后系统主解析器会变成隧道自己的 DNS。
        FileLog.reset()
        let initialSystemDNS = SystemDNS.excludingTunnel(SystemDNS.currentServers())
        replaceSystemDNSServers(initialSystemDNS)
        FileLog.write("system DNS = \(initialSystemDNS)")
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
        startTrollStoreIPCIfNeeded()

        let configYAML = resolveConfig(incoming: incomingConfig,
                                       hasOption: hasConfigOption, home: home)
        var resolvedSettings = injectingSystemDNS(into:
            resolveCached(incoming: settingsJSON.isEmpty ? nil : settingsJSON,
                          home: home, file: "settings.json") ?? "")
        if sharedHome == nil {
            resolvedSettings = Self.disablingGeo(in: resolvedSettings)
        }

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
        let ipv6Enabled = Self.ipv6Enabled(settingsJSON: resolvedSettings)
        FileLog.write(configuredMTU.map { "MTU 使用配置值：\($0)" }
            ?? "配置未设置 tun.mtu，由 iOS 选择系统 MTU")

        let networkSettings = makeNetworkSettings(configuredMTU: configuredMTU,
                                                  ipv6Enabled: ipv6Enabled)
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
                completionHandler(NSError(domain: "CoraTunnel", code: -1,
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
                    domain: "CoraTunnel",
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
            self.memoryDiagnostics.start(directoryPath: home)
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
                    self.configuredIPv6 = ipv6Enabled
                    AppGroupState.vpnConnected = true // 共享给控制中心磁贴显示
                    if #available(iOS 18.0, *) {
                        ControlCenter.shared.reloadControls(ofKind: ControlWidgetKind.vpn)
                    }
                    self.startPathMonitor() // 开始把真实出站接口喂给内核
                }
                return ok
            }
            guard let startResult else {
                self.memoryDiagnostics.stop(event: "startCancelled")
                completionHandler(NSError(
                    domain: "CoraTunnel",
                    code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "VPN 启动已取消"]))
                return
            }
            guard startResult else {
                self.memoryDiagnostics.stop(event: "startFailed")
                let error = startError ?? NSError(domain: "CoraTunnel", code: -3,
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
                    domain: "CoraTunnel",
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
        stopTrollStoreIPC()
        reloadQueue.sync {
            isStopping = true
            tunnelFileDescriptor = nil
            tunnelMTU = nil
            configuredTunnelMTU = nil
            configuredIPv6 = nil
            AppGroupState.vpnConnected = false // 同步给控制中心磁贴
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: ControlWidgetKind.vpn)
            }
            stopPathMonitor()
            memoryDiagnostics.stop(event: "stop")
            MihomoStop()
        }
        completionHandler()
    }

    private func startTrollStoreIPCIfNeeded() {
        guard TrollStoreIPC.isEnabled else { return }
        let server = TrollStoreFileIPCServer { [weak self] request, reply in
            guard let self else {
                reply(nil)
                return
            }
            self.handleAppMessage(request, completionHandler: reply)
        }
        guard server.start() else {
            FileLog.write("TrollStore 文件 IPC 启动失败：共享控制目录不可用")
            return
        }
        trollStoreIPCServer = server
        FileLog.write("TrollStore 文件 IPC 已启动")
    }

    private func stopTrollStoreIPC() {
        trollStoreIPCServer?.stop()
        trollStoreIPCServer = nil
    }

    // MARK: - 物理接口监控

    /// 监控网络路径，把真实出站接口名喂给 mihomo（取代其自带的 iOS 下不可靠的接口监控）。
    /// 出站绑对物理网卡才不会被默认路由兜回 tun → 这是吞吐能跑满的关键。
    private func startPathMonitor() {
        pathMonitorQueue.async { [weak self] in
            guard let self else { return }
            self.stopPathMonitorLocked()
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                self?.schedulePathUpdate(path)
            }
            monitor.start(queue: self.pathMonitorQueue)
            self.pathMonitor = monitor
        }
    }

    private func stopPathMonitor() {
        pathMonitorQueue.sync { stopPathMonitorLocked() }
    }

    private func stopPathMonitorLocked() {
        pendingPathUpdate?.cancel()
        pendingPathUpdate = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPhysicalPath = nil
        hasAppliedPhysicalPath = false
        lastPathWasSatisfied = nil
    }

    /// 首次立即应用（缩短启动时「出站未绑接口」的窗口）；之后变化用防抖。
    private func schedulePathUpdate(_ path: Network.NWPath) {
        pendingPathUpdate?.cancel()
        if !hasAppliedPhysicalPath {
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
        guard path.status == .satisfied else {
            if lastPathWasSatisfied != false {
                FileLog.write("物理网络路径暂时不可用，等待恢复")
            }
            lastPathWasSatisfied = false
            return
        }

        guard let iface = activePhysicalInterface(from: path) else {
            if lastPathWasSatisfied != false {
                FileLog.write("物理网络已满足，但未找到实际使用的接口，等待下一次路径更新")
            }
            lastPathWasSatisfied = false
            return
        }

        let previous = lastPhysicalPath
        let isInitialPath = !hasAppliedPhysicalPath
        let wasUnavailable = lastPathWasSatisfied == false
        let sampledAddresses = Set(SystemDNS.interfaceAddresses(for: iface.name))
        let addresses = stabilizedAddresses(
            sampledAddresses, previous: previous, path: path)
        let snapshot = PhysicalPathSnapshot(
            interfaceName: iface.name,
            addresses: addresses,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6)

        let scopedDNS = SystemDNS.excludingTunnel(
            SystemDNS.scopedServers(for: iface.name))
        let dnsChanged = updateSystemDNSServers(scopedDNS)
        if dnsChanged {
            FileLog.write("物理接口 \(iface.name) scoped DNS = \(scopedDNS)")
        } else if scopedDNS.isEmpty && (isInitialPath || wasUnavailable) {
            FileLog.write("物理接口 \(iface.name) 未读取到 scoped DNS，沿用现有 system DNS")
        }

        lastPhysicalPath = snapshot
        lastPathWasSatisfied = true
        hasAppliedPhysicalPath = true

        if isInitialPath {
            FileLog.write("初始出站接口 = \(iface.name)")
            // 内核启动与首个 NWPath 回调之间可能已经建立了 DNS/健康检查连接；
            // 首次也执行完整刷新，避免这些连接留在未绑定或错误接口上。
            notifyNetworkChange(
                interfaceName: iface.name,
                reason: "初始物理路径",
                resetConnections: true)
            return
        }

        var reasons: [String] = []
        var resetConnections = false
        if previous?.interfaceName != iface.name {
            reasons.append("出站接口变化")
            resetConnections = true
        }
        if wasUnavailable {
            reasons.append("网络路径恢复")
            resetConnections = true
        }
        if let previous,
           addressFamilyWasReplaced(previous.addresses, snapshot.addresses) {
            reasons.append("接口地址变化")
            resetConnections = true
        }
        if let previous,
           previous.supportsIPv4 != snapshot.supportsIPv4 ||
           previous.supportsIPv6 != snapshot.supportsIPv6 {
            reasons.append("IP 协议可用性变化")
            resetConnections = true
        }
        if dnsChanged {
            reasons.append("system DNS 变化")
        }

        // NWPathMonitor 也会为 expensive/constrained 等无关属性发回调。
        // 没有上述有效差异时不通知内核，更不能关闭仍然可用的连接。
        guard !reasons.isEmpty else { return }
        let reason = reasons.joined(separator: "、")
        FileLog.write(resetConnections
            ? "物理网络需要刷新：\(reason)"
            : "物理网络 DNS 刷新：\(reason)，保留活动连接")
        notifyNetworkChange(
            interfaceName: iface.name,
            reason: reason,
            resetConnections: resetConnections)
    }

    private func stabilizedAddresses(
        _ sampled: Set<String>,
        previous: PhysicalPathSnapshot?,
        path: Network.NWPath
    ) -> Set<String> {
        guard let previous else { return sampled }
        var result = sampled
        let sampledIPv4 = sampled.filter { !$0.contains(":") }
        let sampledIPv6 = sampled.filter { $0.contains(":") }
        // getifaddrs 与 NWPath 更新不是原子的。短暂读空时沿用该地址族的上一份值，
        // 避免先把基线清空、随后又漏掉真正的地址替换。
        if path.supportsIPv4 && sampledIPv4.isEmpty {
            result.formUnion(previous.addresses.filter { !$0.contains(":") })
        }
        if path.supportsIPv6 && sampledIPv6.isEmpty {
            result.formUnion(previous.addresses.filter { $0.contains(":") })
        }
        return result
    }

    private func addressFamilyWasReplaced(
        _ previous: Set<String>, _ current: Set<String>
    ) -> Bool {
        for isIPv6 in [false, true] {
            let oldFamily = Set(previous.filter { $0.contains(":") == isIPv6 })
            let newFamily = Set(current.filter { $0.contains(":") == isIPv6 })
            if !oldFamily.isEmpty && !newFamily.isEmpty && oldFamily.isDisjoint(with: newFamily) {
                return true
            }
        }
        return false
    }

    private func notifyNetworkChange(
        interfaceName: String,
        reason: String,
        resetConnections: Bool
    ) {
        let servers = currentSystemDNSServers()
        let data = try? JSONSerialization.data(withJSONObject: servers)
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var updateError: NSError?
        let ok = MihomoNotifyNetworkChange(
            interfaceName, json, reason, resetConnections, &updateError)
        if !ok {
            FileLog.write("刷新物理接口/DNS 失败："
                + (updateError?.localizedDescription ?? "未知错误"))
        }
    }

    /// `availableInterfaces` 可能同时包含 Wi-Fi、蜂窝和 utun；只选择当前 path 实际使用的
    /// 物理类型，避免蜂窝切换后仍把新拨号绑定到已不在路径上的 en0。
    private func activePhysicalInterface(from path: Network.NWPath) -> NWInterface? {
        let preferredTypes: [NWInterface.InterfaceType] = [
            .wifi, .cellular, .wiredEthernet
        ]
        for type in preferredTypes where path.usesInterfaceType(type) {
            if let interface = path.availableInterfaces.first(where: { $0.type == type }) {
                return interface
            }
        }
        return nil
    }

    /// 主 App 经系统 IPC 或 TrollStore 文件 IPC 发来的统一控制请求。
    /// JSON 命令协议：{"v":1,"cmd":"hello"|"queryProxies"|"connections"|...}。
    /// 关键：completionHandler 必须**非 nil 回调**，否则主 App 侧 resp 为 nil。
    override func handleAppMessage(_ messageData: Data,
                                  completionHandler: ((Data?) -> Void)?) {
        let obj = (try? JSONSerialization.jsonObject(with: messageData)) as? [String: Any]
        let cmd = (obj?["cmd"] as? String) ?? String(data: messageData, encoding: .utf8) ?? ""
        let protocolVersion = (obj?["v"] as? NSNumber)?.intValue
        if let protocolVersion, protocolVersion != 1 {
            completionHandler?(Self.jsonData([
                "ok": false,
                "error": "不支持的控制协议版本：\(protocolVersion)",
                "supportedVersion": 1,
            ]))
            return
        }
        if cmd != "traffic" && cmd != "memory" {
            FileLog.write("handleAppMessage：cmd=\(cmd)")
        }

        switch cmd {
        case "hello":
            completionHandler?(Data(MihomoControlInfo().utf8))
        case "queryProxies":
            ipcQueue.async {
                completionHandler?(Data(MihomoQueryProxies().utf8))
            }
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
            let timeout = (obj?["timeout"] as? NSNumber)?.intValue ?? 5000
            ipcQueue.async {
                completionHandler?(Data(MihomoGroupDelay(group, url, timeout).utf8))
            }
        case "connections":
            let limit = (obj?["limit"] as? NSNumber)?.intValue ?? 200
            ipcQueue.async {
                completionHandler?(Data(MihomoConnectionsSnapshot(limit).utf8))
            }
        case "closeConnection":
            let id = (obj?["id"] as? String) ?? ""
            var error: NSError?
            let ok = MihomoCloseConnection(id, &error)
            completionHandler?(Self.jsonData(ok
                ? ["ok": true]
                : ["ok": false, "error": error?.localizedDescription ?? "未知错误"]))
        case "closeAllConnections":
            completionHandler?(Self.jsonData([
                "ok": true,
                "closed": Int(MihomoCloseAllConnections()),
            ]))
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
        case "reloadStatus":
            completionHandler?(reloadStatusResponse(token: obj?["token"] as? String))
        case "runLogChunk":
            let offset = (obj?["offset"] as? NSNumber)?.intValue ?? -1
            let generation = (obj?["generation"] as? NSNumber)?.intValue ?? 0
            ipcQueue.async {
                completionHandler?(Data(MihomoRunLogChunk(offset, generation).utf8))
            }
        case "getLogs":
            // 日志可能很大，IPC 响应有体积上限 → 只回传末尾约 24KB，取最新内容。
            let body = "[cmd=\(cmd)]\n" + collectLogs()
            completionHandler?(Self.tailData(body, maxBytes: 24 * 1024))
        default:
            completionHandler?(Self.jsonData([
                "ok": false,
                "error": "未知控制命令：\(cmd)",
            ]))
        }
    }

    private static func jsonData(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"ok":false}"#.utf8)
    }

    private func reloadConfiguration(_ object: [String: Any]?,
                                     completionHandler: ((Data?) -> Void)?) {
        let transfer = object?["transfer"] as? String
        let token = (object?["token"] as? String).flatMap {
            UUID(uuidString: $0) == nil ? nil : $0
        } ?? UUID().uuidString
        let inlineConfig = object?["config"] as? String
        let inlineSettings = object?["settings"] as? String

        if let activeToken = beginReload(token: token) {
            completionHandler?(Self.reloadResponse(
                error: "已有配置正在重载",
                code: "reloadInProgress",
                token: activeToken))
            return
        }

        let runtime: (fd: Int32, mtu: Int, home: String)?
        runtime = reloadQueue.sync {
            guard !isStopping,
                  let fd = tunnelFileDescriptor,
                  let mtu = tunnelMTU,
                  let home = homeDir else { return nil }
            return (fd, mtu, home)
        }
        guard let runtime else {
            finishReload(token: token, phase: .failed, error: "VPN 尚未完成启动")
            completionHandler?(Self.reloadResponse(error: "VPN 尚未完成启动", token: token))
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
            let message = error.localizedDescription
            FileLog.write("读取重载配置失败：\(message)")
            finishReload(token: token, phase: .failed, error: message)
            completionHandler?(Self.reloadResponse(
                error: message,
                code: (error as? ReloadInputError)?.responseCode,
                token: token))
            return
        }

        // 先回受理结果，再执行耗时的 ParseRawConfig/ApplyConfig。状态查询完全在 Swift
        // 内完成，不会被 Go 侧 configApplyMu 或大配置解析阻塞。
        completionHandler?(Self.reloadResponse(accepted: true, token: token))
        reloadQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.finishReload(token: token, phase: .running)

            let configYAML = input.config.isEmpty
                ? MihomoConfig.directModeYAML()
                : input.config
            let effectiveSettings = AppGroup.containerURL == nil
                ? Self.disablingGeo(in: input.settings)
                : input.settings
            let requestedMTUValue = Int(MihomoConfiguredTunMTU(configYAML))
            let requestedMTU: Int? = requestedMTUValue > 0 ? requestedMTUValue : nil
            guard requestedMTU == self.configuredTunnelMTU else {
                let oldValue = self.configuredTunnelMTU.map(String.init) ?? "系统"
                let newValue = requestedMTU.map(String.init) ?? "系统"
                let message = "tun.mtu 从 \(oldValue) 变为 \(newValue)，请断开并重新连接后生效"
                FileLog.write("拒绝热重载：\(message)")
                self.finishReload(token: token, phase: .failed, error: message)
                return
            }
            let requestedIPv6 = Self.ipv6Enabled(settingsJSON: effectiveSettings)
            guard requestedIPv6 == self.configuredIPv6 else {
                let message = "IPv6 设置发生变化，请断开并重新连接后生效"
                FileLog.write("拒绝热重载：\(message)")
                self.finishReload(token: token, phase: .failed, error: message)
                return
            }
            if let geoError = Self.validateGeoAssets(configYAML: configYAML,
                                                      settingsJSON: effectiveSettings,
                                                      home: runtime.home) {
                let message = geoError.localizedDescription
                FileLog.write("重载前 GEO / ASN 数据检查失败：\(message)")
                self.finishReload(token: token, phase: .failed, error: message)
                return
            }

            let injectedSettings = self.injectingSystemDNS(into: effectiveSettings)
            var prepareError: NSError?
            let prepared = MihomoPrepareReload(runtime.mtu, configYAML,
                                               injectedSettings, &prepareError)
            guard prepared else {
                let message = prepareError?.localizedDescription ?? "mihomo 热重载准备失败"
                FileLog.write("准备热重载失败：\(message)")
                self.finishReload(token: token, phase: .failed, error: message)
                return
            }
            guard MihomoReloadPrepared() else {
                FileLog.write("配置与 GEO 文件均未变化，跳过热重载")
                self.finishReload(token: token, phase: .succeeded)
                return
            }

            self.memoryDiagnostics.record(event: "reloadPrepared")
            // Close() removes trackers synchronously, but their socket/provider
            // goroutines finish asynchronously. Let those stacks unwind before
            // allocating RawConfig and the replacement runtime together.
            Thread.sleep(forTimeInterval: 0.5)
            MihomoForceGC()
            Thread.sleep(forTimeInterval: 0.15)
            self.memoryDiagnostics.record(event: "reloadDrained")

            let availableMemory = UInt64(os_proc_available_memory())
            guard availableMemory >= minimumHotReloadAvailableMemory else {
                MihomoCancelReload()
                self.memoryDiagnostics.record(event: "reloadCancelledLowMemory")
                let availableMiB = availableMemory / (1_024 * 1_024)
                let message = "热重载可用内存仅 \(availableMiB) MB，已保留旧配置和 VPN 连接"
                FileLog.write(message)
                self.finishReload(token: token, phase: .failed, error: message)
                return
            }

            FileLog.write("调用 MihomoReloadConfig（config=\(configYAML.count) 字节）…")
            self.memoryDiagnostics.record(event: "reloadBefore")
            var reloadError: NSError?
            let ok = MihomoReloadConfig(Int(runtime.fd), runtime.mtu, configYAML,
                                        injectedSettings,
                                        &reloadError)
            self.memoryDiagnostics.record(event: ok ? "reloadAfter" : "reloadFailed")
            guard ok else {
                let message = reloadError?.localizedDescription ?? "mihomo 重载失败（未知错误）"
                FileLog.write("MihomoReloadConfig 失败：\(message)")
                self.finishReload(token: token, phase: .failed, error: message)
                return
            }

            // 只有应用成功才更新系统重连使用的缓存，避免坏配置污染下一次启动。
            let configPath = (runtime.home as NSString).appendingPathComponent("config.yaml")
            let settingsPath = (runtime.home as NSString).appendingPathComponent("settings.json")
            do {
                try configYAML.write(toFile: configPath, atomically: true, encoding: .utf8)
                try effectiveSettings.write(toFile: settingsPath, atomically: true, encoding: .utf8)
            } catch {
                FileLog.write("配置已重载，但更新重连缓存失败：\(error.localizedDescription)")
            }
            FileLog.write("配置重载成功")
            self.finishReload(token: token, phase: .succeeded)
        }
    }

    /// 返回正在执行的 token；nil 表示当前请求已成功占用重载槽位。
    private func beginReload(token: String) -> String? {
        reloadStateLock.lock()
        defer { reloadStateLock.unlock() }
        if let job = reloadJob, job.phase == .queued || job.phase == .running {
            return job.token
        }
        reloadJob = ReloadJob(token: token,
                              phase: .queued,
                              error: nil,
                              updatedAt: Date().timeIntervalSince1970)
        return nil
    }

    private func finishReload(token: String, phase: ReloadJob.Phase, error: String? = nil) {
        reloadStateLock.lock()
        defer { reloadStateLock.unlock() }
        guard reloadJob?.token == token else { return }
        reloadJob?.phase = phase
        reloadJob?.error = error
        reloadJob?.updatedAt = Date().timeIntervalSince1970
    }

    private func reloadStatusResponse(token: String?) -> Data {
        reloadStateLock.lock()
        let job = reloadJob
        reloadStateLock.unlock()

        guard let token, let job, job.token == token else {
            return Self.reloadResponse(error: "没有找到该重载任务",
                                       code: "reloadNotFound",
                                       token: token)
        }
        var response: [String: Any] = [
            "ok": true,
            "token": job.token,
            "status": job.phase.rawValue,
            "updatedAt": job.updatedAt,
        ]
        if let error = job.error { response["error"] = error }
        return Self.jsonData(response)
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

    private static func reloadResponse(error: String? = nil,
                                       code: String? = nil,
                                       accepted: Bool = false,
                                       token: String? = nil) -> Data {
        var response: [String: Any] = ["ok": error == nil]
        if let error { response["error"] = error }
        if let code { response["code"] = code }
        if accepted { response["accepted"] = true }
        if let token { response["token"] = token }
        return jsonData(response)
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
        let footprint = MemoryDiagnostics.physicalFootprint()
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

    /// 汇总 NE 步骤日志、mihomo 日志和持久化内存诊断。
    private func collectLogs() -> String {
        var out = "===== ne（NE 启动步骤，内存）=====\n" + FileLog.dump()
        if let home = homeDir {
            let runPath = (home as NSString).appendingPathComponent("run.log")
            let run = Self.tailTextFile(runPath, maxBytes: 10 * 1024) ?? "(run.log 不存在)"
            out += "\n\n===== run.log（mihomo 内核）=====\n" + (run.isEmpty ? "(空)" : run)

            let previousPath = (home as NSString)
                .appendingPathComponent("memory-diagnostic.previous.ndjson")
            let currentPath = (home as NSString)
                .appendingPathComponent("memory-diagnostic.ndjson")
            let previous = Self.tailTextFile(previousPath, maxBytes: 4 * 1024) ?? "(不存在)"
            let current = Self.tailTextFile(currentPath, maxBytes: 6 * 1024) ?? "(不存在)"
            out += "\n\n===== memory diagnostic（上一段）=====\n" + previous
            out += "\n\n===== memory diagnostic（当前段）=====\n" + current
        } else {
            out += "\n\n(home 未设置，mihomo 尚未启动)"
        }
        return out
    }

    /// 只读取文件末尾，避免 getLogs 本身因读取大日志造成额外内存峰值。
    private static func tailTextFile(_ path: String, maxBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let offset = size > maxBytes ? size - maxBytes : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    // MARK: - 网络设置

    /// 构建隧道网络设置。地址与 mihomo 配置严格对齐（198.18.0.x）。
    private func makeNetworkSettings(configuredMTU: Int?,
                                     ipv6Enabled: Bool) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: MihomoConfig.tunGatewayIP)

        // IPv4：网关 198.18.0.1/16，默认路由全量接管。
        // 注：字面默认路由 0.0.0.0/0 经真机验证可用——核心 DIRECT 出站靠系统真实
        // 默认路由走物理网卡，不回环（早期「8 段子网」方案已被推翻）。
        let ipv4 = NEIPv4Settings(addresses: [MihomoConfig.tunGatewayIP],
                                  subnetMasks: [MihomoConfig.tunSubnetMask])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        if ipv6Enabled {
            let ipv6 = NEIPv6Settings(
                addresses: ["fdfe:dcba:9876::1"],
                networkPrefixLengths: [126])
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
        }

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
        var required: [String] = []
        let resolvedJSON = MihomoResolveGeoDownloadURLs(configYAML, settingsJSON)
        if let resolvedData = resolvedJSON.data(using: .utf8),
           let resolved = (try? JSONSerialization.jsonObject(with: resolvedData)) as? [String: Any] {
            if geoEnabled, (resolved["geoRequired"] as? Bool) == true {
                required.append(contentsOf: [
                    geodataMode ? "GeoIP.dat" : "geoip.metadb",
                    "GeoSite.dat"
                ])
            }
            if geoEnabled, (resolved["asnRequired"] as? Bool) == true {
                required.append("ASN.mmdb")
            }
        }
        guard !required.isEmpty else { return nil }
        let sizes = Dictionary(uniqueKeysWithValues: required.map { name in
            let path = (home as NSString).appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return (name, (attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        })
        let missing = required.filter { (sizes[$0] ?? 0) < 1_024 }
        if !missing.isEmpty {
            return NSError(
                domain: "CoraTunnel",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey:
                    "缺少 GEO / ASN 数据文件：\(missing.joined(separator: "、"))。请在主 App 设置中下载后重试。"]
            )
        }
        let oversized = required.filter { (sizes[$0] ?? 0) > tunnelMaximumGeoAssetBytes }
        guard oversized.isEmpty else {
            return NSError(
                domain: "CoraTunnel",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey:
                    "GEO / ASN 数据文件超过 64 MB 上限：\(oversized.joined(separator: "、"))"]
            )
        }
        return nil
    }

    private static func ipv6Enabled(settingsJSON: String) -> Bool {
        guard let data = settingsJSON.data(using: .utf8),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return settings["ipv6"] as? Bool ?? false
    }

    private static func disablingGeo(in settingsJSON: String) -> String {
        let data = settingsJSON.data(using: .utf8) ?? Data()
        var settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        settings["geoEnabled"] = false
        guard let encoded = try? JSONSerialization.data(withJSONObject: settings),
              let result = String(data: encoded, encoding: .utf8) else { return settingsJSON }
        return result
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
