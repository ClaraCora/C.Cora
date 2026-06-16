import Foundation

/// 一个策略组。
struct ProxyGroup: Identifiable {
    var id: String { name }
    let name: String
    let type: String      // Selector / URLTest / Fallback / LoadBalance / Relay ...
    let now: String       // 当前选中/生效的节点
    let all: [String]     // 成员节点名（按配置顺序）

    /// 只有 Selector 可手动点选；URLTest/Fallback 等是自动组。
    var selectable: Bool { type == "Selector" }
}

/// 策略组查询与节点切换：经 mihomo external-controller HTTP（GET /proxies、PUT /proxies/{group}）。
///
/// 排序：用 GLOBAL 组的 all 顺序（即配置里 proxy-groups 的定义顺序），不再按字母乱排。
/// 模式感知：global 只显示 GLOBAL 组；rule 显示其余策略组；direct 不涉及节点选择。
@MainActor
final class ProxyController: ObservableObject {

    @Published private(set) var groups: [ProxyGroup] = []
    @Published private(set) var mode: String = "rule"
    @Published var isLoading = false
    @Published var error: String?

    /// 节点延迟（毫秒），node 名 → ms。0/缺失表示未测或超时。
    @Published private(set) var delays: [String: Int] = [:]
    /// 正在测速的策略组名。
    @Published private(set) var testing: Set<String> = []

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            async let modeStr = MihomoAPI.currentMode()
            async let proxiesObj = MihomoAPI.proxiesJSON()
            let (m, obj) = try await (modeStr, proxiesObj)
            mode = m

            guard let proxies = obj["proxies"] as? [String: Any] else {
                error = "解析代理列表失败"
                return
            }

            // 用 GLOBAL.all 的顺序还原配置定义顺序
            let order = (proxies["GLOBAL"] as? [String: Any])?["all"] as? [String] ?? []

            func makeGroup(_ name: String) -> ProxyGroup? {
                guard let d = proxies[name] as? [String: Any],
                      let all = d["all"] as? [String] else { return nil }
                return ProxyGroup(name: name,
                                  type: d["type"] as? String ?? "",
                                  now: d["now"] as? String ?? "",
                                  all: all)
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
        } catch {
            self.error = "连不上内核：\(error.localizedDescription)\n（请确认 VPN 已连接）"
            groups = []
        }
    }

    /// 在某策略组选定节点。
    func select(group: String, name: String) async {
        do {
            try await MihomoAPI.select(group: group, node: name)
            await load()
        } catch {
            self.error = "切换失败：\(error.localizedDescription)"
        }
    }

    /// 对某策略组做延迟测试，结果并入 delays。
    func testGroup(_ name: String) async {
        testing.insert(name)
        defer { testing.remove(name) }
        do {
            let result = try await MihomoAPI.groupDelay(group: name)
            for (node, ms) in result { delays[node] = ms }
        } catch {
            self.error = "测速失败：\(error.localizedDescription)"
        }
    }
}
