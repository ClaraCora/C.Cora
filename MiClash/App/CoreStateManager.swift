import Foundation
import Combine
import NetworkExtension
import WidgetKit

/// 全局状态机（MVVM 中的「全局 Model/Store」）。
///
/// 它是 UI 与底层之间唯一的状态来源：视图只读它的 @Published 属性，
/// 通过它暴露的方法触发动作，数据流单向（动作 → 底层 → 状态变更 → UI 刷新）。
///
/// Phase 0 只聚合 VPN 连接状态；Phase 2+ 会在此挂上 mihomo external-controller
/// 的 API 客户端（流量、节点、日志等），但对 UI 的接口形态保持不变。
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
                self?.status = connection.status
                // 同步给控制中心磁贴（App 在前台时覆盖各种来源的状态变化）
                AppGroupState.vpnConnected = self?.isActive ?? false
                // 主动请求系统刷新磁贴，否则 App 内启停不会同步到控制中心
                ControlCenter.shared.reloadControls(ofKind: ControlWidgetKind.vpn)
                if connection.status == .connected { await self?.fetchNotices() }
                else if connection.status == .disconnected { self?.configNotices = [] }
            }
        }
    }

    /// 初始化或前台回来时主动拉一次当前状态。
    func refreshStatus() async {
        status = await tunnel.currentStatus()
    }

    /// 向运行中的 NE 索取日志（sendProviderMessage，不依赖 App Group）。
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
            // App 主动连接时明确下发配置意图：nil=使用内建 DIRECT，不复活旧订阅缓存。
            let yaml = SubscriptionStore.shared.activeYAML
            let settings = SettingsStore.shared.asJSON()
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
        ControlCenter.shared.reloadControls(ofKind: ControlWidgetKind.vpn)
    }

    /// 向运行中的 NE 发 JSON 命令并取回响应（策略组查询/切换、日志等共用）。
    /// 返回成功数据或可显示的失败原因。
    func sendMessage(_ object: [String: Any]) async -> TunnelManager.IPCResult {
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else {
            return .failure("命令编码失败")
        }
        return await tunnel.sendMessage(payload)
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
