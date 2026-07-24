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
         icon: URL?,
         details: [String: String]) {
        self.name = name
        self.type = type
        self.now = now
        self.all = all
        self.icon = icon
        self.nodes = all.enumerated().map { index, node in
            let detail = details[node] ?? ""
            return ProxyGroupNode(
                id: .init(group: name, index: index),
                name: node,
                normalizedSearchText: "\(node) \(detail)".lowercased())
        }
    }

    /// 只有 Selector 可手动点选；URLTest/Fallback 等是自动组。
    var selectable: Bool { type.caseInsensitiveCompare("Selector") == .orderedSame }
}

/// 策略组查询与节点切换：经 **sendProviderMessage IPC** 直连 NE 内核
/// （queryProxies / selectProxy / groupDelay），不走 HTTP API。
///
/// 排序：用 GLOBAL 组的 all 顺序（即配置里 proxy-groups 的定义顺序），不再按字母乱排。
/// 模式感知：global 只显示 GLOBAL 组；rule 显示其余策略组；direct 不涉及节点选择。
@MainActor
final class ProxyController: ObservableObject {

    @Published private(set) var groups: [ProxyGroup] = []
    @Published private(set) var uniqueNodeCount = 0
    @Published private(set) var mode: String = "rule"
    @Published var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published var error: String?

    /// 节点延迟（毫秒），node 名 → ms。0/缺失表示未测或超时。
    @Published private(set) var delays: [String: Int] = [:]
    /// 节点协议摘要，node 名 → "VLESS · TCP · Reality · Vision"。
    @Published private(set) var details: [String: String] = [:]
    /// 正在测速的策略组名。
    @Published private(set) var testing: Set<String> = []
    /// 正在切换的策略组与目标节点，避免重复点击并给节点行显示进度。
    @Published private(set) var selecting: [String: String] = [:]
    private var loadGeneration = 0
    private var sessionGeneration = 0

    func load() async {
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

        let result = await CoreStateManager.shared.sendMessage(["cmd": "queryProxies"])
        guard generation == loadGeneration else { return }
        switch result {
        case .failure(let reason):
            self.error = "拿不到节点：\(reason)"
            mode = "rule"
            groups = []
            uniqueNodeCount = 0
            details = [:]
            delays = [:]
            return
        case .ok(let data):
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                error = "解析失败（IPC 响应非 JSON）"
                groups = []
                uniqueNodeCount = 0
                details = [:]
                return
            }
            mode = ((obj["mode"] as? String) ?? "rule").lowercased()

            // 直连模式没有节点页数据，不再额外请求协议详情。
            if mode == "direct" {
                groups = []
                uniqueNodeCount = 0
                details = [:]
                delays = [:]
                return
            }

            guard let proxies = obj["proxies"] as? [String: Any] else {
                error = "解析代理列表失败"
                groups = []
                uniqueNodeCount = 0
                details = [:]
                return
            }

            // 协议摘要（按配置走，随列表一起刷新）。
            let det = await CoreStateManager.shared.sendMessage(["cmd": "proxyDetails"])
            guard generation == loadGeneration else { return }
            if case .ok(let d) = det,
               let map = (try? JSONSerialization.jsonObject(with: d)) as? [String: String] {
                details = map
            } else {
                details = [:]
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
                                  details: details)
            }

            switch mode {
            case "global":
                // 全局模式：只看 GLOBAL 组（在它里面选全局出口）
                groups = makeGroup("GLOBAL").map { [$0] } ?? []
            case "direct":
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
            uniqueNodeCount = Set(groups.flatMap { $0.all }).count
        }
    }

    func resetSession() {
        loadGeneration &+= 1
        sessionGeneration &+= 1
        groups = []
        uniqueNodeCount = 0
        mode = "rule"
        isLoading = false
        hasLoaded = false
        error = nil
        delays = [:]
        details = [:]
        testing = []
        selecting = [:]
    }

    /// 在某策略组选定节点（IPC selectProxy）。
    func select(group: String, name: String) async {
        guard selecting[group] == nil else { return }
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
                await load()
            } else {
                self.error = "切换失败：\((resp?["error"] as? String) ?? "未知错误")"
            }
        case .failure(let reason):
            self.error = "切换失败：\(reason)"
        }
    }

    /// 对某策略组做延迟测试（IPC groupDelay），结果并入 delays。
    func testGroup(_ name: String) async {
        guard !testing.contains(name) else { return }
        let session = sessionGeneration
        error = nil
        testing.insert(name)
        defer {
            if session == sessionGeneration {
                testing.remove(name)
            }
        }
        let result = await CoreStateManager.shared.sendMessage(
            ["cmd": "groupDelay", "group": name, "timeout": 5000])
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
            for (node, ms) in dict {
                if let value = (ms as? NSNumber)?.intValue { updated[node] = value }
            }
            delays = updated
        case .failure(let reason):
            self.error = "测速失败：\(reason)"
        }
    }
}
