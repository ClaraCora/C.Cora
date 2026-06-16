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

/// 策略组查询与节点切换：经 mihomo external-controller 的 HTTP API（不走已失效的 IPC）。
///
/// 数据来自 GET /proxies；切换走 PUT /proxies/{group}。需 VPN 已连接（NE 内 REST 已起）。
@MainActor
final class ProxyController: ObservableObject {

    @Published private(set) var groups: [ProxyGroup] = []
    @Published var isLoading = false
    @Published var error: String?

    /// 拉取所有策略组。
    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let obj = try await MihomoAPI.proxiesJSON()
            guard let proxies = obj["proxies"] as? [String: Any] else {
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
            // 可选组（Selector）排前面，再按名称排序
            result.sort { lhs, rhs in
                (lhs.selectable ? 0 : 1, lhs.name) < (rhs.selectable ? 0 : 1, rhs.name)
            }
            groups = result
        } catch {
            self.error = "连不上内核：\(error.localizedDescription)\n（请确认 VPN 已连接）"
            groups = []
        }
    }

    /// 在某策略组选定节点。
    func select(group: String, name: String) async {
        do {
            try await MihomoAPI.select(group: group, node: name)
            await load() // 切换成功后刷新当前选中
        } catch {
            self.error = "切换失败：\(error.localizedDescription)"
        }
    }
}
