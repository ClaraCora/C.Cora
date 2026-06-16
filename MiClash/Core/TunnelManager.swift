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

    /// 启动隧道，并把订阅配置 + 设置经 options 下发给 NE（不依赖 App Group）。
    /// configYAML 为空串时 NE 会用缓存/DIRECT 兜底。
    func start(configYAML: String, settingsJSON: String) async throws {
        let mgr = try await loadOrCreateManager()
        var options: [String: NSObject] = [:]
        if !configYAML.isEmpty { options["config"] = configYAML as NSString }
        if !settingsJSON.isEmpty { options["settings"] = settingsJSON as NSString }
        try mgr.connection.startVPNTunnel(options: options)
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
        } else if let all = try? await NETunnelProviderManager.loadAllFromPreferences(), let m = all.first {
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
