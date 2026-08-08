import Foundation
import NetworkExtension

/// 负责与系统 VPN 子系统打交道：安装/加载 VPN 描述文件、启停隧道、上报状态。
///
/// Phase 0 只做最小闭环——把 NE 隧道拉起/停掉，验证权限链路与 VPN 图标。
/// Phase 2 起，这里会通过 `sendProviderMessage` 向 NE 传配置路径、查询运行态。
///
/// 设计上它是「控制面」的底层，不持有 UI 状态；UI 状态由 CoreStateManager 聚合。
final class TunnelManager {

    private enum StartOutcome {
        case connected
        case stillConnecting
        case failed
    }

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

    private static let startupPollNanoseconds: UInt64 = 250_000_000
    private static let startupPollCount = 40
    private static let initialTransitionGracePolls = 8

    /// 加载（或创建）MiClash 的 VPN 描述文件。
    /// iOS 要求 VPN 配置先 saveToPreferences 落到「设置 > VPN」里，用户授权一次后方可启动。
    private func loadOrCreateManager(options: ProtocolOptions) async throws -> NETunnelProviderManager {
        let existing = try await NETunnelProviderManager.loadAllFromPreferences()
        let mgr = existing.first { Self.isMiClashManager($0) } ?? NETunnelProviderManager()
        let proto = (mgr.protocolConfiguration as? NETunnelProviderProtocol)
            ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppConstants.tunnelBundleID
        proto.serverAddress = "MiClash"
        proto.includeAllNetworks = options.includeAllNetworks
        proto.enforceRoutes = options.enforceRoutes
        proto.excludeCellularServices = options.excludeCellularServices
        proto.excludeAPNs = options.excludeAPNs
        if #available(iOS 17.4, *) {
            proto.excludeDeviceCommunication = options.excludeDeviceCommunication
        }

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

    /// 只接受当前 MiClash manager 发出的状态通知，避免其它 VPN 或旧连接污染 UI。
    func owns(_ connection: NEVPNConnection) -> Bool {
        guard let manager else { return false }
        return connection === manager.connection
    }

    /// 启动隧道，并把订阅配置 + 设置经 options 下发给 NE（不依赖 App Group）。
    /// App 启动始终携带 config：非空=订阅，空串=明确 DIRECT；系统无 options 重连才复用缓存。
    func start(configYAML: String?, settingsJSON: String, protocolOptions: ProtocolOptions) async throws {
        let mgr = try await loadOrCreateManager(options: protocolOptions)
        var options: [String: NSObject] = ["config": (configYAML ?? "") as NSString]
        if !settingsJSON.isEmpty { options["settings"] = settingsJSON as NSString }
        try mgr.connection.startVPNTunnel(options: options)

        switch await observeStartup(mgr.connection) {
        case .connected, .stillConnecting:
            return
        case .failed:
            if let error = await lastDisconnectError(mgr.connection) {
                throw error
            }
            throw Self.startupError("隧道在启动阶段断开，请查看日志中的具体错误")
        }
    }

    private func observeStartup(_ connection: NEVPNConnection) async -> StartOutcome {
        var enteredStartup = false

        for poll in 0..<Self.startupPollCount {
            switch connection.status {
            case .connected:
                return .connected
            case .connecting, .reasserting:
                enteredStartup = true
            case .disconnecting, .invalid:
                return .failed
            case .disconnected:
                if enteredStartup || poll >= Self.initialTransitionGracePolls {
                    return .failed
                }
            @unknown default:
                break
            }
            try? await Task.sleep(nanoseconds: Self.startupPollNanoseconds)
        }

        // 内核解析大型配置时可能较慢；仍处于 connecting 时交给状态监听继续跟踪。
        return enteredStartup ? .stillConnecting : .failed
    }

    private func lastDisconnectError(_ connection: NEVPNConnection) async -> Error? {
        for _ in 0..<8 {
            guard connection.status == .disconnecting else { break }
            try? await Task.sleep(nanoseconds: Self.startupPollNanoseconds)
        }
        return await withCheckedContinuation { continuation in
            connection.fetchLastDisconnectError { error in
                continuation.resume(returning: error)
            }
        }
    }

    private static func startupError(_ message: String) -> NSError {
        NSError(domain: "MiClash.TunnelManager", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
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

    private final class IPCReplyGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<IPCResult, Never>?

        init(_ continuation: CheckedContinuation<IPCResult, Never>) {
            self.continuation = continuation
        }

        func resolve(_ result: IPCResult) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: result)
        }
    }

    /// TrollStore 的 platform/no-sandbox 身份可能无法使用 NetworkExtension XPC，
    /// 因此该构建优先走共享目录中的原子文件通道。普通签名仍只走官方 IPC。
    func sendMessage(_ payload: Data, timeout: TimeInterval = 10) async -> IPCResult {
        if TrollStoreIPC.isEnabled {
            let fileResult = await sendTrollStoreMessage(payload, timeout: timeout)
            if case .ok = fileResult { return fileResult }

            // 兼容仍在运行的旧 Tunnel 扩展：更新 App 后尚未断开重连时，旧进程
            // 还没有文件 IPC server，短暂尝试一次系统通道并合并诊断信息。
            let systemResult = await sendProviderMessage(payload, timeout: min(timeout, 3))
            if case .ok = systemResult { return systemResult }
            if case .failure(let fileReason) = fileResult,
               case .failure(let systemReason) = systemResult {
                return .failure("巨魔文件 IPC：\(fileReason)；系统 IPC：\(systemReason)")
            }
        }
        return await sendProviderMessage(payload, timeout: timeout)
    }

    private func sendTrollStoreMessage(_ payload: Data,
                                       timeout: TimeInterval) async -> IPCResult {
        let id = UUID()
        guard let requestURL = TrollStoreIPC.requestURL(for: id),
              let responseURL = TrollStoreIPC.responseURL(for: id) else {
            return .failure("共享控制目录不可用")
        }
        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: responseURL)
        }

        do {
            try payload.write(to: requestURL, options: .atomic)
        } catch {
            return .failure("写入请求失败：\(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return .failure("请求已取消") }
            if FileManager.default.fileExists(atPath: responseURL.path),
               let response = try? Data(contentsOf: responseURL) {
                guard !response.isEmpty else { return .failure("Tunnel 回传空响应") }
                return .ok(response)
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return .failure("超时（\(Int(timeout)) 秒，请断开并重连一次 VPN）")
    }

    /// 向运行中的 NE 发送一条 sendProviderMessage 请求并取回响应。
    /// 优先复用连接时那个 manager（其 connection 状态可靠）；不强行卡 .connected，
    /// 直接尝试发送，失败/空响应都回传具体原因。
    private func sendProviderMessage(_ payload: Data,
                                     timeout: TimeInterval) async -> IPCResult {
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
            let gate = IPCReplyGate(cont)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.resolve(.failure("NE IPC 超时（\(Int(timeout)) 秒，status=\(st)）"))
            }
            do {
                try session.sendProviderMessage(payload) { resp in
                    if let resp {
                        gate.resolve(.ok(resp))
                    } else {
                        gate.resolve(.failure("NE 回传空响应（status=\(st)）"))
                    }
                }
            } catch {
                gate.resolve(.failure(
                    "sendProviderMessage 抛错：\(error.localizedDescription)（status=\(st)）"))
            }
        }
    }

    /// 取 NE/内核日志（getLogs 命令）。
    func fetchLogs() async -> String {
        let payload = (try? JSONSerialization.data(withJSONObject: ["v": 1, "cmd": "getLogs"]))
            ?? Data("getLogs".utf8)
        switch await sendMessage(payload) {
        case .ok(let data):
            return String(data: data, encoding: .utf8) ?? "(响应非文本)"
        case .failure(let reason):
            return "(取日志失败：\(reason))"
        }
    }
}
