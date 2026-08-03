import Foundation
import Mihomo

private let subscriptionMaximumDownloadBytes: Int64 = 10 * 1_024 * 1_024

/// 一条订阅。
struct Subscription: Identifiable, Codable, Equatable, Sendable {
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
    var overrideYAML: String  // 独立于订阅原文保存，刷新后仍会应用

    init(id: UUID = UUID(), name: String, url: String, yaml: String = "",
         updatedAt: Date? = nil, nodeCount: Int = 0,
         upload: Int64 = 0, download: Int64 = 0, total: Int64 = 0,
         expire: Date? = nil, autoNamed: Bool = false,
         overrideYAML: String = "") {
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
        self.overrideYAML = overrideYAML
    }

    var used: Int64 { upload + download }
    var remaining: Int64 { max(0, total - used) }
    var hasUsage: Bool { total > 0 }
    var hasOverride: Bool {
        !overrideYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// 本地配置：没有订阅链接，内容由用户手写/粘贴，不可远程刷新。
    var isLocal: Bool { url.isEmpty }

    /// 到期时间显示：机场常用远未来时间（如 2100/1/1）表示「长期有效」，直接显示日期反而奇怪。
    var expireText: String? {
        guard let expire else { return nil }
        if expire.timeIntervalSinceNow > 50 * 365 * 24 * 3600 { return "长期" }
        return expire.formatted(date: .numeric, time: .omitted)
    }

    /// 更新时间显示：今天/昨天只显示时刻并标注，更早的带日期。
    var updatedText: String? {
        guard let updatedAt else { return nil }
        let time = updatedAt.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(updatedAt) { return "今天 \(time)" }
        if Calendar.current.isDateInYesterday(updatedAt) { return "昨天 \(time)" }
        return updatedAt.formatted(date: .numeric, time: .shortened)
    }

    // 容错解码：旧版 subscriptions.json 没有新字段，缺失时给默认值，避免整体解码失败丢订阅。
    enum CodingKeys: String, CodingKey {
        case id, name, url, yaml, updatedAt, nodeCount, upload, download, total, expire, autoNamed
        case overrideYAML
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
        overrideYAML = try c.decodeIfPresent(String.self, forKey: .overrideYAML) ?? ""
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
    @Published private(set) var isBusy = false

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("subscriptions.json")
    }()
    private let persistence = SubscriptionPersistence(fileURL: SubscriptionStore.fileURL)
    private var persistenceRevision = 0
    private var persistenceTask: Task<Void, Never>?
    private var refreshGenerations: [UUID: Int] = [:]
    private var activeRefreshes: [UUID: ActiveSubscriptionRefresh] = [:]
    private var activeRefreshCount = 0
    /// 只保留最近一次覆写结果，避免 SwiftUI 重绘或连接前检查反复解析大型 YAML。
    private var effectiveYAMLCache: (id: UUID, yaml: String)?

    private init() { load() }

    /// 当前选中订阅应用覆写后的 YAML（连接时传给 NE）。无选中/无内容返回 nil。
    var activeYAML: String? {
        guard let id = selectedID else { return nil }
        return effectiveYAML(for: id)
    }

    var selected: Subscription? {
        guard let id = selectedID else { return nil }
        return subscriptions.first(where: { $0.id == id })
    }

    /// 返回指定配置应用覆写后的最终 YAML；原始订阅内容不会被改写。
    func effectiveYAML(for id: UUID) -> String? {
        guard let sub = subscriptions.first(where: { $0.id == id }),
              !sub.yaml.isEmpty else { return nil }
        guard sub.hasOverride else { return sub.yaml }
        if let cached = effectiveYAMLCache, cached.id == id { return cached.yaml }
        guard let merged = try? Self.applyOverride(to: sub.yaml,
                                                   overrideYAML: sub.overrideYAML)
        else { return sub.yaml }
        effectiveYAMLCache = (id: id, yaml: merged)
        return merged
    }

    // MARK: - 增删改

    /// 添加订阅并立即拉取。
    func add(name: String, url: String) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { lastError = "订阅地址为空"; return }
        guard Self.remoteURL(trimmedURL) != nil else {
            lastError = "订阅地址必须是有效的 HTTP/HTTPS 链接"
            return
        }

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
        sub.nodeCount = Self.countProxies(yaml)
        sub.updatedAt = Date()
        subscriptions.append(sub)
        if selectedID == nil { selectedID = sub.id }
        lastError = Self.looksLikeClashYAML(yaml) ? nil
            : "已保存，但内容里没找到 proxies/proxy-groups，连接时可能无效"
        save()
    }

    /// 编辑本地配置（名称 + YAML）。
    func updateLocal(_ id: UUID, name: String, yaml: String) {
        guard let i = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        var merged: String?
        if subscriptions[i].hasOverride {
            do {
                merged = try Self.applyOverride(to: yaml,
                                                overrideYAML: subscriptions[i].overrideYAML)
            } catch {
                lastError = "保存失败：新配置与现有覆写无法合并（\(error.localizedDescription)）"
                return
            }
        }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { subscriptions[i].name = n }
        subscriptions[i].yaml = yaml
        subscriptions[i].nodeCount = Self.countProxies(yaml)
        subscriptions[i].updatedAt = Date()
        effectiveYAMLCache = merged.map { (id: id, yaml: $0) }
        lastError = Self.looksLikeClashYAML(yaml) ? nil
            : "已保存，但内容里没找到 proxies/proxy-groups，连接时可能无效"
        save()
    }

    /// 保存独立覆写层。空内容表示关闭覆写；非空内容先与当前原文合并校验。
    /// 返回 nil 表示保存成功，否则返回可直接显示的校验错误。
    func updateOverride(_ id: UUID, yaml: String) -> String? {
        guard let i = subscriptions.firstIndex(where: { $0.id == id }) else {
            return "配置不存在"
        }
        let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        var merged: String?
        if !trimmed.isEmpty {
            do {
                merged = try Self.applyOverride(to: subscriptions[i].yaml,
                                                overrideYAML: yaml)
            } catch {
                return "覆写 YAML 无效：\(error.localizedDescription)"
            }
        }
        subscriptions[i].overrideYAML = trimmed.isEmpty ? "" : yaml
        effectiveYAMLCache = merged.map { (id: id, yaml: $0) }
        save()
        return nil
    }

    /// 编辑远程订阅（名称 + 链接）。链接变更时先拉取并校验，成功后再原子替换旧内容；
    /// 用户手填过名称后，刷新不再用响应头覆盖（autoNamed 置 false）。
    func updateRemote(_ id: UUID, name: String, url: String) async {
        guard let i = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { lastError = "订阅地址为空"; return }
        guard let remoteURL = Self.remoteURL(u) else {
            lastError = "订阅地址必须是有效的 HTTP/HTTPS 链接"
            return
        }

        let urlChanged = subscriptions[i].url != u
        guard urlChanged else {
            if !n.isEmpty {
                subscriptions[i].name = n
                subscriptions[i].autoNamed = false
                save()
            }
            return
        }

        let previousURL = subscriptions[i].url
        let request = makeRequest(url: remoteURL)
        let (generation, task) = beginRefresh(id, request: request)
        lastError = nil
        defer { finishRefresh(id, generation: generation) }

        do {
            let payload = try await task.value
            guard isCurrentRefresh(id, generation: generation, url: previousURL),
                  let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
            let effective = try Self.validateOverride(subscriptions[index].overrideYAML,
                                                      for: payload.yaml)
            apply(payload, to: &subscriptions[index], resetMissingUsage: true)
            effectiveYAMLCache = effective.map { (id: id, yaml: $0) }
            subscriptions[index].url = u
            if !n.isEmpty {
                subscriptions[index].name = n
                subscriptions[index].autoNamed = false
            } else if subscriptions[index].autoNamed, let title = payload.title {
                subscriptions[index].name = title
            }
            save()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentRefresh(id, generation: generation, url: previousURL) else { return }
            lastError = "拉取失败：\(error.localizedDescription)；已保留原订阅配置"
        }
    }

    func remove(_ id: UUID) {
        invalidateRefresh(id)
        if effectiveYAMLCache?.id == id { effectiveYAMLCache = nil }
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
        guard let url = Self.remoteURL(urlString) else {
            lastError = "订阅地址必须是有效的 HTTP/HTTPS 链接"
            return
        }

        let request = makeRequest(url: url)
        let (generation, task) = beginRefresh(id, request: request)
        lastError = nil
        defer { finishRefresh(id, generation: generation) }

        do {
            let payload = try await task.value
            guard isCurrentRefresh(id, generation: generation, url: urlString),
                  let i = subscriptions.firstIndex(where: { $0.id == id }) else { return }
            let effective = try Self.validateOverride(subscriptions[i].overrideYAML,
                                                      for: payload.yaml)
            apply(payload, to: &subscriptions[i], resetMissingUsage: false)
            effectiveYAMLCache = effective.map { (id: id, yaml: $0) }
            if subscriptions[i].autoNamed, let title = payload.title {
                subscriptions[i].name = title
            }
            save()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentRefresh(id, generation: generation, url: urlString) else { return }
            lastError = "拉取失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 校验/统计

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        let userAgent = SettingsStore.shared.subscriptionUA
            .trimmingCharacters(in: .whitespaces)
        request.setValue(userAgent.isEmpty ? "clash-meta" : userAgent,
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return request
    }

    nonisolated private static func remoteURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    nonisolated private static func fetchSubscription(
        request: URLRequest
    ) async throws -> SubscriptionFetchPayload {
        let download: BoundedHTTPDownload
        do {
            download = try await BoundedHTTPDownloader.download(
                for: request,
                maxBytes: subscriptionMaximumDownloadBytes,
                resourceTimeout: 45)
        } catch let error as BoundedHTTPDownloadError {
            if case .tooLarge = error { throw SubscriptionRefreshError.tooLarge }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: download.fileURL) }

        let data = try Data(contentsOf: download.fileURL, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SubscriptionRefreshError.notText
        }
        guard looksLikeClashYAML(text) else {
            throw SubscriptionRefreshError.notClashYAML
        }

        let usageHeader = headerValue(download.response, "subscription-userinfo")
        let usage = usageHeader.map(parseUserInfo) ?? [:]
        let expiration = usage["expire"].flatMap { value in
            value > 0 ? Date(timeIntervalSince1970: TimeInterval(value)) : nil
        }
        return SubscriptionFetchPayload(
            yaml: text,
            nodeCount: countProxies(text),
            title: subscriptionTitle(download.response,
                                     fallbackHost: download.response.url?.host),
            hasUsageHeader: usageHeader != nil,
            upload: usage["upload"] ?? 0,
            download: usage["download"] ?? 0,
            total: usage["total"] ?? 0,
            expire: expiration)
    }

    private func apply(_ payload: SubscriptionFetchPayload,
                       to subscription: inout Subscription,
                       resetMissingUsage: Bool) {
        subscription.yaml = payload.yaml
        subscription.updatedAt = Date()
        subscription.nodeCount = payload.nodeCount
        if payload.hasUsageHeader || resetMissingUsage {
            subscription.upload = payload.upload
            subscription.download = payload.download
            subscription.total = payload.total
            subscription.expire = payload.expire
        }
    }

    /// 大小写不敏感地取响应头。
    nonisolated private static func headerValue(_ http: HTTPURLResponse, _ key: String) -> String? {
        if #available(iOS 13.0, *) {
            return http.value(forHTTPHeaderField: key)
        }
        return http.allHeaderFields[key] as? String
    }

    /// 解析 subscription-userinfo: "upload=..; download=..; total=..; expire=.."
    nonisolated private static func parseUserInfo(_ s: String) -> [String: Int64] {
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
    nonisolated private static func subscriptionTitle(_ http: HTTPURLResponse,
                                                       fallbackHost: String?) -> String? {
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

    nonisolated private static func filename(fromContentDisposition cd: String) -> String? {
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

    nonisolated private static func looksLikeClashYAML(_ text: String) -> Bool {
        text.contains("proxies:") || text.contains("proxy-groups:") || text.contains("proxy-providers:")
    }

    /// 粗略数 proxies 段下的 `- name:` 条目数，仅用于 UI 展示。
    nonisolated private static func countProxies(_ text: String) -> Int {
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

    private static func applyOverride(to baseYAML: String,
                                      overrideYAML: String) throws -> String {
        guard !overrideYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return baseYAML }
        var mergeError: NSError?
        let merged = MihomoApplyConfigOverride(baseYAML, overrideYAML, &mergeError)
        if let mergeError { throw mergeError }
        return merged
    }

    private static func validateOverride(_ overrideYAML: String,
                                         for baseYAML: String) throws -> String? {
        guard !overrideYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        do {
            return try applyOverride(to: baseYAML, overrideYAML: overrideYAML)
        } catch {
            throw SubscriptionRefreshError.overrideIncompatible(
                error.localizedDescription)
        }
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        if let decoded = try? JSONDecoder().decode(PersistedSubscriptions.self, from: data) {
            subscriptions = decoded.subscriptions
            selectedID = decoded.selectedID
        }
    }

    private func save() {
        persistenceRevision &+= 1
        let revision = persistenceRevision
        let snapshot = subscriptions
        let selectedID = selectedID
        let persistence = persistence
        let previousTask = persistenceTask
        persistenceTask = Task(priority: .utility) { [weak self] in
            await previousTask?.value
            do {
                try await persistence.save(subscriptions: snapshot,
                                           selectedID: selectedID,
                                           revision: revision)
            } catch {
                guard let self, revision == self.persistenceRevision else { return }
                self.lastError = "保存订阅失败：\(error.localizedDescription)"
            }
        }
    }

    /// App 进入后台前等待最后一次原子写入，降低刚编辑完就被挂起时的数据丢失概率。
    func flushPersistence() async {
        await persistenceTask?.value
    }

    private func beginRefresh(
        _ id: UUID,
        request: URLRequest
    ) -> (Int, Task<SubscriptionFetchPayload, Error>) {
        activeRefreshes[id]?.task.cancel()
        let next = (refreshGenerations[id] ?? 0) &+ 1
        refreshGenerations[id] = next
        let task = Task.detached(priority: .userInitiated) {
            try await Self.fetchSubscription(request: request)
        }
        activeRefreshes[id] = ActiveSubscriptionRefresh(generation: next, task: task)
        activeRefreshCount += 1
        isBusy = true
        return (next, task)
    }

    private func finishRefresh(_ id: UUID, generation: Int) {
        if activeRefreshes[id]?.generation == generation {
            activeRefreshes[id] = nil
        }
        activeRefreshCount = max(0, activeRefreshCount - 1)
        isBusy = activeRefreshCount > 0
    }

    private func invalidateRefresh(_ id: UUID) {
        activeRefreshes.removeValue(forKey: id)?.task.cancel()
        refreshGenerations[id] = (refreshGenerations[id] ?? 0) &+ 1
    }

    private func isCurrentRefresh(_ id: UUID, generation: Int, url: String) -> Bool {
        refreshGenerations[id] == generation
            && subscriptions.first(where: { $0.id == id })?.url == url
    }
}

private struct PersistedSubscriptions: Codable, Sendable {
    let subscriptions: [Subscription]
    let selectedID: UUID?
}

private struct SubscriptionFetchPayload: Sendable {
    let yaml: String
    let nodeCount: Int
    let title: String?
    let hasUsageHeader: Bool
    let upload: Int64
    let download: Int64
    let total: Int64
    let expire: Date?
}

private struct ActiveSubscriptionRefresh {
    let generation: Int
    let task: Task<SubscriptionFetchPayload, Error>
}

private actor SubscriptionPersistence {
    let fileURL: URL
    private var latestRevision = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func save(subscriptions: [Subscription], selectedID: UUID?, revision: Int) throws {
        guard revision >= latestRevision else { return }
        let payload = PersistedSubscriptions(subscriptions: subscriptions,
                                             selectedID: selectedID)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: fileURL, options: .atomic)
        latestRevision = revision
    }
}

private enum SubscriptionRefreshError: LocalizedError, Sendable {
    case tooLarge
    case notText
    case notClashYAML
    case overrideIncompatible(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "订阅内容超过 10 MB 上限"
        case .notText: return "订阅内容不是 UTF-8 文本"
        case .notClashYAML:
            return "订阅内容不是 Clash/mihomo YAML（可能是 base64 订阅，暂不支持）"
        case .overrideIncompatible(let reason):
            return "新订阅与现有覆写无法合并：\(reason)"
        }
    }
}
