import Foundation
import NetworkExtension
import Network
import MeowCore
import WidgetKit

/// The engine sees IP frames through Apple's documented packetFlow API.
/// All lifecycle operations run on runtimeQueue; packet callbacks never enter it.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let runtimeQueue = DispatchQueue(label: "com.cora.tunnel.runtime", qos: .userInitiated)
    private let ipcScheduler = IPCControlScheduler()
    private let ipcResponseCache = IPCResponseCache()
    private static let ipcInlineResponseLimit = 16 * 1024
    private static let ipcMaximumRequestBytes = 1024 * 1024
    private let connectionHistoryRecorder = ConnectionHistoryRecorder()
    private lazy var pump = PacketFlowPump(flow: packetFlow)
    private var writerContext: UnsafeMutableRawPointer?
    private let adapterLock = NSLock()
    private var adapter: CoraCoreAdapter?
    private var home: URL?
    private var diagnostics: MemoryDiagnostics?
    private var pathMonitor: NWPathMonitor?
    private var pathSignature: String?
    private var pendingProbe: DispatchWorkItem?
    private var lastRestart: TimeInterval = -.infinity
    private var pathSummary: [String: Any] = [:]

    private func currentAdapter() -> CoraCoreAdapter? {
        adapterLock.lock(); defer { adapterLock.unlock() }; return adapter
    }
    private func installAdapter(_ value: CoraCoreAdapter?) {
        adapterLock.lock(); adapter = value; adapterLock.unlock()
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let generation = clearStoredIPCResponses(enableCaching: true)
        runtimeQueue.async {
            self.stopCore()
            FileLog.reset()
            FileLog.write("meow-rs startup-attempt=\((options?["startupAttemptID"] as? String) ?? UUID().uuidString)")
            do {
                let home = AppGroup.containerURL ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("meow", isDirectory: true)
                self.home = home
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                let snapshot = try CoreSessionSnapshot.load(home: home)
                if options?["restoreLastSuccess"] as? Bool == true && snapshot == nil {
                    throw CoraNativeCore.failure("没有可恢复的 Rust 成功配置快照")
                }
                let explicit = options?["config"] != nil
                let incoming = options?["config"] as? String ?? ""
                let source: String
                if explicit { source = incoming.isEmpty ? CoraRuntimeConfig.directModeYAML() : incoming }
                else if let snapshot { source = snapshot.source }
                else {
                    // First migration only: read the previous core's immutable
                    // input cache. Never overwrite it with a patched runtime.
                    source = (try? String(contentsOf: home.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? CoraRuntimeConfig.directModeYAML()
                }
                let settings = (options?["settings"] as? String) ?? snapshot?.settings
                    ?? ((try? String(contentsOf: home.appendingPathComponent("settings.json"), encoding: .utf8)) ?? "{}")
                var effective = CoraNativeCore.dictionary(settings)
                effective["systemDNS"] = SystemDNS.excludingTunnel(SystemDNS.currentServers())
                // Missing shared GEO is an error, never a silent rule deletion.
                let resolved = try CoraNativeCore.object("resolveGeo", ["yaml": source, "settings": effective])
                var assets: [(String, String)] = []
                if resolved["geoRequired"] as? Bool == true { assets += [("geoip.metadb", "mmdb"), ("GeoSite.dat", "geosite")] }
                if resolved["asnRequired"] as? Bool == true { assets.append(("ASN.mmdb", "asn")) }
                for (name, kind) in assets {
                    _ = try CoraNativeCore.object("validateGeo", ["path": home.appendingPathComponent(name).path, "kind": kind])
                }
                let core = try CoraCoreAdapter(source: source, settingsJSON: settings, home: home)
                self.installAdapter(core)
                let info = try CoraNativeCore.object("configInfo", ["yaml": source])
                let network = self.makeNetworkSettings(configuredMTU: info["mtu"] as? Int,
                    ipv6Enabled: effective["ipv6"] as? Bool ?? false)
                self.setTunnelNetworkSettings(network) { error in
                    self.runtimeQueue.async {
                        guard self.isCurrentIPCSession(generation) else {
                            completionHandler(CoraNativeCore.failure("VPN 启动已取消")); return
                        }
                        do {
                            if let error { throw error }
                            try core.start()
                            try self.startPackets(ipv6: effective["ipv6"] as? Bool ?? false)
                            guard self.isCurrentIPCSession(generation) else { throw CoraNativeCore.failure("VPN 启动已取消") }
                            // Commit only after both engine and packet stack start.
                            try CoreSessionSnapshot(version: 1, source: source, settings: settings, runtime: core.runtimeYAML).commit(home: home)
                            _ = ProxyDelayStore.beginSession()
                            self.connectionHistoryRecorder.start()
                            self.configureDiagnostics(effective["developerMode"] as? Bool ?? false)
                            self.startPathMonitor(generation: generation)
                            AppGroupState.vpnConnected = true
                            ControlCenter.shared.reloadControls(ofKind: ControlWidgetKind.vpn)
                            FileLog.write("meow-rs engine + packetFlow 已启动")
                            completionHandler(nil)
                        } catch {
                            self.stopCore()
                            FileLog.write("meow-rs 启动失败，保留上次成功快照：\(error.localizedDescription)")
                            completionHandler(error)
                        }
                    }
                }
            } catch {
                self.stopCore()
                FileLog.write("配置预检失败：\(error.localizedDescription)")
                completionHandler(error)
            }
        }
    }

    private func startPackets(ipv6: Bool) throws {
        _ = meow_tun_set_ipv6_enabled(ipv6 ? 1 : 0)
        let context = Unmanaged.passRetained(PacketFlowWriter(flow: packetFlow)).toOpaque()
        guard meow_tun_start(context, coraWritePacket) == 0 else {
            meow_tun_stop_blocking()
            Unmanaged<PacketFlowWriter>.fromOpaque(context).release()
            throw CoraNativeCore.failure(CoraNativeCore.lastError)
        }
        writerContext = context
        pump.start()
    }

    private func stopPackets() {
        pump.stop()
        // Must join before release. Never substitute non-blocking meow_tun_stop.
        meow_tun_stop_blocking()
        if let context = writerContext {
            writerContext = nil
            Unmanaged<PacketFlowWriter>.fromOpaque(context).release()
        }
    }

    private func stopCore() {
        pendingProbe?.cancel(); pendingProbe = nil
        pathMonitor?.cancel(); pathMonitor = nil; pathSignature = nil
        currentAdapter()?.cancelRequests()
        connectionHistoryRecorder.stop()
        diagnostics?.stop(event: "stop"); diagnostics = nil
        stopPackets()
        meow_engine_stop()
        installAdapter(nil)
        AppGroupState.vpnConnected = false
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        _ = clearStoredIPCResponses(enableCaching: false)
        currentAdapter()?.cancelRequests()
        runtimeQueue.async {
            self.stopCore()
            ProxyDelayStore.clear()
            ControlCenter.shared.reloadControls(ofKind: ControlWidgetKind.vpn)
            completionHandler()
        }
    }

    private func startPathMonitor(generation: UInt64) {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, self.isCurrentIPCSession(generation) else { return }
            let kind: Int32 = path.status != .satisfied ? 0 :
                (path.usesInterfaceType(.cellular) && (!path.usesInterfaceType(.wifi) || path.isExpensive) ? 2 :
                (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) ? 1 : 3))
            _ = meow_engine_set_network_kind(kind)
            self.pathSummary = ["status": path.status == .satisfied ? "satisfied" : "unsatisfied",
                "networkKind": kind, "supportsIPv4": path.supportsIPv4, "supportsIPv6": path.supportsIPv6,
                "packetFlow": true, "expensive": path.isExpensive, "constrained": path.isConstrained,
                "usedInterfaces": path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map(\.name),
                "availableInterfaces": path.availableInterfaces.map { ["name": $0.name, "type": String(describing: $0.type)] },
                "systemDNS": SystemDNS.excludingTunnel(SystemDNS.currentServers())]
            let signature = "\(kind):\(path.supportsIPv4):\(path.supportsIPv6):" + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            guard signature != self.pathSignature else { return }
            let previous = self.pathSignature
            self.pathSignature = signature
            self.pendingProbe?.cancel()
            guard path.status == .satisfied, previous != nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.probeAndRecover(generation: generation) }
            self.pendingProbe = work
            self.runtimeQueue.asyncAfter(deadline: .now() + 2, execute: work)
        }
        monitor.start(queue: runtimeQueue)
    }

    private func probeAndRecover(generation: UInt64) {
        guard isCurrentIPCSession(generation), let core = currentAdapter(), writerContext != nil else { return }
        let result = CoraRuntimeConfig.tunGatewayIP.withCString { source in
            CoraRuntimeConfig.dnsServerIP.withCString { meow_tun_health_probe(source, $0, 2000) }
        }
        guard result != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRestart >= 60 else {
            FileLog.write("数据路径探测失败；受控重启冷却中")
            return
        }
        lastRestart = now
        reasserting = true
        defer { reasserting = false }
        FileLog.write("数据路径探测失败，执行一次受控重启")
        connectionHistoryRecorder.stop()
        stopPackets()
        meow_engine_stop()
        do {
            try core.start()
            try startPackets(ipv6: CoraNativeCore.dictionary(core.settingsJSON)["ipv6"] as? Bool ?? false)
            connectionHistoryRecorder.start()
        } catch {
            stopCore()
            cancelTunnelWithError(error)
        }
    }

    override func wake() {
        let generation = currentIPCSessionGeneration()
        runtimeQueue.async { self.probeAndRecover(generation: generation) }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let generation = currentIPCSessionGeneration()
        guard messageData.count <= Self.ipcMaximumRequestBytes else {
            completionHandler?(CoraNativeCore.error("控制请求超过 1 MB 上限")); return
        }
        let object = (try? JSONSerialization.jsonObject(with: messageData)) as? [String: Any] ?? [:]
        let command = object["cmd"] as? String ?? String(decoding: messageData, as: UTF8.self)
        if let version = object["v"] as? Int, version != 1 {
            completionHandler?(CoraNativeCore.error("不支持的控制协议版本")); return
        }
        if command == "readResponseChunk" {
            completionHandler?(responseChunk(token: object["token"] as? String, offset: object["offset"] as? Int, generation: generation)); return
        }
        let reply: (Data?) -> Void = { [weak self] data in
            guard let self, let data else { completionHandler?(nil); return }
            self.completeAppMessage(data, completionHandler: completionHandler, generation: generation)
        }
        let work: IPCControlScheduler.WorkClass = ["groupDelay", "proxyDelay", "proxyDelays"].contains(command) || command.hasPrefix("update") ? .heavy : .snapshot
        enqueueIPCWork(generation: generation, workClass: work, reply: reply) {
            switch command {
            case "memory": reply(Self.memoryFootprintData())
            case "networkInfo": reply(self.runtimeQueue.sync { CoraNativeCore.encode(self.pathSummary) })
            case "exportNELog", "getLogs": reply(Data(FileLog.export().utf8))
            case "setMemoryDiagnostics":
                self.runtimeQueue.sync { self.configureDiagnostics(object["enabled"] as? Bool ?? false) }
                reply(Self.jsonData(["ok": true, "enabled": object["enabled"] as? Bool ?? false]))
            case "memoryDiagnostics":
                reply(self.runtimeQueue.sync { self.diagnosticData() })
            case "clearMemoryDiagnostics":
                self.runtimeQueue.sync {
                    let enabled = self.diagnostics != nil
                    self.diagnostics?.stop(event: "clear"); self.diagnostics = nil
                    if let home = self.home {
                        for name in ["memory-diagnostic.ndjson", "memory-diagnostic.previous.ndjson", "memory-diagnostic.summary.json", "memory-diagnostic.summary.previous.json"] {
                            try? FileManager.default.removeItem(at: home.appendingPathComponent(name))
                        }
                    }
                    self.configureDiagnostics(enabled)
                }
                reply(Self.jsonData(["ok": true]))
            default:
                guard let core = self.currentAdapter() else { reply(CoraNativeCore.error("VPN 尚未连接")); return }
                reply(core.command(command, object))
            }
        }
    }

    private func configureDiagnostics(_ enabled: Bool) {
        diagnostics?.stop(event: "reconfigure"); diagnostics = nil
        guard let home else { return }
        try? Data((enabled ? "1" : "0").utf8).write(to: home.appendingPathComponent("developer-mode.state"), options: .atomic)
        if enabled {
            let diagnostics = MemoryDiagnostics()
            diagnostics.start(directoryPath: home.path)
            self.diagnostics = diagnostics
        }
    }

    private func diagnosticData() -> Data {
        guard let home, diagnostics != nil else { return Data("开发者模式未开启".utf8) }
        var result = Data()
        for name in ["memory-diagnostic.previous.ndjson", "memory-diagnostic.ndjson"] {
            let url = home.appendingPathComponent(name)
            guard let file = try? FileHandle(forReadingFrom: url) else { continue }
            let size = (try? file.seekToEnd()) ?? 0
            try? file.seek(toOffset: size > 96 * 1024 ? size - 96 * 1024 : 0)
            result.append((try? file.read(upToCount: 96 * 1024)) ?? Data())
            try? file.close()
        }
        return result
    }

    private func enqueueIPCWork(generation: UInt64,
                                workClass: IPCControlScheduler.WorkClass = .snapshot,
                                key: String? = nil,
                                scriptID: String? = nil,
                                reply: @escaping (Data?) -> Void,
                                operation: @escaping () -> Void) {
        // Provider single-flight keys are scoped to the tunnel session. An
        // old session may still be unwinding a cancelled network request;
        // it must not block the same refresh in a newly started session.
        let scopedKey = key.map { "\($0)#\(generation)" }
        let accepted = ipcScheduler.submit(workClass, key: scopedKey, scriptID: scriptID, operation: { [weak self] in
            guard let self else { return }
            guard self.isCurrentIPCSession(generation) else {
                reply(Self.jsonData(["ok": false, "error": "控制请求已过期"]))
                return
            }
            operation()
        }, onReject: {
            reply(Self.jsonData(["ok": false, "error": "控制任务繁忙，请稍后重试", "code": "busy"]))
        }, onCancel: {
            reply(Self.jsonData(["ok": false, "error": "控制请求已过期", "code": "cancelled"]))
        }, onTimeout: {
            reply(Self.jsonData(["ok": false, "error": "控制任务排队超时", "code": "timeout"]))
        })
        // submit invokes onReject synchronously. Keep this explicit for
        // readability and future scheduler implementations.
        _ = accepted
    }

    private func isCurrentIPCSession(_ generation: UInt64) -> Bool {
        ipcResponseCache.isCurrent(generation)
    }

    /// Keep the existing descriptor and chunk wire format for both IPC transports.
    private func completeAppMessage(_ data: Data,
                                    completionHandler: ((Data?) -> Void)?,
                                    generation: UInt64) {
        guard ipcResponseCache.isCurrent(generation) else {
            completionHandler?(Self.jsonData(["ok": false, "error": "IPC 响应已过期"]))
            return
        }
        guard data.count > Self.ipcInlineResponseLimit else {
            completionHandler?(data)
            return
        }
        do {
            let descriptor = try ipcResponseCache.store(data, generation: generation)
            completionHandler?(Self.jsonData([
                "_coraTransfer": "chunked-v1",
                "token": descriptor.token,
                "total": descriptor.total,
                "chunkSize": IPCResponseCache.chunkSize,
            ]))
        } catch let error as IPCResponseCache.CacheError {
            completionHandler?(Self.jsonData(["ok": false, "error": error.message]))
        } catch {
            completionHandler?(Self.jsonData(["ok": false, "error": "无法暂存控制响应，请稍后重试"]))
        }
    }

    private func responseChunk(token: String?, offset: Int?, generation: UInt64) -> Data {
        guard let token, UUID(uuidString: token) != nil,
              let offset, offset >= 0 else {
            return Self.jsonData(["ok": false, "error": "分块响应参数无效"])
        }
        return ipcResponseCache.chunk(token: token, offset: offset, generation: generation)
    }


    @discardableResult
    private func clearStoredIPCResponses(enableCaching: Bool? = nil) -> UInt64 {
        let generation = ipcResponseCache.reset(enableCaching: enableCaching)
        ipcScheduler.cancelPending()
        return generation
    }

    private func currentIPCSessionGeneration() -> UInt64 {
        ipcResponseCache.currentGeneration()
    }

    private static func jsonData(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"ok":false}"#.utf8)
    }


    /// 返回当前 Network Extension 进程的物理内存占用。
    /// `phys_footprint` 与系统内存压力/Jetsam 口径更接近，不能用 RSS 替代。
    private static func memoryFootprintData() -> Data {
        let footprint = MemoryDiagnostics.physicalFootprint()
        let payload: [String: NSNumber] = ["physFootprint": NSNumber(value: footprint)]
        return (try? JSONSerialization.data(withJSONObject: payload))
            ?? Data(#"{"physFootprint":0}"#.utf8)
    }


    private func makeNetworkSettings(configuredMTU: Int?,
                                     ipv6Enabled: Bool) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: CoraRuntimeConfig.tunGatewayIP)

        // IPv4：网关 198.18.0.1/16，默认路由全量接管。
        // 注：字面默认路由 0.0.0.0/0 经真机验证可用——核心 DIRECT 出站靠系统真实
        // 默认路由走物理网卡，不回环（早期「8 段子网」方案已被推翻）。
        let ipv4 = NEIPv4Settings(addresses: [CoraRuntimeConfig.tunGatewayIP],
                                  subnetMasks: [CoraRuntimeConfig.tunSubnetMask])
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
        let dns = NEDNSSettings(servers: [CoraRuntimeConfig.dnsServerIP])
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


}
