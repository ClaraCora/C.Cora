import Foundation

/// PO0 防火墙白名单服务（Go 版 po0_whitelist.go / po0_transport.go 的 Swift 移植）。
/// 运行在 NE 进程内；NE 自身流量天然绕过隧道，URLSession 请求即为物理直连出口，
/// 与 Go 版显式绑定物理接口等效。IPC 命令同步返回当前快照；HTTP 检测在后台任务执行。
final class PO0WhitelistService: @unchecked Sendable {
    static let shared = PO0WhitelistService()

    private static let apiBase = "https://124.221.69.228/api/firewall/"
    private static let maxResponseBytes = 32 * 1024
    private static let initialDelay: TimeInterval = 2
    private static let minimumGap: TimeInterval = 10
    private static let requestTimeout: TimeInterval = 15
    private static let maxAttempts = 3
    private static let maxWhitelistEntries = 64

    private struct Token {
        let value: String
        let slot: Int?
    }

    private let lock = NSLock()
    private var configurationID = ""
    private var enabled = false
    private var checking = false
    private var pending = false
    private var lastCheckedAt: Double = 0
    private var nextCheckAt: Double = 0
    private var results: [PO0WhitelistResult] = []
    private var refreshing = false
    private var lastRefreshedAt: Double?
    private var tokens: [Token] = []
    private var intervalMinutes = 5
    private var worker: Task<Void, Never>?
    private var readOnlyTask: Task<Void, Never>?
    private var readOnlyGeneration: UInt64 = 0
    private var batchTail: Task<Void, Never>?
    private var wakeContinuation: CheckedContinuation<Bool, Never>?
    private var inFlightSession: URLSession?

    // MARK: - IPC 入口（同步返回快照或错误）

    func snapshotJSON() -> Data {
        lock.withLock {
            let snapshot = PO0WhitelistSnapshot(
                configurationID: configurationID, enabled: enabled, checking: checking,
                pending: pending, lastCheckedAt: lastCheckedAt, nextCheckAt: nextCheckAt,
                results: results, refreshing: refreshing, lastRefreshedAt: lastRefreshedAt)
            return (try? JSONEncoder().encode(snapshot)) ?? Data("{}".utf8)
        }
    }

    @discardableResult
    func configure(json: String) -> Data {
        guard let configuration = Self.parseConfiguration(json) else {
            return Self.errorJSON("PO0 设置格式不正确，请重新保存")
        }
        return configure(configuration)
    }

    @discardableResult
    func configure(_ configuration: PO0WhitelistConfiguration) -> Data {
        let tokens = Self.parseTokens(configuration.tokens)
        lock.withLock {
            cancelLocked()
            configurationID = configuration.id
            enabled = configuration.enabled
            intervalMinutes = configuration.intervalMinutes
            self.tokens = tokens
            checking = false
            pending = false
            refreshing = false
            lastCheckedAt = 0
            nextCheckAt = 0
            lastRefreshedAt = nil
            results = []
            guard configuration.enabled, !tokens.isEmpty else { return }
            pending = true
            nextCheckAt = Date().addingTimeInterval(Self.initialDelay).timeIntervalSince1970
            worker = Task { [weak self] in self?.workLoop() }
        }
        return snapshotJSON()
    }

    func request(networkChange: Bool) {
        let wake = lock.withLock { () -> Bool in
            guard worker != nil else { return false }
            if !networkChange && (checking || pending) { return false }
            pending = true
            return true
        }
        if wake { resumeWake(woke: true) }
    }

    @discardableResult
    func refreshReadOnly(json: String) -> Data {
        guard let configuration = Self.parseConfiguration(json) else {
            return Self.errorJSON("PO0 设置格式不正确，请重新保存")
        }
        let tokens = Self.parseTokens(configuration.tokens)
        guard !tokens.isEmpty else { return Self.errorJSON("请先填写并保存 PO0 Token") }
        let started = lock.withLock { () -> Bool in
            guard configuration.id == configurationID else { return false }
            guard readOnlyTask == nil else { return false }
            intervalMinutes = configuration.intervalMinutes
            self.tokens = tokens
            refreshing = true
            readOnlyGeneration &+= 1
            let generation = readOnlyGeneration
            readOnlyTask = Task { [weak self] in
                guard let self else { return }
                await self.fetchBatch(readOnly: true)
                self.lock.withLock {
                    guard self.readOnlyGeneration == generation else { return }
                    self.readOnlyTask = nil
                    self.refreshing = false
                }
            }
            return true
        }
        if !started {
            let mismatch = lock.withLock { configuration.id != configurationID && readOnlyTask == nil }
            if mismatch { return Self.errorJSON("PO0 设置尚未同步，请先保存设置后重试") }
        }
        return snapshotJSON()
    }

    func stop() {
        lock.withLock {
            cancelLocked()
            configurationID = ""
            enabled = false
            checking = false
            pending = false
            refreshing = false
            lastCheckedAt = 0
            nextCheckAt = 0
            lastRefreshedAt = nil
            results = []
            tokens = []
        }
    }

    // MARK: - 生命周期内部

    /// 调用时必须已持有 lock。
    private func cancelLocked() {
        worker?.cancel(); worker = nil
        readOnlyTask?.cancel(); readOnlyTask = nil
        readOnlyGeneration &+= 1
        inFlightSession?.invalidateAndCancel(); inFlightSession = nil
        let continuation = wakeContinuation
        wakeContinuation = nil
        continuation?.resume(returning: false)
    }

    private func resumeWake(woke: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            let c = wakeContinuation
            wakeContinuation = nil
            return c
        }
        continuation?.resume(returning: woke)
    }

    private func waitForWakeOrTimeout(_ delay: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.withLock { wakeContinuation = continuation }
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.resumeWake(woke: false)
            }
        }
    }

    private func workLoop() async {
        var lastStart = Date.distantPast
        var delay = Self.initialDelay
        while !Task.isCancelled {
            let woken = await waitForWakeOrTimeout(delay)
            if Task.isCancelled { break }
            if woken {
                // 合并网络抖动/手动连点：距上次检测不足 minimumGap 时顺延。
                delay = max(Self.initialDelay,
                            Self.minimumGap - Date().timeIntervalSince(lastStart))
                lock.withLock {
                    nextCheckAt = Date().addingTimeInterval(delay).timeIntervalSince1970
                }
                continue
            }
            lastStart = Date()
            lock.withLock {
                checking = true
                pending = false
                nextCheckAt = 0
            }
            await fetchBatch(readOnly: false)
            if Task.isCancelled { break }
            let interval = TimeInterval(lock.withLock { intervalMinutes }) * 60
            lock.withLock {
                checking = false
                nextCheckAt = Date().addingTimeInterval(interval).timeIntervalSince1970
            }
            delay = interval
        }
    }

    /// 批次串行化（Go 的 gate）：只读 GET 不得覆盖更新的自动 POST 结果。
    private func fetchBatch(readOnly: Bool) async {
        let task = lock.withLock { () -> Task<Void, Never> in
            let previous = batchTail
            let task = Task { [weak self] in
                _ = await previous?.value
                await self?.runBatch(readOnly: readOnly)
            }
            batchTail = task
            return task
        }
        await task.value
    }

    private func runBatch(readOnly: Bool) async {
        let (tokens, configID) = lock.withLock { (self.tokens, self.configurationID) }
        var results: [PO0WhitelistResult] = []
        results.reserveCapacity(tokens.count)
        for (index, token) in tokens.enumerated() {
            if Task.isCancelled { return }
            let result = await request(token: token, readOnly: readOnly)
            results.append(PO0WhitelistResult(
                index: index + 1, slot: result.slot, enabled: result.enabled,
                applied: result.applied, currentIp: result.currentIp,
                whitelist: result.whitelist, limit: result.limit,
                truncated: result.truncated, error: result.error, readOnly: result.readOnly))
        }
        if Task.isCancelled { return }
        lock.withLock {
            guard configurationID == configID else { return }
            self.results = results
            let now = Date().timeIntervalSince1970
            if readOnly { lastRefreshedAt = now } else { lastCheckedAt = now }
        }
    }

    // MARK: - HTTP

    private func session() -> URLSession {
        lock.withLock {
            if let existing = inFlightSession { return existing }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Self.requestTimeout
            config.timeoutIntervalForResource = Self.requestTimeout
            let session = URLSession(configuration: config)
            inFlightSession = session
            return session
        }
    }

    private func request(token: Token, readOnly: Bool) async -> PO0WhitelistResult {
        var endpoint = Self.apiBase + (token.value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token.value)
        var method = "GET"
        if !readOnly {
            method = "POST"
            endpoint += "/add"
            if let slot = token.slot { endpoint += "?slot=\(slot)" }
        }
        var result = PO0WhitelistResult(
            index: 0, slot: token.slot, enabled: false, applied: false, currentIp: "",
            whitelist: [], limit: 0, truncated: false,
            error: "网络请求失败，请检查网络或服务器证书", readOnly: readOnly)
        for attempt in 0..<Self.maxAttempts {
            if Task.isCancelled {
                result.error = "检测已取消"
                return result
            }
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                if Task.isCancelled {
                    result.error = "检测已取消"
                    return result
                }
            }
            guard let url = URL(string: endpoint) else {
                result.error = "请求地址无效"
                return result
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Cora/1.0 PO0Whitelist", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = Self.requestTimeout
            do {
                let (data, response) = try await session().data(for: request,
                                                                delegate: NoRedirectDelegate.shared)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard data.count <= Self.maxResponseBytes else {
                    result.error = "服务器响应过大，请稍后重试"
                    return result
                }
                let decoded = Self.decode(status: status, body: data,
                                          slot: token.slot, readOnly: readOnly)
                if (200..<300).contains(status) { return decoded }
                // Go：403 或带有效 JSON 的 4xx 直接返回；5xx/其他按重试处理。
                if status == 403 || (status < 500 && (try? JSONSerialization.jsonObject(with: data)) != nil) {
                    return decoded
                }
                result = decoded
            } catch {
                result.error = Task.isCancelled ? "检测已取消" : "网络请求失败，请检查网络或服务器证书"
            }
        }
        return result
    }

    private static func decode(status: Int, body: Data, slot: Int?, readOnly: Bool) -> PO0WhitelistResult {
        var result = PO0WhitelistResult(
            index: 0, slot: slot, enabled: false, applied: false, currentIp: "",
            whitelist: [], limit: 0, truncated: false, error: nil, readOnly: readOnly)
        if status == 403 {
            result.error = "请求被拒绝，请检查 Token；若为槽位冲突，请先在 PO0 网站删除旧槽位"
            return result
        }
        guard (200..<300).contains(status) else {
            result.error = "服务返回 HTTP \(status)，请检查 Token 或稍后重试"
            return result
        }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let enabled = object["enabled"] as? Bool,
              let currentIp = object["currentIp"] as? String, isValidPO0Address(currentIp),
              let rawWhitelist = object["whitelist"] as? [Any],
              let limit = object["limit"] as? Int, limit >= 0 else {
            result.error = "响应格式异常，请检查 Token 或稍后重试"
            return result
        }
        result.enabled = enabled
        result.currentIp = currentIp
        result.limit = limit
        var entries: [PO0WhitelistResult.Entry] = []
        entries.reserveCapacity(min(rawWhitelist.count, Self.maxWhitelistEntries))
        for raw in rawWhitelist {
            var ip: String?
            var entrySlot: Int?
            if let dict = raw as? [String: Any] {
                ip = dict["ip"] as? String
                entrySlot = dict["slot"] as? Int
            } else if let text = raw as? String {
                ip = text
            }
            guard let value = ip else {
                result.error = "白名单格式异常"
                return result
            }
            guard isValidPO0Address(value) else {
                result.error = "白名单地址格式异常"
                return result
            }
            if enabled && samePO0Network(value, currentIp) { result.applied = true }
            if entries.count < Self.maxWhitelistEntries {
                entries.append(PO0WhitelistResult.Entry(ip: value, slot: entrySlot))
            } else {
                result.truncated = true
            }
        }
        result.whitelist = entries
        return result
    }

    // MARK: - 地址工具（Go validPO0Address / samePO0Network）

    private static func isIPv4(_ value: String) -> Bool {
        let octets = value.components(separatedBy: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard let byte = UInt8(octet), String(byte) == octet else { return false }
            return true
        }
    }

    private static func isValidPO0Address(_ value: String) -> Bool {
        let parts = value.components(separatedBy: "/")
        guard parts.count == 1 || (parts.count == 2 && parts[1] == "24") else { return false }
        return isIPv4(parts[0])
    }

    private static func ipv4Bits(_ address: String) -> UInt32 {
        let host = address.components(separatedBy: "/")[0]
        var bits: UInt32 = 0
        for octet in host.components(separatedBy: ".") {
            bits = (bits << 8) | UInt32(UInt8(octet) ?? 0)
        }
        return bits
    }

    private static func samePO0Network(_ a: String, _ b: String) -> Bool {
        guard isValidPO0Address(a), isValidPO0Address(b) else { return false }
        if a == b { return true }
        if a.contains("/") && b.contains("/") { return false }
        return ipv4Bits(a) >> 8 == ipv4Bits(b) >> 8
    }

    // MARK: - 配置解析

    private static func parseConfiguration(_ json: String) -> PO0WhitelistConfiguration? {
        guard let data = json.data(using: .utf8), data.count <= 4096,
              let value = try? JSONDecoder().decode(PO0WhitelistConfiguration.self, from: data),
              let validated = try? value.validated() else { return nil }
        return validated
    }

    private static func parseTokens(_ tokens: String) -> [Token] {
        tokens.components(separatedBy: CharacterSet(charactersIn: ",|;、； \t\r\n"))
            .filter { !$0.isEmpty }
            .map { part in
                let pair = part.components(separatedBy: "@")
                return Token(value: pair[0], slot: pair.count == 2 ? Int(pair[1]) : nil)
            }
    }

    private static func errorJSON(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data("{}".utf8)
    }

    /// Go `CheckRedirect: ErrUseLastResponse`：重定向响应原样返回，不把 Token 带往别处。
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        static let shared = NoRedirectDelegate()
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
