import Foundation
import Combine

@MainActor
final class IOSUpdateBlockStore: ObservableObject {
    static let shared = IOSUpdateBlockStore()
    @Published private(set) var configuration = IOSUpdateBlockStorage.load()
    @Published private(set) var snapshot: IOSUpdateBlockSnapshot?
    @Published private(set) var isSaving = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var message: String?
    private var stateRevision: UInt64 = 0
    private var observedEpoch: UInt64?
    private var needsApplyAfterConnection = false

    var isReady: Bool {
        CoreStateManager.shared.status == .connected || CoreStateManager.shared.status == .reasserting
    }

    var isSynchronized: Bool {
        isReady && observedEpoch == CoreStateManager.shared.connectionEpoch &&
            snapshot?.active == true && snapshot?.configurationID == configuration.id &&
            snapshot?.enabled == configuration.enabled
    }

    var summary: String {
        if isSaving { return "正在同步" }
        if !isReady { return configuration.enabled ? "等待 VPN" : "未开启" }
        if message != nil { return "同步失败" }
        guard isSynchronized else { return "未同步" }
        return configuration.enabled ? "已启用" : "未开启"
    }

    func connectionChanged() {
        let epoch = CoreStateManager.shared.connectionEpoch
        if observedEpoch != epoch || !isReady {
            observedEpoch = epoch
            stateRevision &+= 1
            snapshot = nil
            message = nil
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isSaving else { return }
        isSaving = true
        stateRevision &+= 1
        defer { isSaving = false }
        do {
            let value = IOSUpdateBlockConfiguration(id: UUID().uuidString, enabled: enabled)
            try IOSUpdateBlockStorage.save(value)
            configuration = value
            needsApplyAfterConnection = true
            message = nil
        } catch {
            message = "保存失败，请检查本机存储空间后重试"
            return
        }
        connectionChanged()
        if isReady { await apply() }
    }

    func retry() async {
        guard !isSaving, isReady else { return }
        connectionChanged()
        isSaving = true
        stateRevision &+= 1
        defer { isSaving = false }
        await apply()
    }

    /// A save while connecting can occur just after NE's final file read.
    /// Reconcile that pending save once the system reports connected, even if
    /// the settings page has already been closed. This creates no poll/timer.
    func applyAfterConnectionIfNeeded() async {
        guard needsApplyAfterConnection, isReady, !isSaving else { return }
        await retry()
    }

    // No network probes: this command only reads the two NE counters. A status
    // mismatch stays visible until an explicit retry; refresh never applies.
    func refresh() async {
        connectionChanged()
        guard isReady, !isSaving, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await request(["cmd": "iosUpdateBlockStatus"])
    }

    func resetStats() async {
        guard isReady, !isSaving, !isRefreshing else { return }
        connectionChanged()
        isSaving = true
        stateRevision &+= 1 // Invalidate a pre-reset poll.
        defer { isSaving = false }
        var command: [String: Any] = ["cmd": "resetIOSUpdateBlockStats"]
        if let snapshot { command["session"] = String(snapshot.session) }
        await request(command)
    }

    private func apply() async {
        guard let json = try? configuration.json() else { return }
        var command: [String: Any] = ["cmd": "configureIOSUpdateBlock", "configuration": json]
        if let snapshot { command["session"] = String(snapshot.session) }
        await request(command)
    }

    private func request(_ command: [String: Any]) async {
        let id = configuration.id
        let revision = stateRevision
        let epoch = CoreStateManager.shared.connectionEpoch
        let response = await CoreStateManager.shared.sendMessage(command)
        guard id == configuration.id, revision == stateRevision,
              epoch == CoreStateManager.shared.connectionEpoch, isReady else { return }
        switch response {
        case .ok(let data):
            if let value = try? JSONDecoder().decode(IOSUpdateBlockSnapshot.self, from: data), value.active {
                if let previous = snapshot, previous.session == value.session,
                   previous.revision > value.revision { return }
                snapshot = value
                if value.configurationID == id && value.enabled == configuration.enabled {
                    needsApplyAfterConnection = false
                    message = nil
                } else {
                    message = "设置已保存，尚未同步到当前 VPN，请重试同步"
                }
            } else {
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                message = object?["error"] as? String ?? "当前 VPN 未提供拦截状态，请更新并重新连接后重试"
            }
        case .failure:
            message = "设置已保存，暂未确认 VPN 状态，请重试同步"
        }
    }
}
