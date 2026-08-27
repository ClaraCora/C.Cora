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

/// One concrete current-selection target for the toolbar batch delay test.
/// `key` is the shared delay-store key, while `group` is only a lookup context
/// for provider nodes that are not exposed in mihomo's top-level proxy map.
struct ProxyDelayBatchTarget: Hashable {
    let key: String
    let node: String
    let group: String
}

/// 一个策略组。
struct ProxyGroup: Identifiable {
    var id: String { name }
    let name: String
    let type: String      // Selector / URLTest / Fallback / LoadBalance / Relay ...
    let now: String       // 当前选中/生效的节点
    let all: [String]     // 成员节点名（按配置顺序）
    let icon: URL?        // 配置里 proxy-groups[].icon，内核经 /proxies 原样回传
    let hidden: Bool      // 配置里的 hidden: true；缺省为 false
    let nodes: [ProxyGroupNode]

    init(name: String,
         type: String,
         now: String,
         all: [String],
         icon: URL?,
         hidden: Bool) {
        self.name = name
        self.type = type
        self.now = now
        self.all = all
        self.icon = icon
        self.hidden = hidden
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

struct ProxySelectionResolution {
    let immediateSelection: String
    let finalNode: String
    let path: [String]

    var hasDistinctFinalNode: Bool { finalNode != immediateSelection }
}

/// 一份代理分组快照对应的不可变名称索引。
///
/// 分组引用解析会在卡片和节点行渲染期间频繁发生。索引由控制器在
/// `resolutionGroups` 变化时构建一次，避免每次解析都重新创建整张字典。
struct ProxyGroupIndex {
    private let groupsByName: [String: ProxyGroup]
    let groupNames: Set<String>

    init(groups: [ProxyGroup] = []) {
        var lookup: [String: ProxyGroup] = [:]
        lookup.reserveCapacity(groups.count)
        for group in groups {
            // 保持旧实现语义：若异常数据含同名分组，后出现的分组生效。
            lookup[group.name] = group
        }
        groupsByName = lookup
        groupNames = Set(lookup.keys)
    }

    func group(named name: String) -> ProxyGroup? {
        groupsByName[name]
    }
}

/// 沿策略组当前选择递归找到最终出口。精确匹配组名，并对循环、空引用和过深引用安全降级。
enum ProxySelectionResolver {
    private static let maximumDepth = 64

    static func resolve(group: ProxyGroup,
                        groups: [ProxyGroup]) -> ProxySelectionResolution? {
        resolve(group: group, index: ProxyGroupIndex(groups: groups))
    }

    static func resolve(group: ProxyGroup,
                        index: ProxyGroupIndex) -> ProxySelectionResolution? {
        let immediate = group.now
        guard !immediate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return resolve(name: immediate, index: index, initiallyVisited: [group.name])
    }

    static func resolve(name: String,
                        groups: [ProxyGroup]) -> ProxySelectionResolution? {
        resolve(name: name, index: ProxyGroupIndex(groups: groups))
    }

    static func resolve(name: String,
                        index: ProxyGroupIndex) -> ProxySelectionResolution? {
        resolve(name: name, index: index, initiallyVisited: [])
    }

    private static func resolve(name: String,
                                index: ProxyGroupIndex,
                                initiallyVisited: Set<String>) -> ProxySelectionResolution? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var current = name
        var path = [name]
        var visited = initiallyVisited
        guard visited.insert(name).inserted else {
            return ProxySelectionResolution(immediateSelection: name,
                                            finalNode: name,
                                            path: path)
        }

        for _ in 0..<maximumDepth {
            guard let group = index.group(named: current) else {
                return ProxySelectionResolution(immediateSelection: name,
                                                finalNode: current,
                                                path: path)
            }
            let selected = group.now
            guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  visited.insert(selected).inserted else {
                return ProxySelectionResolution(immediateSelection: name,
                                                finalNode: name,
                                                path: path)
            }
            current = selected
            path.append(selected)
        }

        return ProxySelectionResolution(immediateSelection: name,
                                        finalNode: name,
                                        path: path)
    }
}

/// 延迟只存实际节点，显示时再把结果映射回引用项，
/// 使“总模式 -> 地区分组 -> 节点”的多个入口始终展示同一条测速结果。
enum ProxyDelayResolver {
    /// 返回延迟查询优先级：实际节点优先，其次是引用链上的分组名（兼容旧会话数据）。
    static func keys(for name: String, groups: [ProxyGroup]) -> [String] {
        keys(for: name, index: ProxyGroupIndex(groups: groups))
    }

    static func keys(for name: String, index: ProxyGroupIndex) -> [String] {
        guard let resolution = ProxySelectionResolver.resolve(name: name, index: index) else {
            return [name]
        }

        var result = [resolution.finalNode]
        for alias in resolution.path.reversed() where !result.contains(alias) {
            result.append(alias)
        }
        return result
    }

    static func storageKey(for name: String, groups: [ProxyGroup]) -> String {
        storageKey(for: name, index: ProxyGroupIndex(groups: groups))
    }

    static func storageKey(for name: String, index: ProxyGroupIndex) -> String {
        keys(for: name, index: index).first ?? name
    }

    static func delay(for name: String,
                      groups: [ProxyGroup],
                      delays: [String: Int]) -> Int? {
        delay(for: name,
              index: ProxyGroupIndex(groups: groups),
              delays: delays)
    }

    static func delay(for name: String,
                      index: ProxyGroupIndex,
                      delays: [String: Int]) -> Int? {
        for key in keys(for: name, index: index) {
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
    /// 完整分组图用于递归解析引用；`groups` 仍只包含当前模式需要展示的分组。
    @Published private(set) var resolutionGroups: [ProxyGroup] = [] {
        didSet {
            resolutionIndex = ProxyGroupIndex(groups: resolutionGroups)
            catalogRevision &+= 1
        }
    }
    /// 与 `resolutionGroups` 同步的解析索引，供高频 UI 查询复用。
    private(set) var resolutionIndex = ProxyGroupIndex()
    /// 分组目录的轻量变更标记，避免视图每次刷新都排序并拼接完整成员列表。
    private(set) var catalogRevision: UInt64 = 0
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
    /// 顶部批量测速当前覆盖的最终节点 key。卡片据此显示独立加载状态。
    @Published private(set) var testingCurrentSelectionKeys: Set<String> = []
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
            resolutionGroups = []
            return
        case .ok(let data):
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                error = "解析失败（IPC 响应非 JSON）"
                groups = []
                resolutionGroups = []
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
                resolutionGroups = []
                return
            }

            guard let proxies = obj["proxies"] as? [String: Any] else {
                error = "解析代理列表失败"
                groups = []
                resolutionGroups = []
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
                                  icon: iconStr.isEmpty ? nil : URL(string: iconStr),
                                  hidden: d["hidden"] as? Bool ?? false)
            }

            let groupLookup = Dictionary(uniqueKeysWithValues: proxies.keys.compactMap { name in
                makeGroup(name).map { (name, $0) }
            })
            resolutionGroups = Array(groupLookup.values)

            switch mode {
            case "global":
                // 全局模式：只看 GLOBAL 组（在它里面选全局出口）
                groups = groupLookup["GLOBAL"].map { [$0] } ?? []
            case "direct" where runtimeAvailable:
                groups = []
            default: // rule
                // 按 GLOBAL.all 顺序取出其中是「策略组」的项，排除 GLOBAL 自身
                var ordered: [ProxyGroup] = []
                var seen = Set<String>()
                for name in order where name != "GLOBAL" {
                    if let group = groupLookup[name] {
                        ordered.append(group)
                        seen.insert(name)
                    }
                }
                // 兜底：GLOBAL.all 缺失时，补上未收录的策略组
                if ordered.isEmpty {
                    for (name, group) in groupLookup {
                        guard name != "GLOBAL", !seen.contains(name) else { continue }
                        ordered.append(group)
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
        resolutionGroups = []
        mode = "rule"
        isLoading = false
        hasLoaded = false
        isRuntimeAvailable = false
        error = nil
        delays = [:]
        delaySessionID = ProxyDelayStore.load()?.sessionID
        testing = []
        testingNodes = []
        testingCurrentSelectionKeys = []
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
        testingCurrentSelectionKeys = []
    }

    private func persistDelays() {
        guard let delaySessionID else { return }
        ProxyDelayStore.save(delays, sessionID: delaySessionID)
    }

    private func clearDelayValues(for keys: Set<String>) {
        guard !keys.isEmpty else { return }
        var updated = delays
        for key in keys {
            updated.removeValue(forKey: key)
        }
        delays = updated
        persistDelays()
    }

    private func mergeDelayValues(_ values: [String: Int]) {
        guard !values.isEmpty else { return }
        var updated = delays
        for (key, value) in values {
            updated[key] = value
        }
        delays = updated
        persistDelays()
    }

    private func restoreDelayValues(_ previous: [String: Int],
                                    for keys: Set<String>) {
        var updated = delays
        for key in keys {
            updated.removeValue(forKey: key)
        }
        for (key, value) in previous {
            updated[key] = value
        }
        delays = updated
        persistDelays()
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
        guard isRuntimeAvailable,
              testingCurrentSelectionKeys.isEmpty,
              !testing.contains(name) else { return }
        let session = sessionGeneration
        error = nil
        testing.insert(name)
        let memberNames = groups.first(where: { $0.name == name })?.all ?? []
        let memberNameSet = Set(memberNames)
        let memberDelayKeys = Set(memberNames.map {
            ProxyDelayResolver.storageKey(for: $0, index: resolutionIndex)
        })
        clearDelayValues(for: memberDelayKeys)
        defer {
            if session == sessionGeneration {
                testing.remove(name)
            }
        }
        let result = await CoreStateManager.shared.sendMessage(
            ["cmd": "groupDelay", "group": name, "url": delayTestURL,
             "directURL": directDelayTestURL,
             "count": memberNames.count,
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
            var values: [String: Int] = [:]
            for node in memberNames {
                let key = ProxyDelayResolver.storageKey(for: node, index: resolutionIndex)
                values[key] = (dict[node] as? NSNumber)?.intValue ?? 0
            }
            for (node, ms) in dict {
                if let value = (ms as? NSNumber)?.intValue, !memberNameSet.contains(node) {
                    let key = ProxyDelayResolver.storageKey(for: node, index: resolutionIndex)
                    values[key] = value
                }
            }
            mergeDelayValues(values)
            if (dict["_partial"] as? Bool) == true {
                self.error = "分组较大，已达到测速安全时间上限，未完成节点显示为超时"
            }
        case .failure(let reason):
            self.error = "测速失败：\(reason)"
        }
    }

    /// 仅测试一个节点，结果写入与整组测速共用的延迟缓存。
    func testNode(_ name: String, in group: String? = nil) async {
        let testingKey = ProxyNodeTestKey(group: group ?? "", node: name)
        guard isRuntimeAvailable,
              testingCurrentSelectionKeys.isEmpty,
              !testingNodes.contains(testingKey) else { return }
        let session = sessionGeneration
        error = nil
        testingNodes.insert(testingKey)
        let delayKey = ProxyDelayResolver.storageKey(for: name, index: resolutionIndex)
        clearDelayValues(for: [delayKey])
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
            mergeDelayValues([delayKey: delay])
        case .failure(let reason):
            self.error = "测速失败：\(reason)"
        }
    }

    /// 测试当前页面每张卡片已选中的最终节点。目标按共享延迟 key 去重，
    /// 与整组测速和单节点测速共用同一份会话缓存与持久化快照。
    func testCurrentSelections(_ targets: [ProxyDelayBatchTarget]) async {
        var seen = Set<String>()
        let uniqueTargets = targets.filter { target in
            !target.key.isEmpty && !target.node.isEmpty && seen.insert(target.key).inserted
        }
        guard isRuntimeAvailable,
              !uniqueTargets.isEmpty,
              testing.isEmpty,
              testingNodes.isEmpty,
              testingCurrentSelectionKeys.isEmpty else { return }

        let session = sessionGeneration
        let keys = Set(uniqueTargets.map(\.key))
        let previousValues = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            delays[key].map { (key, $0) }
        })
        error = nil
        testingCurrentSelectionKeys = keys
        clearDelayValues(for: keys)
        defer {
            if session == sessionGeneration {
                testingCurrentSelectionKeys = []
            }
        }

        let payload = uniqueTargets.map { target in
            ["key": target.key, "name": target.node, "group": target.group]
        }
        let result = await CoreStateManager.shared.sendMessage(
            ["cmd": "proxyDelays", "targets": payload,
             "count": uniqueTargets.count,
             "directURL": directDelayTestURL,
             "url": delayTestURL, "timeout": delayTestTimeoutMilliseconds])
        guard session == sessionGeneration else { return }

        switch result {
        case .ok(let data):
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                restoreDelayValues(previousValues, for: keys)
                self.error = "测速失败：批量响应非 JSON"
                return
            }
            if let message = object["error"] as? String {
                restoreDelayValues(previousValues, for: keys)
                self.error = "测速失败：\(message)"
                return
            }
            guard let rawResults = object["results"] as? [String: Any] else {
                restoreDelayValues(previousValues, for: keys)
                self.error = "测速失败：批量响应缺少结果"
                return
            }
            var values: [String: Int] = [:]
            for target in uniqueTargets {
                values[target.key] = (rawResults[target.key] as? NSNumber)?.intValue ?? 0
            }
            mergeDelayValues(values)
        case .failure(let reason):
            restoreDelayValues(previousValues, for: keys)
            self.error = "测速失败：\(reason)"
        }
    }
}
