import Foundation
import Combine

@MainActor
final class PO0WhitelistStore: ObservableObject {
    static let shared = PO0WhitelistStore()
    @Published private(set) var configuration = PO0WhitelistStorage.load()
    @Published private(set) var snapshot: PO0WhitelistSnapshot?
    @Published private(set) var isSaving = false
    @Published private(set) var message: String?
    @Published private(set) var validationMessage: String?
    @Published private(set) var isRequestingRefresh = false
    @Published private(set) var readOnlyMessage: String?
    private var isRefreshing = false
    private var lastRefresh = Date.distantPast
    private var stateRevision: UInt64 = 0

    var summary: String {
        if CoreStateManager.shared.isActive, isRequestingRefresh || snapshot?.refreshing == true { return "刷新中" }
        if !configuration.enabled { return "未开启" }
        if !CoreStateManager.shared.isActive { return "等待 VPN 连接" }
        if message != nil { return "需要处理" }
        guard let snapshot, snapshot.configurationID == configuration.id else { return "等待检测" }
        if snapshot.isWorking { return "检测中" }
        if snapshot.results.isEmpty { return "等待检测" }
        return "\(snapshot.successfulCount)/\(snapshot.results.count) 已加白"
    }

    func save(_ draft: PO0WhitelistConfiguration) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        stateRevision &+= 1
        validationMessage = nil
        defer { isSaving = false }
        do {
            var value = try draft.validated()
            value.id = UUID().uuidString
            try PO0WhitelistStorage.save(value)
            configuration = value
            snapshot = nil
            message = nil
            readOnlyMessage = nil
        } catch {
            validationMessage = (error as? PO0SettingsError)?.errorDescription ?? "保存失败，请检查本机存储空间后重试"
            return false
        }
        if CoreStateManager.shared.isActive { await applyConfiguration() }
        return true
    }

    func clearValidationMessage() { validationMessage = nil }

    func refresh(force: Bool = false) async {
        guard !isSaving, !isRefreshing, !isRequestingRefresh else { return }
        guard CoreStateManager.shared.isActive else { return }
        // The default disabled state never sends background IPC queries.
        guard configuration.id != "unconfigured" else { return }
        guard force || Date().timeIntervalSince(lastRefresh) >= 2 else { return }
        if !force, !configuration.enabled, snapshot?.enabled == false,
           snapshot?.refreshing != true, message == nil { return }
        lastRefresh = Date()
        isRefreshing = true
        defer { isRefreshing = false }
        let id = configuration.id
        let revision = stateRevision
        let response = await CoreStateManager.shared.sendMessage(["cmd": "po0WhitelistStatus"])
        guard id == configuration.id, revision == stateRevision else { return }
        guard let value = decode(response) else { return }
        if value.configurationID == id {
            snapshot = value
            message = nil
        } else {
            await applyConfiguration()
        }
    }

    /// Explicit remote GET. Never applies configuration or schedules /add,
    /// including when automatic registration is disabled or the revision differs.
    func refreshReadOnly() async {
        guard CoreStateManager.shared.isActive, !isSaving, !isRequestingRefresh,
              snapshot?.refreshing != true, !configuration.tokens.isEmpty else { return }
        guard let json = try? configuration.json() else { return }
        isRequestingRefresh = true
        stateRevision &+= 1
        let revision = stateRevision
        readOnlyMessage = nil
        defer { isRequestingRefresh = false }
        let id = configuration.id
        let response = await CoreStateManager.shared.sendMessage(["cmd": "refreshPO0Whitelist", "configuration": json])
        guard id == configuration.id, revision == stateRevision, CoreStateManager.shared.isActive else { return }
        if case .ok(let data) = response,
           let value = try? JSONDecoder().decode(PO0WhitelistSnapshot.self, from: data),
           value.configurationID == id {
            snapshot = value
        } else {
            if case .ok(let data) = response,
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let error = object["error"] as? String {
                readOnlyMessage = error
            } else {
                readOnlyMessage = "无法刷新白名单，请稍后重试"
            }
        }
    }

    func checkNow() async {
        guard CoreStateManager.shared.isActive, configuration.enabled, !isSaving, !isRequestingRefresh,
              snapshot?.isWorking != true else { return }
        stateRevision &+= 1
        let revision = stateRevision
        if snapshot?.configurationID != configuration.id {
            await applyConfiguration()
            return
        }
        let id = configuration.id
        let response = await CoreStateManager.shared.sendMessage(["cmd": "checkPO0Whitelist"])
        guard id == configuration.id, revision == stateRevision else { return }
        snapshot = decode(response)
    }

    private func applyConfiguration() async {
        let id = configuration.id
        let revision = stateRevision
        guard let json = try? configuration.json() else { return }
        let response = await CoreStateManager.shared.sendMessage(["cmd": "setPO0Whitelist", "configuration": json])
        guard id == configuration.id, revision == stateRevision else { return }
        snapshot = decode(response)
    }

    private func decode(_ response: TunnelManager.IPCResult) -> PO0WhitelistSnapshot? {
        switch response {
        case .ok(let data):
            if let value = try? JSONDecoder().decode(PO0WhitelistSnapshot.self, from: data) {
                message = nil
                return value
            }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            message = object?["error"] as? String ?? "白名单状态不可用，请重新连接 VPN 后重试"
        case .failure:
            message = "设置已保存，暂未同步到 VPN；请保持连接后重试"
        }
        return nil
    }
}
