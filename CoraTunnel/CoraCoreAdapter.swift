import Foundation
import MeowCore
import CryptoKit
import Darwin

/// Owns one runtime generation. Its authenticated controller is private to the
/// NE; no URLs, ports or credentials are returned to the application.
final class CoraCoreAdapter {
    let runtimeURL: URL
    let source: String
    let settingsJSON: String
    let runtimeYAML: String
    let notices: [String]
    let home: URL
    private let controller: String
    private let secret: String
    private let requests = NSLock()
    private var activeRequests: [UUID: URLSession] = [:]
    private var stopped = false

    init(source: String, settingsJSON: String, home: URL) throws {
        self.source = source
        self.settingsJSON = settingsJSON
        self.home = home
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        home.path.withCString { meow_core_set_home_dir($0) }
        meow_core_init()
        var settings = CoraNativeCore.dictionary(settingsJSON)
        settings["systemDNS"] = SystemDNS.excludingTunnel(SystemDNS.currentServers())
        let identity = (settings["profileID"] as? String ?? "legacy") + "\u{0}" + source
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        // Provider names are only unique inside a profile. Never share the
        // new core's mutable HTTP cache across unrelated subscriptions.
        let value = try CoraNativeCore.object("prepare", ["yaml": source, "settings": settings,
            "home": home.path, "cacheNamespace": digest,
            "mixedPort": (settings["mixedPort"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? (try Self.availablePort()),
            "dnsPort": try Self.availablePort()])
        guard let yaml = value["yaml"] as? String,
              let controller = value["controller"] as? String,
              let secret = value["secret"] as? String, !secret.isEmpty,
              controller.hasPrefix("127.0.0.1:") else {
            throw CoraNativeCore.failure("运行配置缺少受认证的 loopback controller")
        }
        runtimeYAML = yaml
        self.controller = controller
        self.secret = secret
        notices = value["notices"] as? [String] ?? []
        runtimeURL = home.appendingPathComponent("runtime-\(UUID().uuidString).yaml")
        try Data(yaml.utf8).write(to: runtimeURL, options: .atomic)
    }

    deinit { try? FileManager.default.removeItem(at: runtimeURL) }

    func start() throws {
        guard runtimeURL.path.withCString({ meow_engine_start($0) }) == 0 else {
            throw CoraNativeCore.failure(CoraNativeCore.lastError)
        }
        _ = CoraNativeCore.request("resetSession")
        // Listener tasks are asynchronous upstream. Wait briefly for the
        // authenticated API before declaring this generation usable.
        let readyDeadline = Date().addingTimeInterval(3)
        while true {
            do { _ = try api("GET", ["configs"], timeout: 1); break }
            catch {
                guard Date() < readyDeadline else { throw error }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        // Fail closed if an uncached provider was dropped during loading.
        let expected = try CoraNativeCore.object("manifest", ["yaml": source])
        for (key, endpoint) in [("requiredProxyProviders", "proxies"), ("requiredRuleProviders", "rules")] {
            let live = try api("GET", ["providers", endpoint])["providers"] as? [String: Any] ?? [:]
            for provider in expected[key] as? [[String: Any]] ?? [] {
                if let name = provider["name"] as? String, live[name] == nil {
                    throw CoraNativeCore.failure("$.\(key).\(name): Provider 加载失败，未提交此运行配置")
                }
            }
        }
        let settings = CoraNativeCore.dictionary(settingsJSON)
        for (group, member) in settings["proxySelections"] as? [String: String] ?? [:] {
            try select(group, member)
        }
    }

    /// Cancels control requests before stopping the engine. A cancelled old
    /// generation can never authenticate to the next generation's controller.
    func cancelRequests() {
        requests.lock()
        stopped = true
        let pending = Array(activeRequests.values)
        activeRequests.removeAll()
        requests.unlock()
        pending.forEach { $0.invalidateAndCancel() }
    }

    private func select(_ group: String, _ member: String) throws {
        let snapshot = try api("GET", ["proxies"])["proxies"] as? [String: [String: Any]] ?? [:]
        guard (snapshot[group]?["all"] as? [String] ?? []).contains(member) else {
            throw CoraNativeCore.failure("策略组 \(group) 中不存在成员 \(member)，未替换为相近名称")
        }
        let sources = try candidateProviders(group: group, name: member)
        let topMember = snapshot[member] != nil && (snapshot[member]?["provider-name"] as? String ?? "").isEmpty
        guard sources.count + (topMember ? 1 : 0) <= 1 else {
            throw CoraNativeCore.failure("策略组 \(group) 的成员 \(member) 来自多个来源，当前按名称选择存在歧义")
        }
        let code = group.withCString { g in member.withCString { meow_proxy_select(g, $0) } }
        if code == 0 { return }
        if code == -3 {
            // URL-test / fallback pinning is only exposed by the REST API.
            _ = try api("PUT", ["proxies", group], body: ["name": member])
        } else { throw CoraNativeCore.failure(CoraNativeCore.lastError) }
    }

    func command(_ command: String, _ object: [String: Any]) -> Data {
        do {
            switch command {
            case "hello": return CoraNativeCore.encode(CoreIPCCompatibility.hello(version: "meow-rs 0.26.1+fa7a7d6"))
            case "traffic", "runtime", "connections":
                var result = try CoraNativeCore.object(command, ["limit": object["limit"] ?? 200])
                if command == "runtime" {
                    var counters = MeowInterfaceTraffic()
                    meow_engine_interface_traffic(&counters)
                    result["interfaceTraffic"] = ["wifiUpload": counters.wifi_ethernet_upload,
                        "wifiDownload": counters.wifi_ethernet_download, "cellularUpload": counters.cellular_upload,
                        "cellularDownload": counters.cellular_download, "otherUpload": counters.other_upload,
                        "otherDownload": counters.other_download]
                    result["physFootprint"] = MemoryDiagnostics.physicalFootprint()
                    result["running"] = meow_engine_is_running() == 1
                }
                return CoraNativeCore.encode(result)
            case "queryProxies": return CoraNativeCore.encode(try proxySnapshot())
            case "selectProxy":
                try select(object["group"] as? String ?? "", object["name"] as? String ?? "")
                return CoraNativeCore.encode(["ok": true])
            case "getMode", "mode": return Data((try api("GET", ["configs"])["mode"] as? String ?? "rule").utf8)
            case "setMode":
                let mode = object["mode"] as? String ?? "rule"
                guard ["rule", "global", "direct"].contains(mode) else { throw CoraNativeCore.failure("无效分流模式") }
                _ = try api("PATCH", ["configs"], body: ["mode": mode])
                return CoraNativeCore.encode(["ok": true])
            case "groupDelay":
                let group = object["group"] as? String ?? ""
                return CoraNativeCore.encode(try api("GET", ["group", group, "delay"], query: delayQuery(object, name: group), timeout: 25))
            case "proxyDelay": return CoraNativeCore.encode(try delay(object))
            case "proxyDelays":
                let targets = object["targets"] as? [[String: Any]] ?? []
                guard targets.count <= 256 else { throw CoraNativeCore.failure("单次批量测速最多 256 个目标") }
                var results: [String: Int] = [:]
                let deadline = Date().addingTimeInterval(25)
                for target in targets {
                    guard deadline.timeIntervalSinceNow > 1 else { break }
                    var request = object
                    request.merge(target) { _, new in new }
                    let key = target["key"] as? String ?? ""
                    request["timeout"] = min((request["timeout"] as? Int) ?? 5000, max(1, Int((deadline.timeIntervalSinceNow - 1) * 1000)))
                    results[key] = (try? delay(request)["delay"] as? Int) ?? 0
                }
                return CoraNativeCore.encode(["results": results, "_partial": results.count < targets.count])
            case "updateProxyProviders", "updateProxyProvider", "updateRuleProviders", "updateRuleProvider":
                return CoraNativeCore.encode(try updateProviders(command, object))
            case "remoteResourceStatus": return CoraNativeCore.encode(try resourceStatus())
            case "readRuleProvider":
                let content = try CoraNativeCore.object("ruleContent", ["yaml": runtimeYAML, "home": home.path,
                    "name": object["name"] ?? "", "maxBytes": object["maxBytes"] ?? 1048576])
                return CoraNativeCore.encode(CoreIPCCompatibility.ruleContent(content))
            case "closeConnection":
                _ = try api("DELETE", ["connections", object["id"] as? String ?? ""])
                return CoraNativeCore.encode(["ok": true])
            case "closeAllConnections":
                _ = try api("DELETE", ["connections"])
                return CoraNativeCore.encode(["ok": true])
            case "proxyDetails": return CoraNativeCore.error("meow-rs 暂无与 Cora 节点详情探测等价的接口")
            case "configNotices": return CoraNativeCore.encode(notices)
            case "runLogChunk": return try logChunk(object)
            case "logs": return try logChunk(object)
            case "scriptFetch", "scriptTargetInfo", "directNetworkInfo":
                return CoraNativeCore.error("meow-rs 尚不支持该 Cora 脚本/特殊诊断接口，原设置仍保留")
            case "po0WhitelistStatus", "setPO0Whitelist", "checkPO0Whitelist", "refreshPO0Whitelist":
                return CoraNativeCore.error("meow-rs 尚不支持 PO0 自动白名单，原设置仍保留")
            case "releaseMemory": return CoraNativeCore.error("Rust 没有 Go GC；该内核不支持手动回收内存")
            default: return CoraNativeCore.error("meow-rs 不支持命令：\(command)")
            }
        } catch { return CoraNativeCore.error(error.localizedDescription, code: "core_error") }
    }

    private func proxySnapshot() throws -> [String: Any] {
        var result = try api("GET", ["proxies"])
        var types: [String: String] = [:]
        for (name, info) in result["proxies"] as? [String: [String: Any]] ?? [:] {
            if info["all"] == nil { types[name] = info["type"] as? String ?? "" }
        }
        let providers = try api("GET", ["providers", "proxies"])["providers"] as? [String: [String: Any]] ?? [:]
        var catalog: [[String: Any]] = []
        for (provider, info) in providers {
            for node in info["proxies"] as? [[String: Any]] ?? [] {
                var copy = node
                copy["provider-name"] = provider
                catalog.append(copy)
                if let name = node["name"] as? String, types[name] == nil { types[name] = node["type"] as? String ?? "" }
            }
        }
        result["mode"] = try api("GET", ["configs"])["mode"] ?? "rule"
        result["nodeTypes"] = types
        result["providerNodes"] = catalog
        return result
    }

    private func delayQuery(_ object: [String: Any], name: String) -> [URLQueryItem] {
        let direct = name == "DIRECT"
        let url = object[direct ? "directURL" : "url"] as? String ?? "https://www.gstatic.com/generate_204"
        let timeout = min(10000, max(1, (object["timeout"] as? NSNumber)?.intValue ?? 5000))
        return [URLQueryItem(name: "url", value: url), URLQueryItem(name: "timeout", value: String(timeout))]
    }

    private func delay(_ object: [String: Any]) throws -> [String: Any] {
        let name = object["name"] as? String ?? ""
        let providers = try api("GET", ["providers", "proxies"])["providers"] as? [String: [String: Any]] ?? [:]
        let matches = providers.compactMap { provider, info -> String? in
            (info["proxies"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == name } ? provider : nil
        }
        let top = try api("GET", ["proxies"])["proxies"] as? [String: [String: Any]] ?? [:]
        let explicit = object["provider"] as? String
        let timeout = TimeInterval(min(10000, max(1, (object["timeout"] as? Int) ?? 5000))) / 1000 + 0.5
        if let explicit, matches.contains(explicit) {
            return try api("GET", ["providers", "proxies", explicit, name, "healthcheck"], query: delayQuery(object, name: name), timeout: timeout)
        }
        if explicit != nil { throw CoraNativeCore.failure("指定 Provider 中不存在该节点") }
        // The UI sends group + name. Resolve that group's explicit use list;
        // never let the API's name fallback choose an unrelated provider.
        if let group = object["group"] as? String, !group.isEmpty {
            let manifest = try CoraNativeCore.object("manifest", ["yaml": source])
            if let definition = (manifest["groupSources"] as? [[String: Any]])?.first(where: { $0["name"] as? String == group }) {
                let uses = definition["use"] as? [String] ?? []
                let candidates = matches.filter { uses.contains($0) || definition["include-all"] as? Bool == true || definition["include-all-providers"] as? Bool == true }
                let explicitTop = (definition["proxies"] as? [String] ?? []).contains(name)
                    || definition["include-all"] as? Bool == true || definition["include-all-proxies"] as? Bool == true
                let isTop = top[name] != nil && (top[name]?["provider-name"] as? String ?? "").isEmpty
                if candidates.count == 1 && !(explicitTop && isTop) {
                    return try api("GET", ["providers", "proxies", candidates[0], name, "healthcheck"], query: delayQuery(object, name: name), timeout: timeout)
                }
                if candidates.isEmpty && explicitTop && isTop {
                    return try api("GET", ["proxies", name, "delay"], query: delayQuery(object, name: name), timeout: timeout)
                }
            }
        }
        // Never guess which same-named node the UI intended.
        let isTop = top[name] != nil && (top[name]?["provider-name"] as? String ?? "").isEmpty
        guard matches.count + (isTop ? 1 : 0) <= 1 else {
            throw CoraNativeCore.failure("节点 \(name) 存在于多个来源；请在 Provider 中按来源选择，不能按名称猜测")
        }
        let path = matches.first.map { ["providers", "proxies", $0, name, "healthcheck"] } ?? ["proxies", name, "delay"]
        return try api("GET", path, query: delayQuery(object, name: name), timeout: timeout)
    }

    private func candidateProviders(group: String, name: String) throws -> [String] {
        let manifest = try CoraNativeCore.object("manifest", ["yaml": source])
        let definition = (manifest["groupSources"] as? [[String: Any]])?.first { $0["name"] as? String == group }
        let uses = definition?["use"] as? [String] ?? []
        let includeAll = definition?["include-all"] as? Bool == true || definition?["include-all-providers"] as? Bool == true
        let providers = try api("GET", ["providers", "proxies"])["providers"] as? [String: [String: Any]] ?? [:]
        return providers.compactMap { provider, info in
            guard uses.contains(provider) || includeAll else { return nil }
            return (info["proxies"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == name } ? provider : nil
        }
    }

    private func updateProviders(_ command: String, _ object: [String: Any]) throws -> [String: Any] {
        let kind = command.contains("Rule") ? "rules" : "proxies"
        let all = try api("GET", ["providers", kind])["providers"] as? [String: Any] ?? [:]
        let names = (object["name"] as? String).map { [$0] } ?? all.keys.sorted()
        var failures: [String: String] = [:]
        var updated: [String] = []
        for name in names {
            do { _ = try api("PUT", ["providers", kind, name], timeout: 20); updated.append(name) }
            catch { failures[name] = error.localizedDescription }
        }
        return CoreIPCCompatibility.providerUpdate(updated: updated, failures: failures)
    }

    private func resourceStatus() throws -> [String: Any] {
        var resources: [[String: Any]] = []
        for (endpoint, kind) in [("proxies", "proxyProvider"), ("rules", "ruleProvider")] {
            let all = try api("GET", ["providers", endpoint])["providers"] as? [String: [String: Any]] ?? [:]
            for (name, info) in all {
                if let date = info["updatedAt"] as? String, let normalized = CoreIPCCompatibility.resourceTimestamp(date) {
                    resources.append(["name": name, "kind": kind, "updatedAt": normalized])
                }
            }
        }
        return ["ok": true, "resources": resources]
    }

    private func logChunk(_ object: [String: Any]) throws -> Data {
        let url = home.appendingPathComponent("logs/meow-tunnel.log")
        guard let file = try? FileHandle(forReadingFrom: url) else {
            return CoraNativeCore.encode(["offset": 0, "generation": 0, "text": "", "reset": true])
        }
        defer { try? file.close() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let generation = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = try file.seekToEnd()
        let requested = (object["offset"] as? NSNumber)?.int64Value ?? -1
        let same = (object["generation"] as? NSNumber)?.uint64Value == generation
        let reset = !same || requested < 0 || UInt64(max(0, requested)) > size
        let offset = reset ? (size > 24576 ? size - 24576 : 0) : UInt64(requested)
        try file.seek(toOffset: offset)
        let data = try file.read(upToCount: 24576) ?? Data()
        let lines = CoreIPCCompatibility.logLines(data, startsInsideLine: reset && offset > 0, capacity: 24576)
        return CoraNativeCore.encode(["offset": offset + UInt64(lines.consumed), "generation": generation,
            "text": lines.text, "reset": reset])
    }

    private func api(_ method: String, _ path: [String], body: [String: Any]? = nil,
                     query: [URLQueryItem] = [], timeout: TimeInterval = 15) throws -> [String: Any] {
        var components = URLComponents(string: "http://\(controller)")!
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        components.percentEncodedPath = "/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = CoraNativeCore.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let collector = CoreHTTPResponse()
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: collector, delegateQueue: nil)
        let id = UUID()
        requests.lock()
        if stopped { requests.unlock(); session.invalidateAndCancel(); throw CoraNativeCore.failure("内核会话已结束") }
        activeRequests[id] = session
        requests.unlock()
        defer {
            session.invalidateAndCancel()
            requests.lock(); activeRequests.removeValue(forKey: id); requests.unlock()
        }
        session.dataTask(with: request).resume()
        guard collector.done.wait(timeout: .now() + timeout + 1) == .success else { throw CoraNativeCore.failure("loopback API 超时") }
        if let error = collector.error { throw error }
        let object = (try? JSONSerialization.jsonObject(with: collector.data)) as? [String: Any]
        guard (200..<300).contains(collector.status) else {
            throw CoraNativeCore.failure(object?["message"] as? String ?? "loopback API HTTP \(collector.status)")
        }
        if collector.data.isEmpty && method != "GET" { return [:] }
        guard let object else { throw CoraNativeCore.failure("loopback API 返回了无效 JSON") }
        return object
    }

    private static func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CoraNativeCore.failure("不能创建内部监听端口") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                guard bind(fd, pointer, length) == 0 else { return Int32(-1) }
                return getsockname(fd, pointer, &length)
            }
        }
        guard rc == 0 else { throw CoraNativeCore.failure("不能分配内部监听端口") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// Bounds every REST body before accumulation, also disallows redirects away
/// from the authenticated loopback controller.
private final class CoreHTTPResponse: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var data = Data()
    var error: Error?
    var status = 0
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if response.expectedContentLength > 8 * 1024 * 1024 { completionHandler(.cancel) }
        else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        if data.count + bytes.count > 8 * 1024 * 1024 {
            error = CoraNativeCore.failure("控制响应超过 8 MB 上限"); dataTask.cancel()
        } else { data.append(bytes) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError failure: Error?) {
        if error == nil { error = failure }; done.signal()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
