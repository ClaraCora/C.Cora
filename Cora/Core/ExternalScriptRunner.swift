import Combine
import CryptoKit
import Foundation
@preconcurrency import JavaScriptCore

struct ExternalDetectionScript: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let version: String
    let scriptURL: URL
    let sha256: String
    let icon: String
}

struct UnlockTestResult: Identifiable, Sendable {
    let id = UUID()
    let nodeName: String
    let groupName: String
    let scriptID: String
    let scriptName: String
    let scriptIcon: String
    let scriptVersion: String
    let title: String
    let message: String
}

enum ExternalScriptLimits {
    static let maxRequestTimeoutMilliseconds = 15_000
    static let maxExecutionSeconds: TimeInterval = 45
}

/// Values supplied by the NE for the one network-info script. They are
/// ephemeral test data, never written to the script cache or app storage.
private struct ScriptRuntimeContext: Sendable {
    let nodeInfo: [String: String]
    let directNetworkInfo: [String: String]

    static let empty = Self(nodeInfo: [:], directNetworkInfo: [:])

    @MainActor
    static func load(nodeName: String, groupName: String) async -> Self {
        let targetResult = await CoreStateManager.shared.sendMessage([
            "cmd": "scriptTargetInfo", "name": nodeName, "group": groupName,
        ])
        let directResult = await CoreStateManager.shared.sendMessage(["cmd": "directNetworkInfo"])
        return Self(nodeInfo: decodedInfo(from: targetResult),
                    directNetworkInfo: decodedInfo(from: directResult))
    }

    @MainActor
    private static func decodedInfo(from result: TunnelManager.IPCResult) -> [String: String] {
        guard case .ok(let data) = result,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["ok"] as? Bool) == true else {
            return [:]
        }
        var values: [String: String] = [:]
        for (key, value) in object {
            if let text = value as? String, !text.isEmpty {
                values[key] = text
            } else if let number = value as? NSNumber {
                values[key] = number.stringValue
            }
        }
        return values
    }
}

/// Downloads and caches only the signed script selected by the Cora manifest.
/// The app never bundles the detection logic itself.
@MainActor
final class ExternalScriptStore: ObservableObject {
    static let shared = ExternalScriptStore()

    private static let manifestURL = URL(string: "https://raw.githubusercontent.com/ClaraCora/lo/main/cora/manifest.json")!
    private static let signatureURL = URL(string: "https://raw.githubusercontent.com/ClaraCora/lo/main/cora/manifest.sig")!
    private static let trustedPublicKey = "zW2SsWm6+muJOGUp5j9KLOlQDouV+d8IKzq+aL/5Wnk="
    private static let cacheDirectory: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoraScripts", isDirectory: true)
    }()

    private static let fallbackScripts: [ExternalDetectionScript] = [
        ExternalDetectionScript(id: "node-unlock-detection", name: "节点解锁检测", version: "",
                                scriptURL: URL(string: "https://raw.githubusercontent.com/ClaraCora/lo/main/cora/NodeUnlockDetection.js")!,
                                sha256: "", icon: "play.tv"),
    ]

    private struct Manifest: Decodable {
        let apiVersion: Int
        let scripts: [ManifestScript]
    }

    private struct ManifestScript: Decodable {
        let id: String
        let name: String
        let version: String
        let scriptURL: URL
        let sha256: String
        let requiredCapabilities: [String]
        let icon: String?
    }

    private struct CachedScript: Codable {
        let id: String
        let name: String?
        let icon: String?
        let scriptURL: URL?
        let version: String
        let sha256: String
        let updatedAt: Date?
    }

    @Published private(set) var cachedVersion: String?
    @Published private(set) var cachedUpdatedAt: Date?
    @Published private(set) var isUpdating = false
    @Published private(set) var updateMessage: String?
    @Published private(set) var availableScripts: [ExternalDetectionScript]
    @Published private(set) var hasManifest = false

    private init() {
        availableScripts = Self.fallbackScripts
        if let cachedManifest = Self.loadCachedManifest() {
            let definitions = Self.definitions(from: cachedManifest)
            availableScripts = Self.mergedDefinitions(definitions)
            hasManifest = Self.requiredScriptIDs.isSubset(of: Set(definitions.map(\.id)))
        }
        refreshCacheState()
    }

    func loadUnlockScript() async throws -> ExternalDetectionScript {
        try await loadScript(id: "node-unlock-detection")
    }

    func loadScript(id: String) async throws -> ExternalDetectionScript {
        if let cached = validCachedScript(id: id) {
            if id == "node-unlock-detection" { publishCacheState(cached.metadata) }
            return metadata(from: cached.metadata)
        }
        return try await refreshScript(id: id)
    }

    /// 设置页调用的显式更新。签名或下载失败时保留旧缓存。
    func refreshUnlockScript() async throws -> ExternalDetectionScript {
        try await refreshScript(id: "node-unlock-detection")
    }

    /// Refreshes the signed manifest so new scripts can appear in node menus.
    @discardableResult
    func refreshManifest() async throws -> [ExternalDetectionScript] {
        guard !isUpdating else { throw ScriptLoadError.updateInProgress }
        isUpdating = true
        defer { isUpdating = false }
        do {
            let manifestData = try await Self.download(Self.manifestURL, maxBytes: 256 * 1024)
            let signatureData = try await Self.download(Self.signatureURL, maxBytes: 8 * 1024)
            try Self.verify(manifestData: manifestData, signature: signatureData)
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            guard manifest.apiVersion == 1 else { throw ScriptLoadError.invalidManifest }
            let definitions = Self.definitions(from: manifest)
            guard !definitions.isEmpty else { throw ScriptLoadError.invalidManifest }
            try Self.saveManifest(manifestData)
            availableScripts = Self.mergedDefinitions(definitions)
            hasManifest = Self.requiredScriptIDs.isSubset(of: Set(definitions.map(\.id)))
            return definitions
        } catch {
            updateMessage = "更新失败：\(error.localizedDescription)"
            throw error
        }
    }

    func refreshScript(id: String) async throws -> ExternalDetectionScript {
        if isUpdating {
            if let cached = validCachedScript(id: id) {
                return metadata(from: cached.metadata)
            }
            throw ScriptLoadError.updateInProgress
        }
        isUpdating = true
        updateMessage = nil
        defer { isUpdating = false }

        do {
            let manifestData = try await Self.download(Self.manifestURL, maxBytes: 256 * 1024)
            let signatureData = try await Self.download(Self.signatureURL, maxBytes: 8 * 1024)
            try Self.verify(manifestData: manifestData, signature: signatureData)
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            guard manifest.apiVersion == 1,
                  let entry = manifest.scripts.first(where: { $0.id == id }),
                  entry.requiredCapabilities.contains("node-http") else {
                throw ScriptLoadError.invalidManifest
            }
            let definitions = Self.definitions(from: manifest)
            try Self.saveManifest(manifestData)
            availableScripts = Self.mergedDefinitions(definitions)
            hasManifest = Self.requiredScriptIDs.isSubset(of: Set(definitions.map(\.id)))
            let scriptData = try await Self.download(entry.scriptURL, maxBytes: 512 * 1024)
            guard Self.sha256(scriptData) == entry.sha256.lowercased() else {
                throw ScriptLoadError.hashMismatch
            }
            let cached = CachedScript(id: entry.id,
                                      name: entry.name,
                                      icon: entry.icon,
                                      scriptURL: entry.scriptURL,
                                      version: entry.version,
                                      sha256: entry.sha256,
                                      updatedAt: Date())
            try Self.save(scriptData: scriptData, metadata: cached)
            if id == "node-unlock-detection" { publishCacheState(cached) }
            updateMessage = id == "node-unlock-detection" ? "脚本已更新" : "检测脚本已就绪"
            return metadata(from: cached)
        } catch {
            updateMessage = "更新失败：\(error.localizedDescription)"
            throw error
        }
    }

    /// User-initiated update for the settings screen. Downloads scripts one by
    /// one so a failed update preserves every previously verified cache.
    @discardableResult
    func refreshAllScripts() async throws -> [ExternalDetectionScript] {
        guard !isUpdating else { throw ScriptLoadError.updateInProgress }
        isUpdating = true
        updateMessage = nil
        defer { isUpdating = false }

        do {
            let manifestData = try await Self.download(Self.manifestURL, maxBytes: 256 * 1024)
            let signatureData = try await Self.download(Self.signatureURL, maxBytes: 8 * 1024)
            try Self.verify(manifestData: manifestData, signature: signatureData)
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            guard manifest.apiVersion == 1 else { throw ScriptLoadError.invalidManifest }
            let definitions = Self.definitions(from: manifest)
            guard !definitions.isEmpty else { throw ScriptLoadError.invalidManifest }

            for definition in definitions {
                let scriptData = try await Self.download(definition.scriptURL, maxBytes: 512 * 1024)
                guard Self.sha256(scriptData) == definition.sha256.lowercased() else {
                    throw ScriptLoadError.hashMismatch
                }
                try Self.save(scriptData: scriptData,
                              metadata: CachedScript(id: definition.id,
                                                     name: definition.name,
                                                     icon: definition.icon,
                                                     scriptURL: definition.scriptURL,
                                                     version: definition.version,
                                                     sha256: definition.sha256,
                                                     updatedAt: Date()))
            }

            try Self.saveManifest(manifestData)
            availableScripts = Self.mergedDefinitions(definitions)
            hasManifest = Self.requiredScriptIDs.isSubset(of: Set(definitions.map(\.id)))
            publishCacheState(Self.loadCachedMetadata())
            updateMessage = "检测脚本已更新"
            return definitions
        } catch {
            updateMessage = "更新失败：\(error.localizedDescription)"
            throw error
        }
    }

    func refreshCacheState() {
        publishCacheState(Self.loadCachedMetadata())
    }

    func scriptSource(for id: String = "node-unlock-detection") -> (script: String, metadata: ExternalDetectionScript)? {
        guard let cached = validCachedScript(id: id),
              let source = String(data: cached.data, encoding: .utf8) else { return nil }
        return (source, metadata(from: cached.metadata))
    }

    private func validCachedScript(id: String) -> (metadata: CachedScript, data: Data)? {
        guard let metadata = Self.loadCachedMetadata(id: id),
              let data = Self.loadCachedScript(id: id),
              Self.sha256(data) == metadata.sha256.lowercased() else { return nil }
        return (metadata, data)
    }

    private func metadata(from cached: CachedScript) -> ExternalDetectionScript {
        ExternalDetectionScript(id: cached.id,
                                name: cached.name ?? Self.fallbackScripts.first(where: { $0.id == cached.id })?.name ?? cached.id,
                                version: cached.version,
                                scriptURL: cached.scriptURL ?? Self.fallbackScripts.first(where: { $0.id == cached.id })?.scriptURL ?? Self.manifestURL,
                                sha256: cached.sha256,
                                icon: cached.icon ?? Self.fallbackScripts.first(where: { $0.id == cached.id })?.icon ?? "doc.text")
    }

    private func publishCacheState(_ metadata: CachedScript?) {
        cachedVersion = metadata?.version
        cachedUpdatedAt = metadata?.updatedAt
    }

    private static func download(_ url: URL, maxBytes: Int64) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Cora/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let download = try await BoundedHTTPDownloader.download(for: request,
                                                                  maxBytes: maxBytes,
                                                                  resourceTimeout: 15)
        defer { try? FileManager.default.removeItem(at: download.fileURL) }
        return try Data(contentsOf: download.fileURL, options: .mappedIfSafe)
    }

    private static func verify(manifestData: Data, signature: Data) throws {
        guard let publicData = Data(base64Encoded: trustedPublicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicData),
              let signatureText = String(data: signature, encoding: .utf8),
              let signatureBytes = Data(base64Encoded: signatureText.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.isValidSignature(signatureBytes, for: manifestData) else {
            throw ScriptLoadError.signatureMismatch
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadCachedScript(id: String) -> Data? {
        try? Data(contentsOf: cacheDirectory.appendingPathComponent(fileName(id: id, suffix: "js")))
    }

    private static func loadCachedMetadata(id: String) -> CachedScript? {
        guard let data = try? Data(contentsOf: cacheDirectory.appendingPathComponent(fileName(id: id, suffix: "json"))) else { return nil }
        return try? JSONDecoder().decode(CachedScript.self, from: data)
    }

    private static func loadCachedMetadata() -> CachedScript? {
        loadCachedMetadata(id: "node-unlock-detection")
    }

    private static func save(scriptData: Data, metadata: CachedScript) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try scriptData.write(to: cacheDirectory.appendingPathComponent(fileName(id: metadata.id, suffix: "js")), options: .atomic)
        try JSONEncoder().encode(metadata).write(to: cacheDirectory.appendingPathComponent(fileName(id: metadata.id, suffix: "json")), options: .atomic)
    }

    private static func fileName(id: String, suffix: String) -> String {
        let safe = id.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        return "\(safe).\(suffix)"
    }

    private static func definitions(from manifest: Manifest) -> [ExternalDetectionScript] {
        manifest.scripts.compactMap { entry in
            guard entry.requiredCapabilities.contains("node-http"),
                  !entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.sha256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ExternalDetectionScript(id: entry.id,
                                           name: entry.name,
                                           version: entry.version,
                                           scriptURL: entry.scriptURL,
                                           sha256: entry.sha256,
                                           icon: entry.icon ?? fallbackScripts.first(where: { $0.id == entry.id })?.icon ?? "doc.text")
        }
    }

    private static let requiredScriptIDs: Set<String> = [
        "node-unlock-detection",
        "network-entry-exit",
        "ip-quality-detection",
    ]

    private static func mergedDefinitions(_ definitions: [ExternalDetectionScript]) -> [ExternalDetectionScript] {
        definitions + fallbackScripts.filter { fallback in
            !definitions.contains(where: { $0.id == fallback.id })
        }
    }

    private static func saveManifest(_ data: Data) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try data.write(to: cacheDirectory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private static func loadCachedManifest() -> Manifest? {
        guard let data = try? Data(contentsOf: cacheDirectory.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    enum ScriptLoadError: LocalizedError {
        case invalidManifest
        case signatureMismatch
        case hashMismatch
        case updateInProgress

        var errorDescription: String? {
            switch self {
            case .invalidManifest: return "检测脚本清单无效"
            case .signatureMismatch: return "检测脚本清单签名不匹配"
            case .hashMismatch: return "检测脚本摘要不匹配"
            case .updateInProgress: return "检测脚本正在更新"
            }
        }
    }
}

@MainActor
final class UnlockTestController: ObservableObject {
    static let shared = UnlockTestController()

    @Published private(set) var isRunning = false
    @Published private(set) var runningNodeName: String?
    @Published private(set) var runningGroupName: String?
    @Published private(set) var runningScriptName: String?
    @Published var result: UnlockTestResult?
    @Published var error: String?

    private init() {}

    func run(nodeName: String, groupName: String, scriptID: String = "node-unlock-detection") async {
        guard !isRunning else { return }
        let status = CoreStateManager.shared.status
        guard status == .connected || status == .reasserting else {
            error = "连接 VPN 后才能进行检测"
            return
        }
        isRunning = true
        runningNodeName = nodeName
        runningGroupName = groupName
        runningScriptName = ExternalScriptStore.shared.availableScripts.first(where: { $0.id == scriptID })?.name
        result = nil
        error = nil
        defer {
            isRunning = false
            runningNodeName = nil
            runningGroupName = nil
            runningScriptName = nil
        }
        do {
            let store = ExternalScriptStore.shared
            let script = try await store.loadScript(id: scriptID)
            guard let source = store.scriptSource(for: script.id) else {
                throw ExternalScriptStore.ScriptLoadError.invalidManifest
            }
            let runtimeContext: ScriptRuntimeContext
            if script.id == "network-entry-exit" {
                runtimeContext = await ScriptRuntimeContext.load(nodeName: nodeName, groupName: groupName)
            } else {
                runtimeContext = .empty
            }
            let output = try await ScriptExecution(
                source: source.script,
                metadata: source.metadata,
                nodeName: nodeName,
                groupName: groupName,
                runtimeContext: runtimeContext).start()
            result = output
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private final class ScriptExecution: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.cora.external-script", qos: .userInitiated)
    private let source: String
    private let metadata: ExternalDetectionScript
    private let nodeName: String
    private let groupName: String
    private let runtimeContext: ScriptRuntimeContext
    private var context: JSContext?
    private var completed = false
    private var requestCount = 0
    private var timeoutWorkItem: DispatchWorkItem?

    init(source: String,
         metadata: ExternalDetectionScript,
         nodeName: String,
         groupName: String,
         runtimeContext: ScriptRuntimeContext) {
        self.source = source
        self.metadata = metadata
        self.nodeName = nodeName
        self.groupName = groupName
        self.runtimeContext = runtimeContext
    }

    func start() async throws -> UnlockTestResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.evaluate { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    private func evaluate(completion: @escaping (Result<UnlockTestResult, Error>) -> Void) {
        let js = JSContext()!
        context = js
        let fail: (String) -> Void = { [weak self] message in
            self?.queue.async { [weak self] in
                guard let self, !self.completed else { return }
                self.complete(.failure(ScriptExecutionError.runtime(message)),
                              completion: completion)
            }
        }
        js.exceptionHandler = { _, exception in
            if let exception {
                NSLog("Cora script exception: %@", exception.toString())
            }
            fail(exception?.toString() ?? "脚本运行异常")
        }
        var params: [String: Any] = ["node": nodeName]
        if !runtimeContext.nodeInfo.isEmpty {
            params["nodeInfo"] = runtimeContext.nodeInfo
        }
        if !runtimeContext.directNetworkInfo.isEmpty {
            params["directNetworkInfo"] = runtimeContext.directNetworkInfo
        }
        js.setObject(["params": params], forKeyedSubscript: "$environment" as NSString)
        let console = JSValue(newObjectIn: js)
        let log: @convention(block) (JSValue) -> Void = { _ in }
        console?.setObject(log, forKeyedSubscript: "log" as NSString)
        console?.setObject(log, forKeyedSubscript: "info" as NSString)
        console?.setObject(log, forKeyedSubscript: "warn" as NSString)
        console?.setObject(log, forKeyedSubscript: "error" as NSString)
        js.setObject(console, forKeyedSubscript: "console" as NSString)
        let httpClient = JSValue(newObjectIn: js)
        let get: @convention(block) (NSDictionary, JSValue) -> Void = { [weak self] options, callback in
            self?.fetch(method: "GET", options: options, callback: callback)
        }
        let post: @convention(block) (NSDictionary, JSValue) -> Void = { [weak self] options, callback in
            self?.fetch(method: "POST", options: options, callback: callback)
        }
        httpClient?.setObject(get, forKeyedSubscript: "get" as NSString)
        httpClient?.setObject(post, forKeyedSubscript: "post" as NSString)
        js.setObject(httpClient, forKeyedSubscript: "$httpClient" as NSString)
        let done: @convention(block) (JSValue) -> Void = { [weak self] value in
            self?.finish(value: value, completion: completion)
        }
        js.setObject(done, forKeyedSubscript: "$done" as NSString)
        if js.evaluateScript(source) == nil {
            fail("脚本无法执行")
        }
        guard !completed else { return }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.completed else { return }
            self.complete(.failure(ScriptExecutionError.timeout), completion: completion)
        }
        timeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + ExternalScriptLimits.maxExecutionSeconds,
                         execute: timeout)
    }

    private func fetch(method: String, options: NSDictionary, callback: JSValue) {
        guard requestCount < 12 else {
            callback.call(withArguments: ["脚本请求数量超过限制", NSNull(), ""])
            return
        }
        requestCount += 1
        var values: [String: Any] = [:]
        for key in options.allKeys {
            guard let key = key as? String else { continue }
            values[key] = options[key]
        }
        let request: [String: Any] = [
            "name": nodeName,
            "group": groupName,
            "method": method,
            "url": values["url"] as? String ?? "",
            "headers": values["headers"] as? [String: String] ?? [:],
            "body": values["body"] as? String ?? "",
            "timeout": min(max((values["timeout"] as? NSNumber)?.intValue ?? 5_000, 500),
                            ExternalScriptLimits.maxRequestTimeoutMilliseconds),
            "allowRedirect": (values["auto-redirect"] as? NSNumber)?.boolValue ?? true,
        ]
        queue.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let result = await CoreStateManager.shared.sendMessage(["cmd": "scriptFetch", "request": request])
                self.queue.async {
                    guard !self.completed else { return }
                    switch result {
                    case .failure(let reason):
                        callback.call(withArguments: [reason, NSNull(), ""])
                    case .ok(let data):
                        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                        if let error = object["error"] as? String {
                            callback.call(withArguments: [error, NSNull(), ""])
                        } else {
                            let status = object["status"] as? Int ?? 0
                            let response: NSDictionary = [
                                "status": status,
                                "statusCode": status,
                                "headers": object["headers"] as? [String: String] ?? [:],
                            ]
                            callback.call(withArguments: [NSNull(), response, object["body"] as? String ?? ""])
                        }
                    }
                }
            }
        }
    }

    private func finish(value: JSValue, completion: @escaping (Result<UnlockTestResult, Error>) -> Void) {
        guard !completed else { return }
        let object = value.toDictionary() as? [String: Any] ?? [:]
        let title = object["title"] as? String ?? "节点解锁检测"
        let html = object["htmlMessage"] as? String ?? object["message"] as? String ?? "脚本没有返回检测结果"
        let result = UnlockTestResult(nodeName: nodeName,
                                      groupName: groupName,
                                      scriptID: metadata.id,
                                      scriptName: metadata.name,
                                      scriptIcon: metadata.icon,
                                      scriptVersion: metadata.version,
                                      title: title,
                                      message: Self.plainText(html))
        complete(.success(result), completion: completion)
    }

    private func complete(_ result: Result<UnlockTestResult, Error>,
                          completion: @escaping (Result<UnlockTestResult, Error>) -> Void) {
        guard !completed else { return }
        completed = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        context = nil
        completion(result)
    }

    private static func plainText(_ html: String) -> String {
        let text = html.replacingOccurrences(of: #"(?i)</?br\s*/?>"#,
                                             with: "\n",
                                             options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")

        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

private enum ScriptExecutionError: LocalizedError {
    case timeout
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "解锁检测超时（脚本总时限 45 秒）"
        case .runtime(let message): return "脚本运行失败：\(message)"
        }
    }
}
