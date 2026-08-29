import NetworkExtension
import Mihomo // gomobile 生成的 mihomo 内核框架（含 with_gvisor）
import Network
import Darwin
import os.log
import WidgetKit

private let tunnelMaximumGeoAssetBytes: Int64 = 64 * 1_024 * 1_024

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

    /// 当前运行中的 utun fd，用于确认异步启动结果仍有效。
    private var tunnelFileDescriptor: Int32?
    private var isStopping = false
    private let runtimeQueue = DispatchQueue(label: "com.cora.tunnel.runtime", qos: .userInitiated)
    private let ipcQueue = DispatchQueue(label: "com.cora.tunnel.ipc",
                                         qos: .userInitiated,
                                         attributes: .concurrent)
    private struct StoredIPCResponse {
        let data: Data
        let expiresAt: Date
    }
    private let ipcResponseLock = NSLock()
    private var storedIPCResponses: [String: StoredIPCResponse] = [:]
    private var storedIPCResponseBytes = 0
    private var ipcResponseCachingEnabled = true
    // Async IPC work can finish after stopTunnel and even after a new tunnel
    // session starts. Responses are tied to this generation so an old task
    // cannot populate the new session's chunk cache.
    private var ipcSessionGeneration: UInt64 = 0
    private var ipcResponseCleanupWorkItem: DispatchWorkItem?
    private static let ipcInlineResponseLimit = 16 * 1_024
    private static let ipcResponseChunkSize = 12 * 1_024
    private static let ipcMaximumResponseSize = 8 * 1_024 * 1_024
    // A chunked response is only a short-lived hand-off to the App. Keep the
    // aggregate budget bounded when a caller disappears before fetching it.
    private static let ipcMaximumStoredResponseBytes = 8 * 1_024 * 1_024
    private static let ipcMaximumStoredResponses = 2
    private static let ipcResponseLifetime: TimeInterval = 30
    private var trollStoreIPCServer: TrollStoreFileIPCServer?
    /// 仅在开发者模式开启时创建，普通 VPN 会话不持有诊断定时器、压力监听或文件句柄。
    private var memoryDiagnostics: MemoryDiagnostics?
    /// 普通模式只保留这个无状态的压力响应器，不采样、不写诊断文件。
    private var memoryPressureGuard: MemoryPressureGuard?
    private var developerModeEnabled = false
    // Observability is kept outside the packet data path. The recorder writes
    // bounded rows to the App Group SQLite file.
    private let connectionHistoryRecorder = ConnectionHistoryRecorder()

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

    private func systemDNSServersDiffer(from servers: [String]) -> Bool {
        guard !servers.isEmpty else { return false }
        systemDNSLock.lock()
        defer { systemDNSLock.unlock() }
        // dns_configuration_copy 的 resolver 顺序偶尔会抖动；相同地址集合不算 DNS 变化。
        return Set(servers) != Set(systemDNSServers)
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
    // All path state is serialized on pathMonitorQueue. Keeping the latest
    // observation prevents a DNS retry from reusing an interface snapshot
    // that became stale while the backoff timer was pending.
    private var latestObservedPath: Network.NWPath?
    private var lastPhysicalPath: PhysicalPathSnapshot?
    private var hasAppliedPhysicalPath = false
    private var lastPathWasSatisfied: Bool?
    private var systemDNSRetrySignature: String?
    private var systemDNSRetryAttempt = 0
    private static let systemDNSRetryDelays: [TimeInterval] = [2, 5, 10]

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        runtimeQueue.sync {
            isStopping = false
            tunnelFileDescriptor = nil
        }
        stopTrollStoreIPC()
        clearStoredIPCResponses(enableCaching: true)
        // 每次启动只清空进程内缓冲；FileLog 会把上一会话的持久化日志轮换为
        // ne.previous.log，避免 NE 被系统停止后事故现场被新会话覆盖。
        // 隧道建立前先抓物理网络 DNS；隧道起来后系统主解析器会变成隧道自己的 DNS。
        FileLog.reset()
        let startupAttemptID = (options?["startupAttemptID"] as? String) ?? UUID().uuidString
        FileLog.write("startup-attempt=\(startupAttemptID)")
        // 每次真正启动隧道都创建新的延迟会话；App 重新打开时可从该快照恢复。
        let delaySessionID = ProxyDelayStore.beginSession()
        FileLog.write("延迟测试会话已开始：\(delaySessionID)")
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
            let developerMode = Self.developerModeEnabled(
                settingsJSON: resolvedSettings,
                home: home,
                preferSettings: !settingsJSON.isEmpty)
            self.runtimeQueue.sync {
                self.configureMemoryDiagnostics(enabled: developerMode,
                                                 home: home,
                                                 persistState: !settingsJSON.isEmpty)
            }
            var startError: NSError?
            let startResult: Bool? = self.runtimeQueue.sync {
                guard !self.isStopping else { return nil }
                let ok = MihomoStartWithConfig(
                    Int(fd), actualMTU, configYAML, resolvedSettings, &startError)
                if ok {
                    FileLog.write("MihomoStartWithConfig 返回成功")
                    self.log.info("mihomo 启动成功")
                    self.tunnelFileDescriptor = fd
                    AppGroupState.vpnConnected = true // 共享给控制中心磁贴显示
                    if #available(iOS 18.0, *) {
                        ControlCenter.shared.reloadControls(ofKind: ControlWidgetKind.vpn)
                    }
                    self.connectionHistoryRecorder.start()
                    self.startPathMonitor() // 开始把真实出站接口喂给内核
                    if !developerMode, self.memoryPressureGuard == nil {
                        let guarder = MemoryPressureGuard()
                        guarder.start()
                        self.memoryPressureGuard = guarder
                    }
                    self.memoryDiagnostics?.record(event: "tunnelStarted")
                }
                return ok
            }
            guard let startResult else {
                self.runtimeQueue.sync {
                    self.memoryDiagnostics?.stop(event: "startCancelled")
                    self.memoryDiagnostics = nil
                    self.developerModeEnabled = false
                }
                completionHandler(NSError(
                    domain: "CoraTunnel",
                    code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "VPN 启动已取消"]))
                return
            }
            guard startResult else {
                self.runtimeQueue.sync {
                    self.memoryDiagnostics?.stop(event: "startFailed")
                    self.memoryDiagnostics = nil
                    self.developerModeEnabled = false
                }
                let error = startError ?? NSError(domain: "CoraTunnel", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "mihomo 启动失败（未知错误）"])
                FileLog.write("MihomoStartWithConfig 失败：\(error.localizedDescription)")
                self.log.error("mihomo 启动失败：\(error.localizedDescription, privacy: .public)")
                completionHandler(error)
                return
            }

            let stillRunning = self.runtimeQueue.sync {
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
        clearStoredIPCResponses(enableCaching: false)
        runtimeQueue.sync {
            isStopping = true
            tunnelFileDescriptor = nil
            AppGroupState.vpnConnected = false // 同步给控制中心磁贴
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: ControlWidgetKind.vpn)
            }
            stopPathMonitor()
            connectionHistoryRecorder.stop()
            memoryPressureGuard?.stop()
            memoryPressureGuard = nil
            memoryDiagnostics?.record(event: "tunnelStopping")
            memoryDiagnostics?.stop(event: "stop")
            memoryDiagnostics = nil
            developerModeEnabled = false
            MihomoStop()
            // 断开才清空延迟快照；App 进程退出或进入后台不会触发这里。
            ProxyDelayStore.clear()
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
        latestObservedPath = nil
        lastPhysicalPath = nil
        hasAppliedPhysicalPath = false
        lastPathWasSatisfied = nil
        resetSystemDNSRetryLocked()
    }

    /// 首次立即应用（缩短启动时「出站未绑接口」的窗口）；之后变化用防抖。
    private func schedulePathUpdate(_ path: Network.NWPath) {
        latestObservedPath = path
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
        FileLog.write(pathSummary(path))
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
        FileLog.write("物理接口选择 = \(iface.name)（\(Self.interfaceTypeName(iface.type))）")

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
        let candidateDNS = scopedDNS.isEmpty ? currentSystemDNSServers() : scopedDNS
        let dnsChanged = systemDNSServersDiffer(from: candidateDNS)
        if dnsChanged {
            FileLog.write("物理接口 \(iface.name) 候选 scoped DNS = \(candidateDNS)")
        } else if scopedDNS.isEmpty && (isInitialPath || wasUnavailable) {
            FileLog.write("物理接口 \(iface.name) 未读取到 scoped DNS，沿用现有 system DNS")
        } else {
            resetSystemDNSRetryLocked()
        }

        lastPhysicalPath = snapshot
        lastPathWasSatisfied = true
        hasAppliedPhysicalPath = true

        if isInitialPath {
            FileLog.write("初始出站接口 = \(iface.name)")
            // 内核启动与首个 NWPath 回调之间可能已经建立了 DNS/健康检查连接；
            // 首次也执行完整刷新，避免这些连接留在未绑定或错误接口上。
            let applied = notifyNetworkChange(
                interfaceName: iface.name,
                systemDNSServers: candidateDNS,
                reason: "初始物理路径",
                resetConnections: true)
            finishSystemDNSUpdate(applied: applied,
                                  changed: dnsChanged,
                                  candidate: candidateDNS,
                                  path: path)
            return
        }

        var reasons: [String] = []
        var resetConnections = false
        if previous?.interfaceName != iface.name {
            reasons.append("出站接口变化")
            resetConnections = true
        }
        // 路径短暂 unavailable 后恢复并不代表物理出口发生变化。CarPlay 切换
        // 期间 NWPath 可能短暂抖动；只有接口/地址族真正变化时才清理活动连接，
        // 避免无谓地关闭所有连接并制造新的 goroutine、socket 和内存峰值。
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
        let applied = notifyNetworkChange(
            interfaceName: iface.name,
            systemDNSServers: candidateDNS,
            reason: reason,
            resetConnections: resetConnections)
        finishSystemDNSUpdate(applied: applied,
                              changed: dnsChanged,
                              candidate: candidateDNS,
                              path: path)
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
        systemDNSServers servers: [String],
        reason: String,
        resetConnections: Bool
    ) -> Bool {
        let data = try? JSONSerialization.data(withJSONObject: servers)
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var updateError: NSError?
        let ok = MihomoNotifyNetworkChange(
            interfaceName, json, reason, resetConnections, &updateError)
        if !ok {
            FileLog.write("刷新物理接口/DNS 失败："
                + (updateError?.localizedDescription ?? "未知错误"))
        }
        return ok
    }

    /// DNS 候选值只在内核完成原子发布后才提交为已生效值。
    /// 失败时保留旧基线并做有限退避重试，避免临时内存或输入错误在 NE 内形成无限循环。
    private func finishSystemDNSUpdate(
        applied: Bool,
        changed: Bool,
        candidate: [String],
        path: Network.NWPath
    ) {
        guard changed else {
            if applied { resetSystemDNSRetryLocked() }
            return
        }
        if applied {
            replaceSystemDNSServers(candidate)
            resetSystemDNSRetryLocked()
            FileLog.write("system DNS 已提交为 \(candidate)")
        } else {
            scheduleSystemDNSRetryLocked(path: path, candidate: candidate)
        }
    }

    private func scheduleSystemDNSRetryLocked(path: Network.NWPath, candidate: [String]) {
        let signature = candidate.sorted().joined(separator: ",")
        if systemDNSRetrySignature != signature {
            systemDNSRetrySignature = signature
            systemDNSRetryAttempt = 0
        }
        guard systemDNSRetryAttempt < Self.systemDNSRetryDelays.count else {
            FileLog.write("system DNS 热更新已达重试上限，保留旧 DNS 等待下次网络变化")
            return
        }

        let delay = Self.systemDNSRetryDelays[systemDNSRetryAttempt]
        systemDNSRetryAttempt += 1
        let expectedSignature = signature
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPathUpdate = nil
            guard self.systemDNSRetrySignature == expectedSignature,
                  self.systemDNSServersDiffer(from: candidate) else {
                self.resetSystemDNSRetryLocked()
                return
            }
            FileLog.write("system DNS 热更新第 \(self.systemDNSRetryAttempt) 次重试")
            self.applyInterface(from: self.latestObservedPath ?? path)
        }
        pendingPathUpdate?.cancel()
        pendingPathUpdate = work
        pathMonitorQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func resetSystemDNSRetryLocked() {
        systemDNSRetrySignature = nil
        systemDNSRetryAttempt = 0
    }

    /// `availableInterfaces` 可能同时包含 Wi-Fi、蜂窝和 utun。无线 CarPlay 会
    /// 建立 Wi-Fi/P2P 链路，但互联网出口仍是蜂窝；当 NWPath 同时报告两者时，
    /// 蜂窝优先可以避免把 mihomo 出站错误绑定到 CarPlay 的 en0。普通家庭 Wi-Fi
    /// 路径通常不会把 cellular 标记为 usesInterfaceType，因此仍会选择 en0。
    private func activePhysicalInterface(from path: Network.NWPath) -> NWInterface? {
        let usesWiFi = path.usesInterfaceType(.wifi)
        let usesCellular = path.usesInterfaceType(.cellular)
        let preferredTypes: [NWInterface.InterfaceType]
        if usesWiFi && usesCellular {
            // 同时存在两条路径时，isExpensive 表示当前出口实际使用蜂窝。
            // 无线 CarPlay 常见于这一分支；普通家庭 Wi-Fi 通常不会同时 uses
            // cellular，因此不会误切到蜂窝流量。
            preferredTypes = path.isExpensive
                ? [.cellular, .wifi, .wiredEthernet]
                : [.wifi, .cellular, .wiredEthernet]
        } else {
            preferredTypes = [.cellular, .wifi, .wiredEthernet]
        }
        for type in preferredTypes where path.usesInterfaceType(type) {
            if let interface = path.availableInterfaces.first(where: { $0.type == type }) {
                return interface
            }
        }
        return nil
    }

    private func pathSummary(_ path: Network.NWPath) -> String {
        let used = [
            path.usesInterfaceType(.wifi) ? "wifi" : nil,
            path.usesInterfaceType(.cellular) ? "cellular" : nil,
            path.usesInterfaceType(.wiredEthernet) ? "wired" : nil,
        ].compactMap { $0 }.joined(separator: ",")
        let available = path.availableInterfaces.map { interface in
            "\(interface.name):\(Self.interfaceTypeName(interface.type))"
        }.joined(separator: ",")
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requiresConnection"
        @unknown default: status = "unknown"
        }
        return "NWPath status=\(status) used=[\(used.isEmpty ? "none" : used)] "
            + "available=[\(available.isEmpty ? "none" : available)] "
            + "ipv4=\(path.supportsIPv4) ipv6=\(path.supportsIPv6) "
            + "expensive=\(path.isExpensive) constrained=\(path.isConstrained)"
    }

    private static func interfaceTypeName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "wired"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }

    /// 主 App 经系统 IPC 或 TrollStore 文件 IPC 发来的统一控制请求。
    /// JSON 命令协议：{"v":1,"cmd":"hello"|"queryProxies"|"connections"|...}。
    /// 关键：completionHandler 必须**非 nil 回调**，否则主 App 侧 resp 为 nil。
    override func handleAppMessage(_ messageData: Data,
                                  completionHandler: ((Data?) -> Void)?) {
        let obj = (try? JSONSerialization.jsonObject(with: messageData)) as? [String: Any]
        let cmd = (obj?["cmd"] as? String) ?? String(data: messageData, encoding: .utf8) ?? ""
        let sessionGeneration = currentIPCSessionGeneration()
        let reply: (Data?) -> Void = { [weak self] data in
            guard let self, let data else {
                completionHandler?(data)
                return
            }
            self.completeAppMessage(data,
                                    completionHandler: completionHandler,
                                    generation: sessionGeneration)
        }
        let protocolVersion = (obj?["v"] as? NSNumber)?.intValue
        if let protocolVersion, protocolVersion != 1 {
            reply(Self.jsonData([
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
            reply(Data(MihomoControlInfo().utf8))
        case "queryProxies":
            ipcQueue.async {
                reply(Data(MihomoQueryProxies().utf8))
            }
        case "remoteResourceStatus":
            ipcQueue.async {
                reply(Data(MihomoRemoteResourceStatus().utf8))
            }
        case "updateProxyProviders":
            recordMemoryDiagnostic("providerUpdateStart")
            ipcQueue.async {
                let response = MihomoUpdateProxyProviders()
                self.recordMemoryDiagnostic("providerUpdateEnd")
                reply(Data(response.utf8))
            }
        case "updateProxyProvider":
            let name = (obj?["name"] as? String) ?? ""
            recordMemoryDiagnostic("providerUpdateStart")
            ipcQueue.async {
                let response = MihomoUpdateProxyProvider(name)
                self.recordMemoryDiagnostic("providerUpdateEnd")
                reply(Data(response.utf8))
            }
        case "updateRuleProviders":
            recordMemoryDiagnostic("ruleProviderUpdateStart")
            ipcQueue.async {
                let response = MihomoUpdateRuleProviders()
                self.recordMemoryDiagnostic("ruleProviderUpdateEnd")
                reply(Data(response.utf8))
            }
        case "updateRuleProvider":
            let name = (obj?["name"] as? String) ?? ""
            recordMemoryDiagnostic("ruleProviderUpdateStart")
            ipcQueue.async {
                let response = MihomoUpdateRuleProvider(name)
                self.recordMemoryDiagnostic("ruleProviderUpdateEnd")
                reply(Data(response.utf8))
            }
        case "selectProxy":
            let group = (obj?["group"] as? String) ?? ""
            let name = (obj?["name"] as? String) ?? ""
            var err: NSError?
            let ok = MihomoSelectProxy(group, name, &err)
            let resp: [String: Any] = ok ? ["ok": true]
                                         : ["ok": false, "error": err?.localizedDescription ?? "未知错误"]
            reply((try? JSONSerialization.data(withJSONObject: resp)) ?? Data())
        case "groupDelay":
            let group = (obj?["group"] as? String) ?? ""
            let url = (obj?["url"] as? String) ?? ""
            let directURL = (obj?["directURL"] as? String) ?? ""
            let timeout = (obj?["timeout"] as? NSNumber)?.intValue ?? 5000
            recordMemoryDiagnostic("groupDelayStart")
            ipcQueue.async {
                let response = MihomoGroupDelay(group, url, directURL, timeout)
                self.recordMemoryDiagnostic("groupDelayEnd")
                reply(Self.validatedCoreJSONData(response, command: "groupDelay"))
            }
        case "proxyDelay":
            let name = (obj?["name"] as? String) ?? ""
            let group = (obj?["group"] as? String) ?? ""
            let url = (obj?["url"] as? String) ?? ""
            let directURL = (obj?["directURL"] as? String) ?? ""
            let timeout = (obj?["timeout"] as? NSNumber)?.intValue ?? 5000
            recordMemoryDiagnostic("proxyDelayStart")
            ipcQueue.async {
                let response = MihomoProxyDelay(name, group, url, directURL, timeout)
                self.recordMemoryDiagnostic("proxyDelayEnd")
                reply(Self.validatedCoreJSONData(response, command: "proxyDelay"))
            }
        case "proxyDelays":
            guard let targets = obj?["targets"] as? [Any],
                  JSONSerialization.isValidJSONObject(targets),
                  let targetsData = try? JSONSerialization.data(withJSONObject: targets) else {
                reply(Self.jsonData(["error": "批量测速目标格式错误"]))
                return
            }
            let targetsJSON = String(decoding: targetsData, as: UTF8.self)
            let url = (obj?["url"] as? String) ?? ""
            let directURL = (obj?["directURL"] as? String) ?? ""
            let timeout = (obj?["timeout"] as? NSNumber)?.intValue ?? 5000
            recordMemoryDiagnostic("proxyDelaysStart")
            ipcQueue.async {
                let response = MihomoProxyDelays(targetsJSON, url, directURL, timeout)
                self.recordMemoryDiagnostic("proxyDelaysEnd")
                reply(Self.validatedCoreJSONData(response, command: "proxyDelays"))
            }
        case "readRuleProvider":
            let name = (obj?["name"] as? String) ?? ""
            let maxBytes = (obj?["maxBytes"] as? NSNumber)?.intValue ?? (1 * 1024 * 1024)
            ipcQueue.async {
                reply(Data(MihomoRuleProviderContent(name, maxBytes).utf8))
            }
        case "scriptFetch":
            guard let request = obj?["request"] as? [String: Any],
                  let requestData = try? JSONSerialization.data(withJSONObject: request),
                  let requestJSON = String(data: requestData, encoding: .utf8) else {
                reply(Self.jsonData(["ok": false, "error": "脚本请求参数无效"]))
                return
            }
            ipcQueue.async {
                reply(Data(MihomoScriptFetch(requestJSON).utf8))
            }
        case "scriptTargetInfo":
            let name = (obj?["name"] as? String) ?? ""
            let group = (obj?["group"] as? String) ?? ""
            ipcQueue.async {
                reply(Data(MihomoScriptTargetInfo(name, group).utf8))
            }
        case "directNetworkInfo":
            ipcQueue.async {
                reply(Data(MihomoDirectNetworkInfo().utf8))
            }
        case "connections":
            let limit = (obj?["limit"] as? NSNumber)?.intValue ?? 200
            ipcQueue.async {
                reply(Data(MihomoConnectionsSnapshot(limit).utf8))
            }
        case "closeConnection":
            let id = (obj?["id"] as? String) ?? ""
            var error: NSError?
            let ok = MihomoCloseConnection(id, &error)
            reply(Self.jsonData(ok
                ? ["ok": true]
                : ["ok": false, "error": error?.localizedDescription ?? "未知错误"]))
        case "closeAllConnections":
            reply(Self.jsonData([
                "ok": true,
                "closed": Int(MihomoCloseAllConnections()),
            ]))
        case "traffic":
            reply(Data(MihomoTrafficNow().utf8))
        case "memory":
            reply(Self.memoryFootprintData())
        case "setMemoryDiagnostics":
            let enabled = (obj?["enabled"] as? NSNumber)?.boolValue ?? false
            let result = setMemoryDiagnosticsEnabled(enabled)
            reply(Self.jsonData(result.ok
                ? ["ok": true, "enabled": result.enabled]
                : ["ok": false, "error": result.error ?? "开发者诊断不可用"]))
        case "memoryDiagnostics":
            ipcQueue.async {
                let enabled = self.runtimeQueue.sync { self.developerModeEnabled }
                guard enabled else {
                    reply(Data("开发者模式未开启".utf8))
                    return
                }
                let diagnostics = self.runtimeQueue.sync {
                    self.collectMemoryDiagnostics()
                }
                reply(Self.tailData(diagnostics, maxBytes: 128 * 1024))
            }
        case "clearMemoryDiagnostics":
            let result = clearMemoryDiagnostics()
            reply(Self.jsonData(result.ok
                ? ["ok": true]
                : ["ok": false, "error": result.error ?? "清理诊断失败"]))
        case "proxyDetails":
            reply(Data(MihomoProxyDetails().utf8))
        case "configNotices":
            reply(Data(MihomoConfigNotices().utf8))
        case "getMode":
            reply(Data(MihomoMode().utf8))
        case "setMode":
            MihomoSetMode((obj?["mode"] as? String) ?? "rule")
            reply(Data(#"{"ok":true}"#.utf8))
        case "runLogChunk":
            let offset = (obj?["offset"] as? NSNumber)?.intValue ?? -1
            let generation = (obj?["generation"] as? NSNumber)?.intValue ?? 0
            ipcQueue.async {
                reply(Data(MihomoRunLogChunk(offset, generation).utf8))
            }
        case "readResponseChunk":
            completionHandler?(responseChunk(token: obj?["token"] as? String,
                                              offset: (obj?["offset"] as? NSNumber)?.intValue,
                                              generation: sessionGeneration))
        case "getLogs":
            // 日志可能很大，IPC 响应有体积上限 → 只回传末尾约 24KB，取最新内容。
            let body = "[cmd=\(cmd)]\n" + collectLogs()
            reply(Self.tailData(body, maxBytes: 24 * 1024))
        case "exportNELog":
            // 只导出有界的 NE 专用日志；不包含完整 run.log，避免事故备份本身
            // 在 NE 内制造不必要的内存峰值。
            reply(Data(FileLog.export().utf8))
        default:
            reply(Self.jsonData([
                "ok": false,
                "error": "未知控制命令：\(cmd)",
            ]))
        }
    }

    /// NetworkExtension may turn an oversized provider reply into nil. Large
    /// replies are retained briefly and fetched by the app in bounded chunks.
    private func completeAppMessage(_ data: Data,
                                    completionHandler: ((Data?) -> Void)?,
                                    generation: UInt64) {
        ipcResponseLock.lock()
        let isCurrentSession = ipcResponseCachingEnabled
            && generation == ipcSessionGeneration
        ipcResponseLock.unlock()
        guard isCurrentSession else {
            completionHandler?(Self.jsonData([
                "ok": false,
                "error": "IPC 响应已过期",
            ]))
            return
        }
        guard data.count > Self.ipcInlineResponseLimit else {
            completionHandler?(data)
            return
        }
        guard data.count <= Self.ipcMaximumResponseSize else {
            completionHandler?(Self.jsonData([
                "ok": false,
                "error": "控制响应超过 \(Self.ipcMaximumResponseSize / 1_048_576) MB 上限",
            ]))
            return
        }

        let token = UUID().uuidString
        let now = Date()
        ipcResponseLock.lock()
        guard ipcResponseCachingEnabled, generation == ipcSessionGeneration else {
            ipcResponseLock.unlock()
            completionHandler?(Self.jsonData([
                "ok": false,
                "error": "IPC 响应已过期",
            ]))
            return
        }
        purgeExpiredIPCResponsesLocked(now: now)
        // The app normally consumes a token immediately. If it does not,
        // evict the oldest hand-off before retaining another response so a
        // failed UI request cannot accumulate several megabytes in the NE.
        while storedIPCResponses.count >= Self.ipcMaximumStoredResponses
                || storedIPCResponseBytes + data.count > Self.ipcMaximumStoredResponseBytes {
            guard let oldest = storedIPCResponses.min(by: {
                $0.value.expiresAt < $1.value.expiresAt
            })?.key else { break }
            removeStoredIPCResponseLocked(forKey: oldest)
        }
        storedIPCResponses[token] = StoredIPCResponse(
            data: data,
            expiresAt: now.addingTimeInterval(Self.ipcResponseLifetime))
        storedIPCResponseBytes += data.count
        ipcResponseLock.unlock()

        // Expiration must not depend on a later IPC request. A single
        // coalesced work item services the whole bounded cache, so repeated
        // large replies cannot enqueue an unbounded number of delayed blocks.
        scheduleIPCResponseCleanup(generation: generation)

        completionHandler?(Self.jsonData([
            "_coraTransfer": "chunked-v1",
            "token": token,
            "total": data.count,
            "chunkSize": Self.ipcResponseChunkSize,
        ]))
    }

    private func responseChunk(token: String?, offset: Int?, generation: UInt64) -> Data {
        guard let token, UUID(uuidString: token) != nil,
              let offset, offset >= 0 else {
            return Self.jsonData(["ok": false, "error": "分块响应参数无效"])
        }

        ipcResponseLock.lock()
        defer { ipcResponseLock.unlock() }
        guard ipcResponseCachingEnabled, generation == ipcSessionGeneration else {
            return Data()
        }
        purgeExpiredIPCResponsesLocked(now: Date())
        guard let stored = storedIPCResponses[token], stored.expiresAt > Date(),
              offset < stored.data.count else {
            removeStoredIPCResponseLocked(forKey: token)
            return Data()
        }
        let end = min(offset + Self.ipcResponseChunkSize, stored.data.count)
        let chunk = stored.data.subdata(in: offset..<end)
        if end == stored.data.count {
            removeStoredIPCResponseLocked(forKey: token)
        }
        return chunk
    }

    private func scheduleIPCResponseCleanup(generation: UInt64) {
        ipcResponseLock.lock()
        guard ipcResponseCachingEnabled,
              generation == ipcSessionGeneration,
              ipcResponseCleanupWorkItem == nil,
              !storedIPCResponses.isEmpty else {
            ipcResponseLock.unlock()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.runIPCResponseCleanup(generation: generation)
        }
        ipcResponseCleanupWorkItem = work
        ipcResponseLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.ipcResponseLifetime,
            execute: work)
    }

    private func runIPCResponseCleanup(generation: UInt64) {
        ipcResponseLock.lock()
        guard generation == ipcSessionGeneration else {
            ipcResponseLock.unlock()
            return
        }
        ipcResponseCleanupWorkItem = nil
        purgeExpiredIPCResponsesLocked(now: Date())
        let hasResponses = !storedIPCResponses.isEmpty
        ipcResponseLock.unlock()
        if hasResponses {
            scheduleIPCResponseCleanup(generation: generation)
        }
    }

    private func purgeExpiredIPCResponsesLocked(now: Date) {
        let expiredKeys = storedIPCResponses.compactMap { key, value in
            value.expiresAt <= now ? key : nil
        }
        for key in expiredKeys {
            removeStoredIPCResponseLocked(forKey: key)
        }
    }

    private func removeStoredIPCResponseLocked(forKey key: String) {
        guard let response = storedIPCResponses.removeValue(forKey: key) else { return }
        storedIPCResponseBytes = max(0, storedIPCResponseBytes - response.data.count)
    }

    private func clearStoredIPCResponses(enableCaching: Bool? = nil) {
        ipcResponseLock.lock()
        ipcSessionGeneration &+= 1
        ipcResponseCleanupWorkItem?.cancel()
        ipcResponseCleanupWorkItem = nil
        storedIPCResponses.removeAll(keepingCapacity: false)
        storedIPCResponseBytes = 0
        if let enableCaching {
            ipcResponseCachingEnabled = enableCaching
        }
        ipcResponseLock.unlock()
    }

    private func currentIPCSessionGeneration() -> UInt64 {
        ipcResponseLock.lock()
        defer { ipcResponseLock.unlock() }
        return ipcSessionGeneration
    }

    private static func jsonData(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"ok":false}"#.utf8)
    }

    /// MobileCore control methods promise a JSON object. Keep malformed core
    /// errors from crossing IPC as opaque text, which would hide the source of
    /// the failure behind a generic decoding error in the app.
    private static func validatedCoreJSONData(_ response: String, command: String) -> Data {
        let data = Data(response.utf8)
        if let object = try? JSONSerialization.jsonObject(with: data),
           object is [String: Any] {
            return data
        }
        FileLog.write("\(command)：内核返回无效 JSON，字节数=\(data.count)")
        return jsonData([
            "error": "内核返回无效响应（\(command)）",
        ])
    }

    /// 返回当前 Network Extension 进程的物理内存占用。
    /// `phys_footprint` 与系统内存压力/Jetsam 口径更接近，不能用 RSS 替代。
    private static func memoryFootprintData() -> Data {
        let footprint = MemoryDiagnostics.physicalFootprint()
        let payload: [String: NSNumber] = ["physFootprint": NSNumber(value: footprint)]
        return (try? JSONSerialization.data(withJSONObject: payload))
            ?? Data(#"{"physFootprint":0}"#.utf8)
    }

    /// 只在设置 JSON 明确开启时启动 NE 诊断。旧缓存或系统重连同样经过这里，
    /// 因此开发者模式不会因为一次重连意外恢复成常驻采样。
    private func configureMemoryDiagnostics(enabled: Bool,
                                            home: String,
                                            persistState: Bool = false) {
        if persistState {
            Self.persistDeveloperMode(enabled, home: home)
        }
        // The always-on guard is mutually exclusive with detailed diagnostics.
        // Reconfigure it here so a live developer-mode toggle takes effect
        // without requiring a tunnel restart.
        memoryPressureGuard?.stop()
        memoryPressureGuard = nil
        memoryDiagnostics?.stop(event: "reconfigure")
        memoryDiagnostics = nil
        developerModeEnabled = enabled
        guard enabled else {
            guard tunnelFileDescriptor != nil else { return }
            let guarder = MemoryPressureGuard()
            guarder.start()
            memoryPressureGuard = guarder
            return
        }
        let diagnostics = MemoryDiagnostics()
        diagnostics.start(directoryPath: home)
        memoryDiagnostics = diagnostics
        FileLog.write("开发者模式：已开启 NE 内存诊断（5 秒采样，文件上限 256KB）")
    }

    /// 事件标记只进入开发者模式的有界 NDJSON 文件，不进入普通日志/连接历史。
    private func recordMemoryDiagnostic(_ event: String) {
        runtimeQueue.async { [weak self] in
            self?.memoryDiagnostics?.record(event: event)
        }
    }

    private func setMemoryDiagnosticsEnabled(_ enabled: Bool)
        -> (ok: Bool, enabled: Bool, error: String?) {
        runtimeQueue.sync {
            guard let home = homeDir else {
                return (false, developerModeEnabled, "隧道尚未启动")
            }
            if enabled == developerModeEnabled,
               (enabled == false || memoryDiagnostics != nil) {
                return (true, developerModeEnabled, nil)
            }
            configureMemoryDiagnostics(enabled: enabled, home: home, persistState: true)
            return (true, developerModeEnabled, nil)
        }
    }

    private func clearMemoryDiagnostics()
        -> (ok: Bool, error: String?) {
        runtimeQueue.sync {
            guard let home = homeDir else {
                return (false, "隧道尚未启动")
            }
            let shouldRestart = developerModeEnabled
            memoryDiagnostics?.stop(event: "clear")
            memoryDiagnostics = nil
            let directory = URL(fileURLWithPath: home, isDirectory: true)
            let manager = FileManager.default
            for name in ["memory-diagnostic.ndjson", "memory-diagnostic.previous.ndjson"] {
                try? manager.removeItem(at: directory.appendingPathComponent(name))
            }
            if shouldRestart {
                let diagnostics = MemoryDiagnostics()
                diagnostics.start(directoryPath: home)
                memoryDiagnostics = diagnostics
            }
            FileLog.write("开发者模式：已清理内存诊断文件")
            return (true, nil)
        }
    }

    private func collectMemoryDiagnostics() -> String {
        guard let home = homeDir else {
            return "(隧道尚未启动)"
        }
        let directory = URL(fileURLWithPath: home, isDirectory: true)
        let previous = Self.tailTextFile(
            directory.appendingPathComponent("memory-diagnostic.previous.ndjson").path,
            maxBytes: 96 * 1024) ?? "(不存在)"
        let current = Self.tailTextFile(
            directory.appendingPathComponent("memory-diagnostic.ndjson").path,
            maxBytes: 96 * 1024) ?? "(不存在)"
        return "===== memory diagnostic（上一段）=====\n\(previous)\n\n"
            + "===== memory diagnostic（当前段）=====\n\(current)"
    }

    private static func developerModeEnabled(settingsJSON: String,
                                             home: String,
                                             preferSettings: Bool) -> Bool {
        if !preferSettings,
           let persisted = persistedDeveloperMode(home: home) {
            return persisted
        }
        guard let data = settingsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return false }
        return (dict["developerMode"] as? Bool) ?? false
    }

    /// 系统重连没有携带 options，使用最近一次 App/IPC 明确设置的轻量标记，
    /// 避免关闭开发者模式后仍因旧 settings.json 恢复采样。
    private static func persistedDeveloperMode(home: String) -> Bool? {
        let path = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("developer-mode.state")
        guard let value = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }

    private static func persistDeveloperMode(_ enabled: Bool, home: String) {
        let path = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("developer-mode.state")
        let value = enabled ? "1" : "0"
        try? value.write(to: path, atomically: true, encoding: .utf8)
    }

    /// 取字符串末尾不超过 maxBytes 的 UTF-8 数据（避免 IPC 响应超限被丢成空响应）。
    private static func tailData(_ s: String, maxBytes: Int) -> Data {
        let data = Data(s.utf8)
        guard data.count > maxBytes else { return data }
        return Data("…（已截断，仅显示最新 \(maxBytes / 1024)KB）\n".utf8) + data.suffix(maxBytes)
    }

    /// 汇总 NE 步骤日志、mihomo 日志和持久化内存诊断。
    private func collectLogs() -> String {
        var out = "===== ne（NE 启动步骤）=====\n" + FileLog.dump()
        if let home = homeDir {
            let runPath = (home as NSString).appendingPathComponent("run.log")
            let run = Self.tailTextFile(runPath, maxBytes: 10 * 1024) ?? "(run.log 不存在)"
            out += "\n\n===== run.log（mihomo 内核）=====\n" + (run.isEmpty ? "(空)" : run)

            // 普通日志请求不读取开发者诊断文件；这样关闭开发者模式后，
            // 旧诊断数据不会被意外带入日志响应或制造额外内存峰值。
            let diagnosticsEnabled = runtimeQueue.sync { developerModeEnabled }
            if diagnosticsEnabled {
                let previousPath = (home as NSString)
                    .appendingPathComponent("memory-diagnostic.previous.ndjson")
                let currentPath = (home as NSString)
                    .appendingPathComponent("memory-diagnostic.ndjson")
                let previous = Self.tailTextFile(previousPath, maxBytes: 4 * 1024) ?? "(不存在)"
                let current = Self.tailTextFile(currentPath, maxBytes: 6 * 1024) ?? "(不存在)"
                out += "\n\n===== memory diagnostic（上一段）=====\n" + previous
                out += "\n\n===== memory diagnostic（当前段）=====\n" + current
            }
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
