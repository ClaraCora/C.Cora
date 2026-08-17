import Foundation

struct ProxyGroupNode: Identifiable {
    struct ID: Hashable {
        let group: String
        let index: Int
    }

    let id: ID
    let name: String
    let normalizedSearchText: String
}

/// A node test is scoped to one strategy group. This prevents equal node names
/// in different groups from sharing an in-progress state.
struct ProxyNodeTestKey: Hashable {
    let group: String
    let node: String
}

/// 一个策略组。
struct ProxyGroup: Identifiable {
    var id: String { name }
    let name: String
    let type: String      // Selector / URLTest / Fallback / LoadBalance / Relay ...
    let now: String       // 当前选中/生效的节点
    let all: [String]     // 成员节点名（按配置顺序）
    let icon: URL?        // 配置里 proxy-groups[].icon，内核经 /proxies 原样回传
    let nodes: [ProxyGroupNode]

    init(name: String,
         type: String,
         now: String,
         all: [String],
         icon: URL?) {
        self.name = name
        self.type = type
        self.now = now
        self.all = all
        self.icon = icon
        self.nodes = all.enumerated().map { index, node in
            return ProxyGroupNode(
                id: .init(group: name, index: index),
                name: node,
                normalizedSearchText: node.lowercased())
        }
    }

    /// 只有 Selector 可手动点选；URLTest/Fallback 等是自动组。
    var selectable: Bool { type.caseInsensitiveCompare("Selector") == .orderedSame }
}

/// 将引用策略组解析为当前实际出口节点。延迟只存实际节点，显示时再把结果映射回引用项，
/// 使“总模式 -> 地区分组 -> 节点”的多个入口始终展示同一条测速结果。
enum ProxyDelayResolver {
    /// 返回延迟查询优先级：实际节点优先，其次是引用链上的分组名（兼容旧会话数据）。
    static func keys(for name: String, groups: [ProxyGroup]) -> [String] {
        var lookup: [String: ProxyGroup] = [:]
        for group in groups {
            lookup[group.name] = group
        }

        var current = name
        var path = [name]
        var visited: Set<String> = [name]
        while let group = lookup[current] {
            let selected = group.now.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selected.isEmpty, visited.insert(selected).inserted else { break }
            current = selected
            path.append(selected)
        }

        var result = [current]
        for alias in path.reversed() where !result.contains(alias) {
            result.append(alias)
        }
        return result
    }

    static func storageKey(for name: String, groups: [ProxyGroup]) -> String {
        keys(for: name, groups: groups).first ?? name
    }

    static func delay(for name: String,
                      groups: [ProxyGroup],
                      delays: [String: Int]) -> Int? {
        for key in keys(for: name, groups: groups) {
            if let value = delays[key] { return value }
        }
        return nil
    }
}

/// 策略组查询与节点切换：经统一控制通道直连 NE 内核
/// （queryProxies / selectProxy / groupDelay），不走 HTTP API。
///
/// 排序：用 GLOBAL 组的 all 顺序（即配置里 proxy-groups 的定义顺序），不再按字母乱排。
/// 模式感知：global 只显示 GLOBAL 组；rule 显示其余策略组；direct 不涉及节点选择。
@MainActor
final class ProxyController: ObservableObject {

    @Published private(set) var groups: [ProxyGroup] = []
    @Published private(set) var mode: String = "rule"
    @Published var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var isRuntimeAvailable = false
    @Published var error: String?

    /// 节点延迟（毫秒），node 名 → ms。0 表示本次测速超时，缺失表示本次连接尚未测速。
    /// 结果属于当前 VPN 会话，App 重启时从 App Group 快照恢复。
    @Published private(set) var delays: [String: Int]
    /// 正在测速的策略组名。
    @Published private(set) var testing: Set<String> = []
    /// 正在单独测速的节点，以策略组和节点名共同标识。
    @Published private(set) var testingNodes: Set<ProxyNodeTestKey> = []
    /// 正在切换的策略组与目标节点，避免重复点击并给节点行显示进度。
    @Published private(set) var selecting: [String: String] = [:]
    private var loadGeneration = 0
    private var sessionGeneration = 0
    private var delaySessionID: String?

    init() {
        let snapshot = ProxyDelayStore.load()
        delaySessionID = snapshot?.sessionID
        delays = snapshot?.delays ?? [:]
    }

    func load() async {
        reconcileDelaySession()
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        error = nil
        defer {
            if generation == loadGeneration {
                isLoading = false
                hasLoaded = true
            }
        }

        let status = CoreStateManager.shared.status
        let runtimeAvailable = status == .connected || status == .reasserting
        isRuntimeAvailable = runtimeAvailable
        let result: TunnelManager.IPCResult
        if runtimeAvailable {
            result = await CoreStateManager.shared.sendMessage(["cmd": "queryProxies"])
        } else if let subscription = SubscriptionStore.shared.selected,
                  !subscription.yaml.isEmpty {
            let providerJSON = SubscriptionStore.shared.providerPayloadsJSON(for: subscription.id)
            let selectionJSON = Self.jsonString(subscription.proxySelections)
            let data = await Task.detached(priority: .userInitiated) {
                MihomoCore.offlineProxySnapshot(configYAML: subscription.yaml,
                                                providerPayloadsJSON: providerJSON,
                                                selectionsJSON: selectionJSON)
            }.value
            result = .ok(data)
        } else {
            result = .failure("当前配置为空，请先添加或刷新订阅")
        }
        guard generation == loadGeneration else { return }
        switch result {
        case .failure(let reason):
            self.error = "拿不到节点：\(reason)"
            mode = "rule"
            groups = []
            return
        case .ok(let data):
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                error = "解析失败（IPC 响应非 JSON）"
                groups = []
                return
            }
            mode = ((obj["mode"] as? String) ?? "rule").lowercased()
            if let snapshotError = obj["error"] as? String {
                error = "解析已保存配置失败：\(snapshotError)"
            } else if let missing = obj["missingProviders"] as? [String], !missing.isEmpty {
                error = "远程 Provider 尚未缓存：\(missing.joined(separator: "、"))。请在订阅详情中刷新。"
            }

            // 直连模式没有节点页数据，不再额外请求协议详情。
            if runtimeAvailable && mode == "direct" {
                groups = []
                return
            }

            guard let proxies = obj["proxies"] as? [String: Any] else {
                error = "解析代理列表失败"
                groups = []
                return
            }

            // 用 GLOBAL.all 的顺序还原配置定义顺序
            let order = (proxies["GLOBAL"] as? [String: Any])?["all"] as? [String] ?? []

            func makeGroup(_ name: String) -> ProxyGroup? {
                guard let d = proxies[name] as? [String: Any],
                      let all = d["all"] as? [String] else { return nil }
                let iconStr = (d["icon"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                return ProxyGroup(name: name,
                                  type: d["type"] as? String ?? "",
                                  now: d["now"] as? String ?? "",
                                  all: all,
                                  icon: iconStr.isEmpty ? nil : URL(string: iconStr))
            }

            switch mode {
            case "global":
                // 全局模式：只看 GLOBAL 组（在它里面选全局出口）
                groups = makeGroup("GLOBAL").map { [$0] } ?? []
            case "direct" where runtimeAvailable:
                groups = []
            default: // rule
                // 按 GLOBAL.all 顺序取出其中是「策略组」的项，排除 GLOBAL 自身
                var ordered: [ProxyGroup] = []
                var seen = Set<String>()
                for name in order where name != "GLOBAL" {
                    if let g = makeGroup(name) { ordered.append(g); seen.insert(name) }
                }
                // 兜底：GLOBAL.all 缺失时，补上未收录的策略组
                if ordered.isEmpty {
                    for (name, _) in proxies where name != "GLOBAL" && !seen.contains(name) {
                        if let g = makeGroup(name) { ordered.append(g) }
                    }
                }
                groups = ordered
            }
        }
    }

    /// 结束当前界面测速任务并清除内存结果。NE 负责创建/删除持久化会话快照。
    func resetSession() {
        loadGeneration &+= 1
        sessionGeneration &+= 1
        groups = []
        mode = "rule"
        isLoading = false
        hasLoaded = false
        isRuntimeAvailable = false
        error = nil
        delays = [:]
        delaySessionID = ProxyDelayStore.load()?.sessionID
        testing = []
        testingNodes = []
        selecting = [:]
    }

    /// 断开状态由 App 观察到时的兜底清理；正常情况下 NE stopTunnel 已先清理。
    func clearDisconnectedSession() {
        resetSession()
        delaySessionID = nil
        ProxyDelayStore.clear()
    }

    private func reconcileDelaySession() {
        let snapshot = ProxyDelayStore.load()
        guard snapshot?.sessionID != delaySessionID else { return }
        delaySessionID = snapshot?.sessionID
        delays = snapshot?.delays ?? [:]
        testing = []
        testingNodes = []
    }

    private func persistDelays() {
        guard let delaySessionID else { return }
        ProxyDelayStore.save(delays, sessionID: delaySessionID)
    }

    /// 在某策略组选定节点。连接中走 IPC；断开时保存到订阅，下次连接恢复。
    func select(group: String, name: String) async {
        guard selecting[group] == nil else { return }
        if !isRuntimeAvailable {
            guard let subscriptionID = SubscriptionStore.shared.selectedID,
                  let proxyGroup = groups.first(where: { $0.name == group }),
                  proxyGroup.selectable,
                  proxyGroup.all.contains(name) else { return }
            SubscriptionStore.shared.selectProxyOffline(subscriptionID: subscriptionID,
                                                        group: group,
                                                        name: name)
            await load()
            return
        }
        let session = sessionGeneration
        error = nil
        selecting[group] = name
        defer {
            if session == sessionGeneration {
                selecting[group] = nil
            }
        }

        let result = await CoreStateManager.shared.sendMessage(
            ["cmd": "selectProxy", "group": group, "name": name])
        guard session == sessionGeneration else { return }
        switch result {
        case .ok(let data):
            let resp = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if (resp?["ok"] as? Bool) == true {
                if let subscriptionID = SubscriptionStore.shared.selectedID {
                    SubscriptionStore.shared.selectProxyOffline(subscriptionID: subscriptionID,
                                                                group: group,
                                                                name: name)
                }
                await load()
            } else {
                self.error = "切换失败：\((resp?["error"] as? String) ?? "未知错误")"
            }
        case .failure(let reason):
            self.error = "切换失败：\(reason)"
        }
    }

    nonisolated private static func jsonString(_ value: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private var delayTestURL: String {
        let configured = SettingsStore.shared.delayTestURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? SettingsStore.defaultDelayTestURL : configured
    }

    private var directDelayTestURL: String {
        let configured = SettingsStore.shared.directDelayTestURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? SettingsStore.defaultDirectDelayTestURL : configured
    }

    private var delayTestTimeoutMilliseconds: Int {
        SettingsStore.shared.delayTestTimeout * 1_000
    }

    /// 对某策略组做延迟测试（IPC groupDelay）。每个成员都会收到成功延迟或 0（超时），
    /// 因而不会继续显示上一次测速的旧结果。
    func testGroup(_ name: String) async {
        guard isRuntimeAvailable, !testing.contains(name) else { return }
        let session = sessionGeneration
        error = nil
        testing.insert(name)
        let memberNames = groups.first(where: { $0.name == name })?.all ?? []
        let memberDelayKeys = Set(memberNames.map {
            ProxyDelayResolver.storageKey(for: $0, groups: groups)
        })
        var cleared = delays
        for key in memberDelayKeys {
            cleared.removeValue(forKey: key)
        }
        delays = cleared
        persistDelays()
        defer {
            if session == sessionGeneration {
                testing.remove(name)
            }
        }
        let result = await CoreStateManager.shared.sendMessage(
            ["cmd": "groupDelay", "group": name, "url": delayTestURL,
             "directURL": directDelayTestURL,
             "timeout": delayTestTimeoutMilliseconds])
        guard session == sessionGeneration else { return }
        switch result {
        case .ok(let data):
            guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                self.error = "测速失败：响应非 JSON"
                return
            }
            if let err = dict["error"] as? String {
                self.error = "测速失败：\(err)"
                return
            }
            var updated = delays
            for node in memberNames {
                let key = ProxyDelayResolver.storageKey(for: node, groups: groups)
                updated[key] = (dict[node] as? NSNumber)?.intValue ?? 0
            }
            for (node, ms) in dict {
                if let value = (ms as? NSNumber)?.intValue, !memberNames.contains(node) {
                    let key = ProxyDelayResolver.storageKey(for: node, groups: groups)
                    updated[key] = value
                }
            }
            delays = updated
            persistDelays()
        case .failure(let reason):
            self.error = "测速失败：\(reason)"
        }
    }

    /// 仅测试一个节点，结果写入与整组测速共用的延迟缓存。
    func testNode(_ name: String, in group: String? = nil) async {
        let testingKey = ProxyNodeTestKey(group: group ?? "", node: name)
        guard isRuntimeAvailable, !testingNodes.contains(testingKey) else { return }
        let session = sessionGeneration
        error = nil
        testingNodes.insert(testingKey)
        let delayKey = ProxyDelayResolver.storageKey(for: name, groups: groups)
        delays.removeValue(forKey: delayKey)
        persistDelays()
        defer {
            if session == sessionGeneration {
                testingNodes.remove(testingKey)
            }
        }
        let result = await CoreStateManager.shared.sendMessage(
            ["cmd": "proxyDelay", "name": name, "group": group ?? "",
             "directURL": directDelayTestURL,
             "url": delayTestURL, "timeout": delayTestTimeoutMilliseconds])
        guard session == sessionGeneration else { return }
        switch result {
        case .ok(let data):
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                self.error = "测速失败：响应非 JSON"
                return
            }
            if let message = object["error"] as? String {
                self.error = "测速失败：\(message)"
                return
            }
            guard let delay = (object["delay"] as? NSNumber)?.intValue else {
                self.error = "测速失败：响应缺少延迟"
                return
            }
            delays[delayKey] = delay
            persistDelays()
        case .failure(let reason):
            self.error = "测速失败：\(reason)"
        }
    }
}
