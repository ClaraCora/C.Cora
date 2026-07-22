import Foundation
import NetworkExtension

/// 负责与系统 VPN 子系统打交道：安装/加载 VPN 描述文件、启停隧道、上报状态。
///
/// Phase 0 只做最小闭环——把 NE 隧道拉起/停掉，验证权限链路与 VPN 图标。
/// Phase 2 起，这里会通过 `sendProviderMessage` 向 NE 传配置路径、查询运行态。
///
/// 设计上它是「控制面」的底层，不持有 UI 状态；UI 状态由 CoreStateManager 聚合。
final class TunnelManager {

    /// NETunnelProviderProtocol(NEVPNProtocol) 上的隧道开关（连接时设置）。
    struct ProtocolOptions {
        var includeAllNetworks = false
        var excludeCellularServices = true
        var excludeAPNs = true
        var excludeDeviceCommunication = true
        var enforceRoutes = false
    }

    /// 当前使用的 provider 管理对象。懒加载/复用，避免重复创建系统描述文件。
    private var manager: NETunnelProviderManager?

    /// 加载（或创建）MiClash 的 VPN 描述文件。
    /// iOS 要求 VPN 配置先 saveToPreferences 落到「设置 > VPN」里，用户授权一次后方可启动。
    private func loadOrCreateManager(options: ProtocolOptions) async throws -> NETunnelProviderManager {
        let existing = try await NETunnelProviderManager.loadAllFromPreferences()
        let mgr = existing.first { Self.isMiClashManager($0) } ?? NETunnelProviderManager()

        // 每次连接都写入一份新协议对象，避免覆盖安装后继续引用旧扩展配置快照。
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppConstants.tunnelBundleID
        proto.serverAddress = "MiClash"
        proto.includeAllNetworks = options.includeAllNetworks
        proto.enforceRoutes = options.enforceRoutes
        proto.excludeCellularServices = options.excludeCellularServices
        proto.excludeAPNs = options.excludeAPNs
        proto.excludeDeviceCommunication = options.excludeDeviceCommunication

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

    /// 只读加载已保存配置。状态查询不能顺带创建/保存配置，否则覆盖安装后容易刷新旧快照。
    private func loadSavedManager() async throws -> NETunnelProviderManager? {
        let existing = try await NETunnelProviderManager.loadAllFromPreferences()
        let mgr = existing.first { Self.isMiClashManager($0) }
        self.manager = mgr
        return mgr
    }

    private static func isMiClashManager(_ manager: NETunnelProviderManager) -> Bool {
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
            == AppConstants.tunnelBundleID
    }

    /// 启动隧道，并把订阅配置 + 设置经 options 下发给 NE（不依赖 App Group）。
    /// App 启动始终携带 config：非空=订阅，空串=明确 DIRECT；系统无 options 重连才复用缓存。
    func start(configYAML: String?, settingsJSON: String, protocolOptions: ProtocolOptions) async throws {
        let mgr = try await loadOrCreateManager(options: protocolOptions)
        var options: [String: NSObject] = ["config": (configYAML ?? "") as NSString]
        if !settingsJSON.isEmpty { options["settings"] = settingsJSON as NSString }
        do {
            try mgr.connection.startVPNTunnel(options: options)
        } catch {
            try await mgr.loadFromPreferences()
            try mgr.connection.startVPNTunnel(options: options)
            return
        }

        // iOS 覆盖安装时偶尔会让第一次启动请求立即回到 disconnected/disconnecting，且不抛错。
        // 短暂观察状态；只有确认没有进入运行态时才重新加载系统配置并重试一次。
        guard !(await reachesRunningState(mgr.connection)) else { return }
        await waitUntilDisconnected(mgr.connection)
        try await mgr.loadFromPreferences()
        try mgr.connection.startVPNTunnel(options: options)
    }

    private func reachesRunningState(_ connection: NEVPNConnection) async -> Bool {
        for _ in 0..<6 {
            switch connection.status {
            case .connected, .connecting, .reasserting:
                return true
            case .invalid, .disconnected, .disconnecting:
                break
            @unknown default:
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func waitUntilDisconnected(_ connection: NEVPNConnection) async {
        for _ in 0..<8 {
            guard connection.status == .disconnecting else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// 停止隧道。
    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    /// 读取当前连接状态（用于 UI 初始化时同步）。
    func currentStatus() async -> NEVPNStatus {
        if let manager, Self.isMiClashManager(manager) {
            return manager.connection.status
        }
        guard let mgr = try? await loadSavedManager() else { return .invalid }
        return mgr.connection.status
    }

    /// IPC 结果：成功带数据，失败带可显示的原因（便于无 Mac 排查）。
    enum IPCResult {
        case ok(Data)
        case failure(String)
    }

    /// 向运行中的 NE 发送一条 sendProviderMessage 请求并取回响应（不依赖 App Group）。
    /// 优先复用连接时那个 manager（其 connection 状态可靠）；不强行卡 .connected，
    /// 直接尝试发送，失败/空响应都回传具体原因。
    func sendMessage(_ payload: Data) async -> IPCResult {
        let mgr: NETunnelProviderManager
        if let m = manager {
            mgr = m
        } else if let all = try? await NETunnelProviderManager.loadAllFromPreferences(),
                  let m = all.first(where: { Self.isMiClashManager($0) }) {
            self.manager = m
            mgr = m
        } else {
            return .failure("未找到 VPN 配置（请先连接）")
        }

        guard let session = mgr.connection as? NETunnelProviderSession else {
            return .failure("连接对象不是 NETunnelProviderSession（status=\(mgr.connection.status.rawValue)）")
        }
        let st = session.status.rawValue

        return await withCheckedContinuation { cont in
            do {
                try session.sendProviderMessage(payload) { resp in
                    if let resp {
                        cont.resume(returning: .ok(resp))
                    } else {
                        cont.resume(returning: .failure("NE 回传空响应（status=\(st)）"))
                    }
                }
            } catch {
                cont.resume(returning: .failure("sendProviderMessage 抛错：\(error.localizedDescription)（status=\(st)）"))
            }
        }
    }

    /// 取 NE/内核日志（getLogs 命令）。
    func fetchLogs() async -> String {
        let payload = (try? JSONSerialization.data(withJSONObject: ["cmd": "getLogs"]))
            ?? Data("getLogs".utf8)
        switch await sendMessage(payload) {
        case .ok(let data):
            return String(data: data, encoding: .utf8) ?? "(响应非文本)"
        case .failure(let reason):
            return "(取日志失败：\(reason))"
        }
    }
}
