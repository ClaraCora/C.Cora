import Foundation

private let subscriptionMaximumDownloadBytes: Int64 = 10 * 1_024 * 1_024
private let proxyProviderMaximumDownloadBytes: Int64 = 10 * 1_024 * 1_024

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
    var overrideEnabled: Bool // 是否应用全局固定覆写设置
    var proxySelections: [String: String] // 离线选择，下次连接时恢复

    init(id: UUID = UUID(), name: String, url: String, yaml: String = "",
         updatedAt: Date? = nil, nodeCount: Int = 0,
         upload: Int64 = 0, download: Int64 = 0, total: Int64 = 0,
         expire: Date? = nil, autoNamed: Bool = false,
         overrideEnabled: Bool = false,
         proxySelections: [String: String] = [:]) {
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
        self.overrideEnabled = overrideEnabled
        self.proxySelections = proxySelections
    }

    var used: Int64 { upload + download }
    var remaining: Int64 { max(0, total - used) }
    var hasUsage: Bool { total > 0 }
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
        case overrideEnabled, proxySelections
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
        overrideEnabled = try c.decodeIfPresent(Bool.self, forKey: .overrideEnabled) ?? false
        proxySelections = try c.decodeIfPresent([String: String].self,
                                                forKey: .proxySelections) ?? [:]
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
    @Published private(set) var refreshingProviderIDs: Set<UUID> = []
    @Published private(set) var providerCacheRevision = 0

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("subscriptions.json")
    }()
    private static let providerCacheDirectory: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("ProxyProviderCache", isDirectory: true)
    }()
    private let persistence = SubscriptionPersistence(fileURL: SubscriptionStore.fileURL)
    private var persistenceRevision = 0
    private var persistenceTask: Task<Void, Never>?
    private var refreshGenerations: [UUID: Int] = [:]
    private var activeRefreshes: [UUID: ActiveSubscriptionRefresh] = [:]
    private var activeRefreshCount = 0
    private init() { load() }

    /// 当前选中的订阅原文。固定覆写由 NE 按该配置的开关统一应用。
    var activeYAML: String? {
        guard let id = selectedID else { return nil }
        return subscriptions.first(where: { $0.id == id })?.yaml
    }

    var selected: Subscription? {
        guard let id = selectedID else { return nil }
        return subscriptions.first(where: { $0.id == id })
    }

    var activeOverridesEnabled: Bool {
        selected?.overrideEnabled ?? false
    }

    var activeProxySelections: [String: String] {
        selected?.proxySelections ?? [:]
    }

    var hasRemoteSubscriptions: Bool {
        subscriptions.contains { !$0.isLocal }
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
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { subscriptions[i].name = n }
        subscriptions[i].yaml = yaml
        subscriptions[i].nodeCount = Self.countProxies(yaml)
        subscriptions[i].updatedAt = Date()
        lastError = Self.looksLikeClashYAML(yaml) ? nil
            : "已保存，但内容里没找到 proxies/proxy-groups，连接时可能无效"
        save()
    }

    func setOverrideEnabled(_ id: UUID, enabled: Bool) {
        guard let i = subscriptions.firstIndex(where: { $0.id == id }),
              subscriptions[i].overrideEnabled != enabled else { return }
        subscriptions[i].overrideEnabled = enabled
        save()
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
            apply(payload, to: &subscriptions[index], resetMissingUsage: true)
            subscriptions[index].url = u
            removeProviderCache(id)
            if !n.isEmpty {
                subscriptions[index].name = n
                subscriptions[index].autoNamed = false
            } else if subscriptions[index].autoNamed, let title = payload.title {
                subscriptions[index].name = title
            }
            save()
            if Self.hasRemoteProxyProviders(payload.yaml) {
                await refreshProxyProviders(id, updateRuntime: false)
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentRefresh(id, generation: generation, url: previousURL) else { return }
            lastError = "拉取失败：\(error.localizedDescription)；已保留原订阅配置"
        }
    }

    func remove(_ id: UUID) {
        invalidateRefresh(id)
        removeProviderCache(id)
        subscriptions.removeAll { $0.id == id }
        if selectedID == id { selectedID = subscriptions.first?.id }
        save()
    }

    func select(_ id: UUID) {
        selectedID = id
        save()
    }

    func selectProxyOffline(subscriptionID: UUID, group: String, name: String) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }),
              subscriptions[index].proxySelections[group] != name else { return }
        subscriptions[index].proxySelections[group] = name
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
            apply(payload, to: &subscriptions[i], resetMissingUsage: false)
            if subscriptions[i].autoNamed, let title = payload.title {
                subscriptions[i].name = title
            }
            save()
            if Self.hasRemoteProxyProviders(payload.yaml) {
                await refreshProxyProviders(id, updateRuntime: false)
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentRefresh(id, generation: generation, url: urlString) else { return }
            lastError = "拉取失败：\(error.localizedDescription)"
        }
    }

    /// 依次重新下载全部远程订阅。本地手写配置没有外部来源，保持原内容不变。
    func refreshRemoteSubscriptions() async {
        let remotes = subscriptions.filter { !$0.isLocal }.map { ($0.id, $0.name) }
        guard !remotes.isEmpty else { return }

        var failures: [String] = []
        for (id, name) in remotes {
            await refresh(id)
            if let error = lastError {
                failures.append("\(name)：\(error)")
            }
        }
        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    /// 刷新订阅声明的 HTTP proxy-providers。连接中时先让运行内核原地更新，
    /// 同时由主 App 保存一份订阅隔离缓存，供断开状态下浏览节点。
    func refreshProxyProviders(_ id: UUID, updateRuntime: Bool = true) async {
        guard !refreshingProviderIDs.contains(id),
              let subscription = subscriptions.first(where: { $0.id == id }),
              !subscription.isLocal else { return }
        refreshingProviderIDs.insert(id)
        lastError = nil
        defer { refreshingProviderIDs.remove(id) }

        var failures: [String] = []
        let runtimeStatus = CoreStateManager.shared.status
        if updateRuntime && selectedID == id &&
            (runtimeStatus == .connected || runtimeStatus == .reasserting) {
            switch await CoreStateManager.shared.sendMessage(["cmd": "updateProxyProviders"]) {
            case .failure(let reason):
                failures.append("运行内核：\(reason)")
            case .ok(let data):
                if let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let providerFailures = response["failures"] as? [String: String] {
                    failures.append(contentsOf: providerFailures.sorted(by: { $0.key < $1.key })
                        .map { "\($0.key)：\($0.value)" })
                }
            }
        }

        do {
            let providers = try Self.providerManifest(subscription.yaml)
            guard !providers.isEmpty else {
                throw ProxyProviderRefreshError.noRemoteProviders
            }
            var cached = Self.loadProviderCache(id)
            var downloaded = 0
            for provider in providers {
                do {
                    guard let url = Self.remoteURL(provider.url) else {
                        throw ProxyProviderRefreshError.invalidURL(provider.name)
                    }
                    var request = makeRequest(url: url)
                    for (field, values) in provider.header where !values.isEmpty {
                        request.setValue(values.joined(separator: ", "),
                                         forHTTPHeaderField: field)
                    }
                    let download = try await BoundedHTTPDownloader.download(
                        for: request,
                        maxBytes: proxyProviderMaximumDownloadBytes,
                        resourceTimeout: 45)
                    defer { try? FileManager.default.removeItem(at: download.fileURL) }
                    let data = try Data(contentsOf: download.fileURL, options: .mappedIfSafe)
                    guard let payload = String(data: data, encoding: .utf8) else {
                        throw SubscriptionRefreshError.notText
                    }
                    if let validationError = MihomoCore.validateProxyProviderPayload(payload) {
                        throw ProxyProviderRefreshError.invalidPayload(provider.name, validationError)
                    }
                    cached[provider.name] = payload
                    downloaded += 1
                } catch {
                    failures.append("\(provider.name)：\(error.localizedDescription)")
                }
            }
            if downloaded > 0 {
                try Self.saveProviderCache(cached, id: id)
                updateNodeCount(id, providerPayloads: cached)
                providerCacheRevision &+= 1
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        lastError = failures.isEmpty ? nil : "Provider 刷新未全部完成：\n" + failures.joined(separator: "\n")
    }

    func providerPayloadsJSON(for id: UUID) -> String {
        let cache = Self.loadProviderCache(id)
        guard let data = try? JSONEncoder().encode(cache),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private func updateNodeCount(_ id: UUID, providerPayloads: [String: String]) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }),
              let payloadData = try? JSONEncoder().encode(providerPayloads),
              let payloadJSON = String(data: payloadData, encoding: .utf8),
              let selectionData = try? JSONEncoder().encode(subscriptions[index].proxySelections),
              let selectionJSON = String(data: selectionData, encoding: .utf8) else { return }
        let data = MihomoCore.offlineProxySnapshot(configYAML: subscriptions[index].yaml,
                                                   providerPayloadsJSON: payloadJSON,
                                                   selectionsJSON: selectionJSON)
        guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              response["error"] == nil,
              let count = response["nodeCount"] as? Int else { return }
        subscriptions[index].nodeCount = count
        save()
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

    private static func providerManifest(_ yaml: String) throws -> [RemoteProxyProvider] {
        let data = MihomoCore.proxyProviderManifest(configYAML: yaml)
        let response = try JSONDecoder().decode(ProxyProviderManifestResponse.self, from: data)
        if let error = response.error { throw ProxyProviderRefreshError.manifest(error) }
        return response.providers
    }

    private static func hasRemoteProxyProviders(_ yaml: String) -> Bool {
        (try? providerManifest(yaml).isEmpty == false) ?? false
    }

    private static func providerCacheURL(_ id: UUID) -> URL {
        providerCacheDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private static func loadProviderCache(_ id: UUID) -> [String: String] {
        guard let data = try? Data(contentsOf: providerCacheURL(id)),
              let cache = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return cache
    }

    private static func saveProviderCache(_ cache: [String: String], id: UUID) throws {
        try FileManager.default.createDirectory(at: providerCacheDirectory,
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(cache)
        try data.write(to: providerCacheURL(id), options: .atomic)
    }

    private func removeProviderCache(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.providerCacheURL(id))
        providerCacheRevision &+= 1
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

private struct RemoteProxyProvider: Decodable, Sendable {
    let name: String
    let url: String
    let header: [String: [String]]

    private enum CodingKeys: String, CodingKey { case name, url, header }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        header = try container.decodeIfPresent([String: [String]].self, forKey: .header) ?? [:]
    }
}

private struct ProxyProviderManifestResponse: Decodable, Sendable {
    let providers: [RemoteProxyProvider]
    let error: String?
}

private enum ProxyProviderRefreshError: LocalizedError {
    case noRemoteProviders
    case invalidURL(String)
    case invalidPayload(String, String)
    case manifest(String)

    var errorDescription: String? {
        switch self {
        case .noRemoteProviders:
            return "当前配置没有可刷新的远程 Proxy Provider"
        case .invalidURL(let name):
            return "Provider \(name) 的链接无效"
        case .invalidPayload(let name, let reason):
            return "Provider \(name) 内容无效：\(reason)"
        case .manifest(let reason):
            return "解析 Provider 配置失败：\(reason)"
        }
    }
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

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "订阅内容超过 10 MB 上限"
        case .notText: return "订阅内容不是 UTF-8 文本"
        case .notClashYAML:
            return "订阅内容不是 Clash/mihomo YAML（可能是 base64 订阅，暂不支持）"
        }
    }
}
