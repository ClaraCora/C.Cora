import Foundation

/// 一条订阅。
struct Subscription: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var yaml: String          // 拉取到的 Clash/mihomo 配置原文
    var updatedAt: Date?      // 最近一次成功拉取时间
    var nodeCount: Int        // 粗略统计 proxies 条目数

    // 来自机场返回的 subscription-userinfo 响应头（字节）
    var upload: Int64
    var download: Int64
    var total: Int64
    var expire: Date?
    var autoNamed: Bool       // 名称是否自动获取（用户没手填时才自动覆盖）

    init(id: UUID = UUID(), name: String, url: String, yaml: String = "",
         updatedAt: Date? = nil, nodeCount: Int = 0,
         upload: Int64 = 0, download: Int64 = 0, total: Int64 = 0,
         expire: Date? = nil, autoNamed: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.yaml = yaml
        self.updatedAt = updatedAt
        self.nodeCount = nodeCount
        self.upload = upload
        self.download = download
        self.total = total
        self.expire = expire
        self.autoNamed = autoNamed
    }

    var used: Int64 { upload + download }
    var remaining: Int64 { max(0, total - used) }
    var hasUsage: Bool { total > 0 }
    /// 本地配置：没有订阅链接，内容由用户手写/粘贴，不可远程刷新。
    var isLocal: Bool { url.isEmpty }

    // 容错解码：旧版 subscriptions.json 没有新字段，缺失时给默认值，避免整体解码失败丢订阅。
    enum CodingKeys: String, CodingKey {
        case id, name, url, yaml, updatedAt, nodeCount, upload, download, total, expire, autoNamed
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        yaml = try c.decodeIfPresent(String.self, forKey: .yaml) ?? ""
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        nodeCount = try c.decodeIfPresent(Int.self, forKey: .nodeCount) ?? 0
        upload = try c.decodeIfPresent(Int64.self, forKey: .upload) ?? 0
        download = try c.decodeIfPresent(Int64.self, forKey: .download) ?? 0
        total = try c.decodeIfPresent(Int64.self, forKey: .total) ?? 0
        expire = try c.decodeIfPresent(Date.self, forKey: .expire)
        autoNamed = try c.decodeIfPresent(Bool.self, forKey: .autoNamed) ?? false
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

        let auto = trimmedName.isEmpty
        let sub = Subscription(name: auto ? "拉取中…" : trimmedName, url: trimmedURL, autoNamed: auto)
        subscriptions.append(sub)
        if selectedID == nil { selectedID = sub.id }
        save()
        await refresh(sub.id)
    }

    /// 新建一个本地配置文件（用户手写/粘贴 YAML，无订阅链接）。
    func addLocal(name: String, yaml: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var sub = Subscription(name: n.isEmpty ? "本地配置" : n, url: "", yaml: yaml)
        sub.nodeCount = countProxies(yaml)
        sub.updatedAt = Date()
        subscriptions.append(sub)
        if selectedID == nil { selectedID = sub.id }
        lastError = looksLikeClashYAML(yaml) ? nil
            : "已保存，但内容里没找到 proxies/proxy-groups，连接时可能无效"
        save()
    }

    /// 编辑本地配置（名称 + YAML）。
    func updateLocal(_ id: UUID, name: String, yaml: String) {
        guard let i = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { subscriptions[i].name = n }
        subscriptions[i].yaml = yaml
        subscriptions[i].nodeCount = countProxies(yaml)
        subscriptions[i].updatedAt = Date()
        lastError = looksLikeClashYAML(yaml) ? nil
            : "已保存，但内容里没找到 proxies/proxy-groups，连接时可能无效"
        save()
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
        guard !urlString.isEmpty else { lastError = "本地配置无需刷新"; return }
        guard let url = URL(string: urlString) else { lastError = "无效的订阅地址"; return }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            var req = URLRequest(url: url)
            // 机场常按 UA 返回不同格式；UA 可在设置里改，默认 clash-meta。
            let ua = SettingsStore.shared.subscriptionUA.trimmingCharacters(in: .whitespaces)
            req.setValue(ua.isEmpty ? "clash-meta" : ua, forHTTPHeaderField: "User-Agent")
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

            // 解析机场返回的流量/到期（subscription-userinfo 头）
            if let info = headerValue(http, "subscription-userinfo") {
                let kv = parseUserInfo(info)
                subscriptions[i].upload = kv["upload"] ?? 0
                subscriptions[i].download = kv["download"] ?? 0
                subscriptions[i].total = kv["total"] ?? 0
                if let exp = kv["expire"], exp > 0 {
                    subscriptions[i].expire = Date(timeIntervalSince1970: TimeInterval(exp))
                }
            }
            // 自动名称（用户没手填时）
            if subscriptions[i].autoNamed,
               let title = subscriptionTitle(http, fallbackHost: url.host) {
                subscriptions[i].name = title
            }
            save()
        } catch {
            lastError = "拉取失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 校验/统计

    /// 大小写不敏感地取响应头。
    private func headerValue(_ http: HTTPURLResponse, _ key: String) -> String? {
        if #available(iOS 13.0, *) {
            return http.value(forHTTPHeaderField: key)
        }
        return http.allHeaderFields[key] as? String
    }

    /// 解析 subscription-userinfo: "upload=..; download=..; total=..; expire=.."
    private func parseUserInfo(_ s: String) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for part in s.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let v = Int64(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            result[k] = v
        }
        return result
    }

    /// 从响应头推断订阅名称：优先 profile-title（可能 base64），其次 content-disposition 文件名，最后主机名。
    private func subscriptionTitle(_ http: HTTPURLResponse, fallbackHost: String?) -> String? {
        if let raw = headerValue(http, "profile-title") {
            if raw.lowercased().hasPrefix("base64:"),
               let data = Data(base64Encoded: String(raw.dropFirst(7))),
               let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty {
                return decoded
            }
            if !raw.isEmpty { return raw }
        }
        if let cd = headerValue(http, "content-disposition"),
           let name = filename(fromContentDisposition: cd) {
            return name
        }
        return fallbackHost
    }

    private func filename(fromContentDisposition cd: String) -> String? {
        // filename*=UTF-8''xxx 优先
        if let range = cd.range(of: "filename*=") {
            var v = String(cd[range.upperBound...])
            if let semi = v.firstIndex(of: ";") { v = String(v[..<semi]) }
            if let tick = v.range(of: "''") { v = String(v[tick.upperBound...]) }
            if let decoded = v.removingPercentEncoding, !decoded.isEmpty { return decoded }
        }
        if let range = cd.range(of: "filename=") {
            var v = String(cd[range.upperBound...])
            if let semi = v.firstIndex(of: ";") { v = String(v[..<semi]) }
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if !v.isEmpty { return v }
        }
        return nil
    }

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
