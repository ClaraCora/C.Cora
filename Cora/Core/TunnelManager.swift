import Foundation
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
    private var persistedNELogAttemptID: String?
    private var appInitiatedStartupAttemptID: String?

    private static let startupPollNanoseconds: UInt64 = 250_000_000
    private static let startupPollCount = 40
    private static let initialTransitionGracePolls = 8
    private static let shutdownPollNanoseconds: UInt64 = 100_000_000

    /// 加载（或创建）Cora 的 VPN 描述文件。
    /// iOS 要求 VPN 配置先 saveToPreferences 落到「设置 > VPN」里，用户授权一次后方可启动。
    private func loadOrCreateManager(options: ProtocolOptions) async throws -> NETunnelProviderManager {
        let existing = try await NETunnelProviderManager.loadAllFromPreferences()
        let mgr = existing.first { Self.isCoraManager($0) } ?? NETunnelProviderManager()
        let proto = (mgr.protocolConfiguration as? NETunnelProviderProtocol)
            ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppConstants.tunnelBundleID
        proto.serverAddress = "Cora"
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

        // 落盘到系统偏好；首次会弹「允许 Cora 添加 VPN 配置」
        try await mgr.saveToPreferences()
        // 存盘后需重新 load 一次，拿到系统补全后的对象（否则 startVPNTunnel 可能报错）
        try await mgr.loadFromPreferences()

        self.manager = mgr
        return mgr
    }

    /// 只读加载已保存配置。状态查询不能顺带创建/保存配置，否则覆盖安装后容易刷新旧快照。
    private func loadSavedManager() async throws -> NETunnelProviderManager? {
        let existing = try await NETunnelProviderManager.loadAllFromPreferences()
        let mgr = existing.first { Self.isCoraManager($0) }
        self.manager = mgr
        return mgr
    }

    private static func isCoraManager(_ manager: NETunnelProviderManager) -> Bool {
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
            == AppConstants.tunnelBundleID
    }

    /// 只接受当前 Cora manager 发出的状态通知，避免其它 VPN 或旧连接污染 UI。
    func owns(_ connection: NEVPNConnection) -> Bool {
        guard let manager else { return false }
        return connection === manager.connection
    }

    /// A new `.connecting` transition without an App-owned attempt came from
    /// Control Center or On-Demand. Do not let that session reuse old log data.
    func noteStatusChange(_ status: NEVPNStatus) {
        switch status {
        case .connecting:
            if appInitiatedStartupAttemptID == nil {
                persistedNELogAttemptID = nil
            }
        case .connected, .disconnecting, .disconnected, .invalid:
            appInitiatedStartupAttemptID = nil
        case .reasserting:
            break
        @unknown default:
            appInitiatedStartupAttemptID = nil
        }
    }

    /// 启动隧道，并把订阅配置 + 设置经 options 下发给 NE（不依赖 App Group）。
    /// App 启动始终携带 config：非空=订阅，空串=明确 DIRECT；系统无 options 重连才复用缓存。
    func start(configYAML: String?, settingsJSON: String, protocolOptions: ProtocolOptions) async throws {
        let mgr = try await loadOrCreateManager(options: protocolOptions)
        var options: [String: NSObject] = ["config": (configYAML ?? "") as NSString]
        if !settingsJSON.isEmpty { options["settings"] = settingsJSON as NSString }
        let startupAttemptID = UUID().uuidString
        options["startupAttemptID"] = startupAttemptID as NSString
        persistedNELogAttemptID = Self.resetPersistedNELog() ? startupAttemptID : nil
        appInitiatedStartupAttemptID = startupAttemptID
        do {
            try mgr.connection.startVPNTunnel(options: options)
        } catch {
            if appInitiatedStartupAttemptID == startupAttemptID {
                appInitiatedStartupAttemptID = nil
            }
            throw error
        }

        switch await observeStartup(mgr.connection) {
        case .connected:
            if appInitiatedStartupAttemptID == startupAttemptID {
                appInitiatedStartupAttemptID = nil
            }
            return
        case .stillConnecting:
            return
        case .failed:
            if appInitiatedStartupAttemptID == startupAttemptID {
                appInitiatedStartupAttemptID = nil
            }
            if let error = await lastDisconnectError(mgr.connection) {
                throw error
            }
            if let attemptID = persistedNELogAttemptID,
               Self.persistedNELog(for: attemptID) == nil {
                throw Self.startupError(
                    "未收到 NE 启动日志，隧道扩展可能在初始化阶段退出；请重新连接，若仍失败请重新安装此版本的 VPN 配置")
            }
            let message = persistedNELogAttemptID != nil
                ? "隧道在启动阶段断开，请查看日志中的具体错误"
                : "隧道在启动阶段断开，本次启动未建立共享日志回退"
            throw Self.startupError(message)
        }
    }

    private static func resetPersistedNELog() -> Bool {
        // 不要在 NE 启动前清空 ne.log。FileLog.reset() 会在扩展进程内
        // 把旧会话轮换为 ne.previous.log；这里仅报告共享目录是否可用。
        guard let url = AppGroup.containerURL else { return false }
        return FileManager.default.isWritableFile(atPath: url.path)
    }

    private static func persistedNELog(for attemptID: String) -> String? {
        guard let url = AppGroup.containerURL?.appendingPathComponent("ne.log"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let marker = "startup-attempt=\(attemptID)"
        guard let markerRange = text.range(of: marker, options: .backwards) else { return nil }
        let lineStart = text[..<markerRange.lowerBound].lastIndex(of: "\n")
            .map { text.index(after: $0) } ?? text.startIndex
        let value = String(text[lineStart...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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
        NSError(domain: "Cora.TunnelManager", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// 停止隧道。
    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    /// 停止隧道并等待 Network Extension 完成 stopTunnel 回调。
    ///
    /// 配置重载必须等旧的 mihomo executor、连接和 DNS 资源释放后再启动，
    /// 否则新旧运行时会在短时间内同时占用 NE 内存，容易触发 Jetsam。
    func stopAndWaitUntilDisconnected(timeout: TimeInterval = 15) async throws {
        let mgr = try await loadSavedManager()
        guard let connection = mgr?.connection else { return }

        switch connection.status {
        case .disconnected, .invalid:
            return
        default:
            connection.stopVPNTunnel()
        }

        let deadline = Date().addingTimeInterval(max(1, timeout))
        while connection.status != .disconnected && connection.status != .invalid {
            if Date() >= deadline {
                throw Self.startupError("等待旧 VPN 完全退出超时")
            }
            try await Task.sleep(nanoseconds: Self.shutdownPollNanoseconds)
        }

        // 状态切到 disconnected 后，给系统一个很短的机会完成 provider 的收尾。
        // 这里不启动新任务，也不复制配置数据，只避免 stopTunnel 的尾部工作与新启动重叠。
        try await Task.sleep(nanoseconds: Self.shutdownPollNanoseconds * 2)
    }

    /// 等待已经启动的隧道真正进入 connected。用于配置重载，避免仍处于 connecting
    /// 时就把重载标记为成功，导致失败无法自动回滚。
    func waitUntilConnected(timeout: TimeInterval = 20) async -> Bool {
        guard let connection = manager?.connection else { return false }
        let deadline = Date().addingTimeInterval(max(1, timeout))
        while Date() < deadline {
            switch connection.status {
            case .connected:
                return true
            case .disconnected, .disconnecting, .invalid:
                return false
            default:
                try? await Task.sleep(nanoseconds: Self.shutdownPollNanoseconds)
            }
        }
        return connection.status == .connected
    }

    /// 配置 iOS Connect On Demand。真正的受监管设备 Always-On 仍由 MDM 管理，
    /// 普通 App 使用该能力实现重启和网络变化后的系统自动重连。
    func setOnDemandEnabled(_ enabled: Bool) async throws {
        guard let mgr = try await loadSavedManager() else {
            throw NSError(domain: "Cora.TunnelManager", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "请先连接一次 VPN，再启用自动连接"])
        }
        // A user can disable the profile from Settings or the control center;
        // keep the saved profile usable so a later manual start is still allowed.
        mgr.isEnabled = true
        mgr.isOnDemandEnabled = enabled
        mgr.onDemandRules = enabled ? [NEOnDemandRuleConnect()] : []
        try await mgr.saveToPreferences()
        try await mgr.loadFromPreferences()
        manager = mgr
    }

    /// 读取当前连接状态（用于 UI 初始化时同步）。
    func currentStatus() async -> NEVPNStatus {
        if let manager, Self.isCoraManager(manager) {
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
            if case .ok(let data) = fileResult {
                return await expandChunkedFileResponse(data, timeout: timeout)
            }

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

    private func expandChunkedFileResponse(_ initial: Data,
                                           timeout: TimeInterval) async -> IPCResult {
        guard let descriptor = (try? JSONSerialization.jsonObject(with: initial))
                as? [String: Any],
              descriptor["_coraTransfer"] as? String == "chunked-v1" else {
            return .ok(initial)
        }
        guard let token = descriptor["token"] as? String,
              UUID(uuidString: token) != nil,
              let total = (descriptor["total"] as? NSNumber)?.intValue,
              total > 0, total <= 8 * 1_024 * 1_024 else {
            return .failure("Tunnel 返回了无效的分块响应描述")
        }

        var response = Data()
        response.reserveCapacity(total)
        while response.count < total {
            guard let request = try? JSONSerialization.data(withJSONObject: [
                "v": 1,
                "cmd": "readResponseChunk",
                "token": token,
                "offset": response.count,
            ]) else {
                return .failure("分块响应请求编码失败")
            }
            switch await sendTrollStoreMessage(request, timeout: timeout) {
            case .failure(let reason):
                return .failure("读取 Tunnel 分块响应失败：\(reason)")
            case .ok(let chunk):
                guard !chunk.isEmpty, response.count + chunk.count <= total else {
                    return .failure("Tunnel 分块响应不完整")
                }
                response.append(chunk)
            }
        }
        return response.count == total ? .ok(response) : .failure("Tunnel 分块响应长度不匹配")
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
                  let m = all.first(where: { Self.isCoraManager($0) }) {
            self.manager = m
            mgr = m
        } else {
            return .failure("未找到 VPN 配置（请先连接）")
        }

        guard let session = mgr.connection as? NETunnelProviderSession else {
            return .failure("连接对象不是 NETunnelProviderSession（status=\(mgr.connection.status.rawValue)）")
        }
        let initial = await sendRawProviderMessage(payload, session: session, timeout: timeout)
        guard case .ok(let data) = initial else { return initial }
        return await expandChunkedResponse(data, session: session, timeout: timeout)
    }

    private func sendRawProviderMessage(_ payload: Data,
                                        session: NETunnelProviderSession,
                                        timeout: TimeInterval) async -> IPCResult {
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

    private func expandChunkedResponse(_ initial: Data,
                                       session: NETunnelProviderSession,
                                       timeout: TimeInterval) async -> IPCResult {
        guard let descriptor = (try? JSONSerialization.jsonObject(with: initial))
                as? [String: Any],
              descriptor["_coraTransfer"] as? String == "chunked-v1" else {
            return .ok(initial)
        }
        guard let token = descriptor["token"] as? String,
              UUID(uuidString: token) != nil,
              let total = (descriptor["total"] as? NSNumber)?.intValue,
              total > 0, total <= 8 * 1_024 * 1_024 else {
            return .failure("NE 返回了无效的分块响应描述")
        }

        var response = Data()
        response.reserveCapacity(total)
        while response.count < total {
            guard let request = try? JSONSerialization.data(withJSONObject: [
                "v": 1,
                "cmd": "readResponseChunk",
                "token": token,
                "offset": response.count,
            ]) else {
                return .failure("分块响应请求编码失败")
            }
            switch await sendRawProviderMessage(request, session: session, timeout: timeout) {
            case .failure(let reason):
                return .failure("读取 NE 分块响应失败：\(reason)")
            case .ok(let chunk):
                guard !chunk.isEmpty, response.count + chunk.count <= total else {
                    return .failure("NE 分块响应不完整")
                }
                response.append(chunk)
            }
        }
        return response.count == total ? .ok(response) : .failure("NE 分块响应长度不匹配")
    }

    /// 取 NE/内核日志（getLogs 命令）。
    func fetchLogs() async -> String {
        let payload = (try? JSONSerialization.data(withJSONObject: ["v": 1, "cmd": "getLogs"]))
            ?? Data("getLogs".utf8)
        switch await sendMessage(payload) {
        case .ok(let data):
            return String(data: data, encoding: .utf8) ?? "(响应非文本)"
        case .failure(let reason):
            if let attemptID = persistedNELogAttemptID,
               let persisted = Self.persistedNELog(for: attemptID) {
                return "===== ne（共享文件回退）=====\n\(persisted)\n\n(实时 IPC 不可用：\(reason))"
            }
            if let persisted = Self.persistedNELogs() {
                return "===== ne（共享文件回退）=====\n\(persisted)\n\n(实时 IPC 不可用：\(reason))"
            }
            if persistedNELogAttemptID != nil {
                return "(未收到 NE 启动日志；扩展可能在初始化阶段退出。实时 IPC：\(reason))"
            }
            return "(实时 IPC 不可用，且本次启动未建立共享日志回退：\(reason))"
        }
    }

    /// 导出有界的 NE 日志文件（当前会话 + 上一会话），供 App 分享或存档。
    func exportNELog() async -> String {
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "v": 1, "cmd": "exportNELog"
        ])) ?? Data(#"{"cmd":"exportNELog"}"#.utf8)
        switch await sendMessage(payload, timeout: 20) {
        case .ok(let data):
            return String(data: data, encoding: .utf8) ?? "(NE 日志不是有效文本)"
        case .failure(let reason):
            if let persisted = Self.persistedNELogs() {
                return persisted + "\n\n(实时 IPC 不可用：\(reason))"
            }
            return "NE 日志导出失败：\(reason)"
        }
    }

    private static func persistedNELogs() -> String? {
        guard let directory = AppGroup.containerURL else { return nil }
        let names = ["ne.previous.log", "ne.log"]
        var sections: [String] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            do {
                let size = try handle.seekToEnd()
                let offset = size > 512 * 1024 ? size - 512 * 1024 : 0
                try handle.seek(toOffset: offset)
                let data = try handle.readToEnd() ?? Data()
                guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { continue }
                sections.append("===== \(name) =====\n\(text)")
            } catch {
                continue
            }
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// 取受限的 NE 内存诊断 NDJSON。与完整日志分开，避免日志尾部内容干扰 App 侧解析。
    func fetchMemoryDiagnostics() async -> String {
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "v": 1, "cmd": "memoryDiagnostics"
        ])) ?? Data(#"{"cmd":"memoryDiagnostics"}"#.utf8)
        switch await sendMessage(payload, timeout: 15) {
        case .ok(let data):
            return String(data: data, encoding: .utf8) ?? "(响应非文本)"
        case .failure(let reason):
            return "(内存诊断不可用：\(reason))"
        }
    }

    /// 清理 NE 侧诊断文件；普通模式下不会创建这些文件。
    func clearMemoryDiagnostics() async -> Result<Void, Error> {
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "v": 1, "cmd": "clearMemoryDiagnostics"
        ])) ?? Data(#"{"cmd":"clearMemoryDiagnostics"}"#.utf8)
        switch await sendMessage(payload, timeout: 15) {
        case .ok(let data):
            if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               (object["ok"] as? Bool) == true {
                return .success(())
            }
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
                ?? "清理诊断失败"
            return .failure(NSError(domain: "Cora.MemoryDiagnostics", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: message]))
        case .failure(let reason):
            return .failure(NSError(domain: "Cora.MemoryDiagnostics", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: reason]))
        }
    }
}
