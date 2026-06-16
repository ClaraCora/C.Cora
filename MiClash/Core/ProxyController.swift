import Foundation

/// 一个策略组（或带 all 的代理集合）。
struct ProxyGroup: Identifiable {
    var id: String { name }
    let name: String
    let type: String      // Selector / URLTest / Fallback / LoadBalance / Relay ...
    let now: String       // 当前选中/生效的节点
    let all: [String]     // 成员节点名

    /// 只有 Selector 可手动点选；URLTest/Fallback 等是自动组。
    var selectable: Bool { type == "Selector" }
}

/// 策略组查询与节点切换：经 CoreStateManager 的 sendProviderMessage IPC 与 NE 内 mihomo 通信。
///
/// 数据来自 mihomo `tunnel.Proxies()`（等价 REST GET /proxies）；
/// 切换走 `SelectProxy`（等价 PUT /proxies/{name}）。均不依赖 App Group。
@MainActor
final class ProxyController: ObservableObject {

    @Published private(set) var groups: [ProxyGroup] = []
    @Published var isLoading = false
    @Published var error: String?

    private let core: CoreStateManager

    init(core: CoreStateManager = .shared) { self.core = core }

    /// 拉取所有策略组。需 VPN 已连接（NE 运行中）。
    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        let data: Data
        switch await core.sendMessage(["cmd": "queryProxies"]) {
        case .ok(let d):
            data = d
        case .failure(let reason):
            error = reason
            groups = []
            return
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let proxies = obj["proxies"] as? [String: Any] else {
            error = "解析代理列表失败"
            return
        }

        var result: [ProxyGroup] = []
        for (name, value) in proxies {
            // 只有策略组带 "all" 成员列表；普通节点跳过
            guard let d = value as? [String: Any], let all = d["all"] as? [String] else { continue }
            result.append(ProxyGroup(
                name: name,
                type: d["type"] as? String ?? "",
                now: d["now"] as? String ?? "",
                all: all))
        }
        // 可选组（Selector）排前面，再按名称排序；GLOBAL 这类自动靠后
        result.sort { lhs, rhs in
            (lhs.selectable ? 0 : 1, lhs.name) < (rhs.selectable ? 0 : 1, rhs.name)
        }
        groups = result
    }

    /// 在某策略组选定节点。
    func select(group: String, name: String) async {
        let data: Data
        switch await core.sendMessage(["cmd": "selectProxy", "group": group, "name": name]) {
        case .ok(let d):
            data = d
        case .failure(let reason):
            error = "切换失败：\(reason)"
            return
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let ok = obj?["ok"] as? Bool, ok {
            await load() // 切换成功后刷新当前选中
        } else {
            error = "切换失败：\(obj?["error"] as? String ?? "未知错误")"
        }
    }
}
