import Foundation
import Combine
import Foundation
import NetworkExtension
import WidgetKit

/// 全局状态机（MVVM 中的「全局 Model/Store」）。
///
/// 它是 UI 与底层之间唯一的状态来源：视图只读它的 @Published 属性，
/// 通过它暴露的方法触发动作，数据流单向（动作 → 底层 → 状态变更 → UI 刷新）。
///
/// 运行态控制统一经版本化命令协议；普通签名走 Network Extension IPC，
/// TrollStore 包走共享目录文件 IPC。
@MainActor
final class CoreStateManager: ObservableObject {

    /// 全局单例。App 入口以 @StateObject 持有，确保生命周期与 App 一致。
    static let shared = CoreStateManager()

    /// 连接状态（驱动连接按钮与状态文案）。
    @Published private(set) var status: NEVPNStatus = .invalid

    /// 是否正在执行启停（防抖，避免重复点击）。
    @Published private(set) var isBusy = false

    /// 是否正在把新订阅配置应用到运行中的 VPN。
    @Published private(set) var isReloadingConfiguration = false

    /// 最近一次错误信息（用于 UI 提示）。
    @Published var lastError: String?

    /// mihomo 内核版本号（Phase 1 用于验证核心加载）。
    @Published private(set) var coreVersion: String = "加载中…"

    /// 合并配置时被忽略的不适用内容提示（geo 剔除、进程规则等），连接后从 NE 取。
    @Published var configNotices: [String] = []

    private let tunnel = TunnelManager()
    private var statusObserver: NSObjectProtocol?
    private var reloadRequested = false
    private var pendingReloadSnapshot: String?
    private var pendingReloadHasSnapshot = false
    private var lastReloadSucceeded = true

    private init() {
        // NE 会把已连接状态同步到 App Group。主 App 被系统重新拉起时先用它恢复界面和
        // IPC 轮询，再异步向 NetworkExtension 核实，避免运行中的 VPN 首屏短暂显示空值。
        if AppGroupState.vpnConnected { status = .connected }
        observeVPNStatus()
        // 调用内核取版本号：能返回即证明 mihomo 已正确链接进 App
        coreVersion = MihomoCore.version()
        Task { await refreshStatus() }
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 监听系统 VPN 状态变化，实时同步到 @Published status。
    private func observeVPNStatus() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let connection = note.object as? NEVPNConnection else { return }
            // 通知在主线程队列回调；用 Task 切到 actor 上下文更新隔离状态
            Task { @MainActor in
                guard let self, self.tunnel.owns(connection) else { return }
                self.tunnel.noteStatusChange(connection.status)
                self.status = connection.status
                // 同步给控制中心磁贴（App 在前台时覆盖各种来源的状态变化）
                AppGroupState.vpnConnected = self.isActive
                // 主动请求系统刷新磁贴，否则 App 内启停不会同步到控制中心
                if #available(iOS 18.0, *) {
                    ControlCenter.shared.reloadControls(ofKind: ControlWidgetKind.vpn)
                }
                if connection.status == .connected {
                    await self.fetchNotices()
                }
                else if connection.status == .disconnected { self.configNotices = [] }
            }
        }
    }

    /// 初始化或前台回来时主动拉一次当前状态。
    func refreshStatus() async {
        let currentStatus = await tunnel.currentStatus()
        tunnel.noteStatusChange(currentStatus)
        status = currentStatus
        AppGroupState.vpnConnected = isActive
        if status == .connected || status == .reasserting {
            await fetchNotices()
        } else {
            configNotices = []
        }
    }

    /// 向运行中的 NE 索取日志（普通签名走系统 IPC，TrollStore 走文件 IPC）。
    func fetchLogs() async -> String {
        await tunnel.fetchLogs()
    }

    /// 读取受限的开发者内存诊断，不进入普通日志缓冲。
    func fetchMemoryDiagnostics() async -> String {
        await tunnel.fetchMemoryDiagnostics()
    }

    /// 开发者模式切换后立即同步到正在运行的 NE；下次启动仍会从设置 JSON 恢复。
    @discardableResult
    func setMemoryDiagnostics(_ enabled: Bool) async -> Bool {
        let result = await sendMessage(["cmd": "setMemoryDiagnostics", "enabled": enabled])
        if case .ok(let data) = result,
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           (object["ok"] as? Bool) == true {
            return true
        }
        return false
    }

    func clearMemoryDiagnostics() async -> Result<Void, Error> {
        await tunnel.clearMemoryDiagnostics()
    }

    /// 取配置「不适用内容」提示（连接后调用）。
    func fetchNotices() async {
        let r = await sendMessage(["cmd": "configNotices"])
        if case .ok(let d) = r,
           let arr = (try? JSONSerialization.jsonObject(with: d)) as? [String] {
            configNotices = arr
        }
    }

    /// 用户点连接按钮：根据当前状态决定启停（toggle 语义）。
    func toggleConnection() async {
        if isActive { disconnect() } else { await connect() }
    }

    /// 显式连接（UI / 快捷指令共用）。连接后同步磁贴状态。
    func connect() async {
        guard !isBusy, !isActive else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        do {
            AppGroupState.vpnAutoConnectSuspended = false
            try await startCurrentConfiguration()
            let s = SettingsStore.shared
            if s.alwaysOnVPN {
                try await tunnel.setOnDemandEnabled(true)
            }
            syncWidget(true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 使用当前订阅和设置构造一次完整的 NE 启动请求。
    /// `configYAML` 仅用于失败回滚；正常连接和重载都明确传入当前订阅内容。
    private func startCurrentConfiguration(configYAML: String? = nil,
                                           useCurrentConfiguration: Bool = true) async throws {
        let yaml = useCurrentConfiguration ? SubscriptionStore.shared.activeYAML : configYAML
        // GEO 首次下载与定时更新在主 App 完成，避免 NE 启动阶段联网和冲高内存。
        try await GeoDatabaseManager.shared.prepareForConnection(configYAML: yaml)
        let settings = SettingsStore.shared.asJSON(
            geoAvailable: AppGroup.containerURL != nil,
            applyOverrides: SubscriptionStore.shared.activeOverridesEnabled,
            proxySelections: SubscriptionStore.shared.activeProxySelections)
        let s = SettingsStore.shared
        let opts = TunnelManager.ProtocolOptions(
            includeAllNetworks: s.includeAllNetworks,
            excludeCellularServices: s.excludeCellularServices,
            excludeAPNs: s.excludeAPNs,
            excludeDeviceCommunication: s.excludeDeviceCommunication,
            enforceRoutes: s.enforceRoutes)
        try await tunnel.start(configYAML: yaml, settingsJSON: settings, protocolOptions: opts)
    }

    /// 在运行中的 VPN 上应用刚刚成功下载的当前订阅。
    ///
    /// 采用完整 stop/start，而不是在同一 NE 进程内叠加第二个 mihomo 运行时：
    /// stopTunnel 完成并经过状态确认后才会启动新配置，从根上限制内存峰值。
    /// 多次刷新在重载期间会合并为下一轮，避免并发重启。
    @discardableResult
    func reloadActiveConfigurationIfNeeded(changedSubscriptionID: UUID,
                                           previousYAML: String?) async -> Bool {
        guard SubscriptionStore.shared.selectedID == changedSubscriptionID else { return true }
        guard status == .connected || status == .reasserting else { return true }

        reloadRequested = true
        pendingReloadSnapshot = previousYAML
        pendingReloadHasSnapshot = true
        if isReloadingConfiguration {
            // 让正在进行的 stop/start 消化这次最新请求，再把最终结果返回给调用方。
            while isReloadingConfiguration {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return lastReloadSucceeded
        }

        isReloadingConfiguration = true
        isBusy = true
        var allSucceeded = true
        defer {
            lastReloadSucceeded = allSucceeded
            isReloadingConfiguration = false
            isBusy = false
            reloadRequested = false
            pendingReloadSnapshot = nil
            pendingReloadHasSnapshot = false
        }

        while reloadRequested {
            reloadRequested = false
            let oldYAML = pendingReloadHasSnapshot ? pendingReloadSnapshot : nil
            pendingReloadSnapshot = nil
            pendingReloadHasSnapshot = false
            allSucceeded = await performConfigurationReload(previousYAML: oldYAML)
                && allSucceeded
        }
        return allSucceeded
    }

    private func performConfigurationReload(previousYAML: String?) async -> Bool {
        guard status == .connected || status == .reasserting else { return true }

        let alwaysOn = SettingsStore.shared.alwaysOnVPN
        var stopped = false
        lastError = nil
        do {
            // 防止 Connect On Demand 在 stop/start 间隙抢先拉起旧配置。
            if alwaysOn {
                try await tunnel.setOnDemandEnabled(false)
            }

            try await tunnel.stopAndWaitUntilDisconnected()
            stopped = true
            syncWidget(false)

            try await startCurrentConfiguration()
            guard await tunnel.waitUntilConnected() else {
                throw NSError(domain: "Cora.CoreStateManager", code: -20,
                              userInfo: [NSLocalizedDescriptionKey: "新配置启动后未进入已连接状态"])
            }
            if alwaysOn && !AppGroupState.vpnAutoConnectSuspended {
                try await tunnel.setOnDemandEnabled(true)
            }
            syncWidget(true)
        } catch {
            let newError = error.localizedDescription
            if !stopped {
                // 停止超时不等于旧运行时已经退出；仅在确认它最终断开后才允许回滚。
                do {
                    try await tunnel.stopAndWaitUntilDisconnected(timeout: 2)
                    stopped = true
                } catch {
                    stopped = false
                }
                if !stopped {
                    lastError = "配置重载失败：" + newError
                    return false
                }
                syncWidget(false)
            }

            // 启动阶段失败时也先确认失败的 NE 已退出，再尝试回滚，
            // 避免回滚启动与失败运行时重叠。
            try? await tunnel.stopAndWaitUntilDisconnected()

            // 新配置失败时，旧配置仍在内存中的副本只保留这一份；新 NE 已确认退出后才回滚。
            do {
                try await startCurrentConfiguration(configYAML: previousYAML,
                                                    useCurrentConfiguration: false)
                guard await tunnel.waitUntilConnected() else {
                    throw NSError(domain: "Cora.CoreStateManager", code: -21,
                                  userInfo: [NSLocalizedDescriptionKey: "旧配置恢复后未进入已连接状态"])
                }
                if alwaysOn && !AppGroupState.vpnAutoConnectSuspended {
                    try await tunnel.setOnDemandEnabled(true)
                }
                syncWidget(true)
                lastError = "新配置加载失败，已恢复旧配置：" + newError
                return false
            } catch {
                lastError = "配置重载失败且旧配置恢复失败：" + newError
                    + "；" + error.localizedDescription
                syncWidget(false)
                return false
            }
        }
        return true
    }

    /// 显式断开（UI / 快捷指令共用）。断开后同步磁贴状态。
    func disconnect() {
        guard isActive else { return }
        let shouldSuspend = SettingsStore.shared.alwaysOnVPN
        AppGroupState.vpnAutoConnectSuspended = shouldSuspend
        Task {
            if shouldSuspend {
                try? await tunnel.setOnDemandEnabled(false)
            }
            tunnel.stop()
        }
        syncWidget(false)
    }

    /// 设置页切换自动连接时调用。关闭只撤销自动连接，不强制断开当前 VPN。
    func setAlwaysOnVPN(_ enabled: Bool) async {
        do {
            if enabled {
                AppGroupState.vpnAutoConnectSuspended = false
                try await tunnel.setOnDemandEnabled(true)
            } else {
                AppGroupState.vpnAutoConnectSuspended = false
                try await tunnel.setOnDemandEnabled(false)
            }
            SettingsStore.shared.alwaysOnVPN = enabled
        } catch {
            lastError = error.localizedDescription
            if enabled {
                SettingsStore.shared.alwaysOnVPN = false
            }
        }
    }

    /// 写共享状态 + 请求刷新控制中心磁贴（乐观，NE 启停后还会再写一次确认）。
    private func syncWidget(_ connected: Bool) {
        AppGroupState.vpnConnected = connected
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: ControlWidgetKind.vpn)
        }
    }

    /// 向运行中的 NE 发 JSON 命令并取回响应（策略组查询/切换、日志等共用）。
    /// 返回成功数据或可显示的失败原因。
    func sendMessage(_ object: [String: Any]) async -> TunnelManager.IPCResult {
        var request = object
        request["v"] = 1
        guard let payload = try? JSONSerialization.data(withJSONObject: request) else {
            return .failure("命令编码失败")
        }
        let command = request["cmd"] as? String ?? ""
        let timeout: TimeInterval
        switch command {
        case "groupDelay":
            let milliseconds = (request["timeout"] as? NSNumber)?.doubleValue ?? 5_000
            let requestedCount = (request["count"] as? NSNumber)?.intValue ?? 0
            // The NE may be on cellular, where group tests use two workers.
            // Use that conservative estimate for the IPC deadline so a
            // bounded test is not mistaken for an unresponsive extension.
            let targetCount = max(1, requestedCount)
            let workerWaves = (targetCount + 1) / 2
            timeout = min(190, max(10, Double(workerWaves) * milliseconds / 1_000 + 10))
        case "proxyDelay":
            let milliseconds = (request["timeout"] as? NSNumber)?.doubleValue ?? 5_000
            timeout = max(10, milliseconds / 1_000 + 5)
        case "proxyDelays":
            let requestedMilliseconds = (request["timeout"] as? NSNumber)?.doubleValue ?? 5_000
            let milliseconds = requestedMilliseconds > 0 ? requestedMilliseconds : 5_000
            let requestedCount = (request["count"] as? NSNumber)?.intValue ?? 0
            let encodedCount = (request["targets"] as? [Any])?.count ?? 0
            let targetCount = min(256, max(1, max(requestedCount, encodedCount)))
            // Batch tests use two workers on cellular; use this lower bound
            // for the IPC deadline even when the current interface is Wi-Fi.
            let workerWaves = (targetCount + 1) / 2
            timeout = min(190, max(10, Double(workerWaves) * milliseconds / 1_000 + 10))
        case "scriptFetch":
            let nestedRequest = request["request"] as? [String: Any]
            let milliseconds = (nestedRequest?["timeout"] as? NSNumber)?.doubleValue ?? 5_000
            // Leave a small IPC margin around the mihomo request itself. The
            // script runner caps the nested request at 15 seconds.
            timeout = min(20, max(10, milliseconds / 1_000 + 3))
        case "updateProxyProviders", "updateProxyProvider",
             "updateRuleProviders", "updateRuleProvider":
            timeout = 120
        default:
            timeout = 10
        }
        return await tunnel.sendMessage(payload, timeout: timeout)
    }

    /// 给 UI 用的友好状态文案。
    var statusText: String {
        switch status {
        case .invalid:      return "未配置"
        case .disconnected: return "已断开"
        case .connecting:   return "连接中…"
        case .connected:    return "已连接"
        case .reasserting:  return "重连中…"
        case .disconnecting:return "断开中…"
        @unknown default:   return "未知"
        }
    }

    /// 是否处于「已连接/连接中」语义（用于按钮样式）。
    var isActive: Bool {
        status == .connected || status == .connecting || status == .reasserting
    }
}
