import Foundation

/// 一条订阅。
struct Subscription: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var yaml: String          // 拉取到的 Clash/mihomo 配置原文
    var updatedAt: Date?      // 最近一次成功拉取时间
    var nodeCount: Int        // 粗略统计 proxies 条目数，给 UI 展示

    init(id: UUID = UUID(), name: String, url: String, yaml: String = "",
         updatedAt: Date? = nil, nodeCount: Int = 0) {
        self.id = id
        self.name = name
        self.url = url
        self.yaml = yaml
        self.updatedAt = updatedAt
        self.nodeCount = nodeCount
    }
}

/// 订阅的存取与拉取（MVVM 中的「Model/Store」，单向数据流的源）。
///
/// 订阅内容约定是 **Clash/mihomo YAML**（含 proxies/proxy-groups/rules），无需格式转换。
/// 持久化到 App 沙盒 Documents 的 JSON 文件；当前选中的订阅 yaml 在连接时下发给 NE。
@MainActor
final class SubscriptionStore: ObservableObject {

    static let shared = SubscriptionStore()

    @Published private(set) var subscriptions: [Subscription] = []
    @Published var selectedID: UUID?
    @Published var lastError: String?
    @Published var isBusy = false

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("subscriptions.json")
    }()

    private init() { load() }

    /// 当前选中订阅的配置 YAML（连接时传给 NE）。无选中/无内容返回 nil。
    var activeYAML: String? {
        guard let id = selectedID,
              let sub = subscriptions.first(where: { $0.id == id }),
              !sub.yaml.isEmpty else { return nil }
        return sub.yaml
    }

    var selected: Subscription? {
        guard let id = selectedID else { return nil }
        return subscriptions.first(where: { $0.id == id })
    }

    // MARK: - 增删改

    /// 添加订阅并立即拉取。
    func add(name: String, url: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { lastError = "订阅地址为空"; return }

        let sub = Subscription(name: trimmedName.isEmpty ? "未命名订阅" : trimmedName, url: trimmedURL)
        subscriptions.append(sub)
        if selectedID == nil { selectedID = sub.id }
        save()
        await refresh(sub.id)
    }

    func remove(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        if selectedID == id { selectedID = subscriptions.first?.id }
        save()
    }

    func select(_ id: UUID) {
        selectedID = id
        save()
    }

    /// 重新拉取某订阅的配置 YAML。
    func refresh(_ id: UUID) async {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let urlString = subscriptions[idx].url
        guard let url = URL(string: urlString) else { lastError = "无效的订阅地址"; return }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            var req = URLRequest(url: url)
            // 多数订阅服务按 UA 返回 clash 配置
            req.setValue("clash-meta", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 30
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                lastError = "拉取失败：HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                lastError = "订阅内容不是文本"
                return
            }
            guard looksLikeClashYAML(text) else {
                lastError = "订阅内容不是 Clash/mihomo YAML（可能是 base64 订阅，暂不支持）"
                return
            }
            // firstIndex 可能因并发变化，重新定位
            guard let i = subscriptions.firstIndex(where: { $0.id == id }) else { return }
            subscriptions[i].yaml = text
            subscriptions[i].updatedAt = Date()
            subscriptions[i].nodeCount = countProxies(text)
            save()
        } catch {
            lastError = "拉取失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 校验/统计

    private func looksLikeClashYAML(_ text: String) -> Bool {
        text.contains("proxies:") || text.contains("proxy-groups:") || text.contains("proxy-providers:")
    }

    /// 粗略数 proxies 段下的 `- name:` 条目数，仅用于 UI 展示。
    private func countProxies(_ text: String) -> Int {
        guard let range = text.range(of: "proxies:") else { return 0 }
        let after = text[range.upperBound...]
        // 数到下一个顶格 key 为止
        var count = 0
        for line in after.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first != " ", first != "-", line.contains(":") { break }
            if line.contains("- name:") || line.trimmingCharacters(in: .whitespaces).hasPrefix("- {") {
                count += 1
            }
        }
        return count
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            subscriptions = decoded.subscriptions
            selectedID = decoded.selectedID
        }
    }

    private func save() {
        let payload = Persisted(subscriptions: subscriptions, selectedID: selectedID)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private struct Persisted: Codable {
        var subscriptions: [Subscription]
        var selectedID: UUID?
    }
}
