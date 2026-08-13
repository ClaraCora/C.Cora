import Foundation
import Combine
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

    /// 最近一次错误信息（用于 UI 提示）。
    @Published var lastError: String?

    /// mihomo 内核版本号（Phase 1 用于验证核心加载）。
    @Published private(set) var coreVersion: String = "加载中…"

    /// 合并配置时被忽略的不适用内容提示（geo 剔除、进程规则等），连接后从 NE 取。
    @Published var configNotices: [String] = []

    private let tunnel = TunnelManager()
    private var statusObserver: NSObjectProtocol?

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
        status = await tunnel.currentStatus()
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
            // 先确定当前配置，GEO/ASN 下载地址与所需数据库均从该配置解析。
            let yaml = SubscriptionStore.shared.activeYAML
            // GEO 首次下载与定时更新在主 App 完成，避免 NE 启动阶段联网和冲高内存。
            try await GeoDatabaseManager.shared.prepareForConnection(configYAML: yaml)
            // App 主动连接时明确下发配置意图：nil=使用内建 DIRECT，不复活旧订阅缓存。
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
            syncWidget(true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 显式断开（UI / 快捷指令共用）。断开后同步磁贴状态。
    func disconnect() {
        guard isActive else { return }
        tunnel.stop()
        syncWidget(false)
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
        case "groupDelay", "proxyDelay":
            let milliseconds = (request["timeout"] as? NSNumber)?.doubleValue ?? 5_000
            timeout = max(10, milliseconds / 1_000 + 5)
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
