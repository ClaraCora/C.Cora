import Combine
import CryptoKit
import Foundation
@preconcurrency import JavaScriptCore

struct ExternalDetectionScript: Codable, Sendable {
    let id: String
    let name: String
    let version: String
    let scriptURL: URL
    let sha256: String
}

struct UnlockTestResult: Identifiable, Sendable {
    let id = UUID()
    let nodeName: String
    let groupName: String
    let scriptVersion: String
    let title: String
    let message: String
}

enum ExternalScriptLimits {
    static let maxRequestTimeoutMilliseconds = 15_000
    static let maxExecutionSeconds: TimeInterval = 45
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
    }

    private struct CachedScript: Codable {
        let id: String
        let version: String
        let sha256: String
        let updatedAt: Date?
    }

    @Published private(set) var cachedVersion: String?
    @Published private(set) var cachedUpdatedAt: Date?
    @Published private(set) var isUpdating = false
    @Published private(set) var updateMessage: String?

    private init() {
        refreshCacheState()
    }

    func loadUnlockScript() async throws -> ExternalDetectionScript {
        if let cached = validCachedScript() {
            publishCacheState(cached.metadata)
            return metadata(from: cached.metadata)
        }
        return try await refreshUnlockScript()
    }

    /// 设置页调用的显式更新。签名或下载失败时保留旧缓存。
    func refreshUnlockScript() async throws -> ExternalDetectionScript {
        if isUpdating {
            if let cached = validCachedScript() {
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
                  let entry = manifest.scripts.first(where: { $0.id == "node-unlock-detection" }),
                  entry.requiredCapabilities.contains("node-http") else {
                throw ScriptLoadError.invalidManifest
            }
            let scriptData = try await Self.download(entry.scriptURL, maxBytes: 512 * 1024)
            guard Self.sha256(scriptData) == entry.sha256.lowercased() else {
                throw ScriptLoadError.hashMismatch
            }
            let cached = CachedScript(id: entry.id,
                                      version: entry.version,
                                      sha256: entry.sha256,
                                      updatedAt: Date())
            try Self.save(scriptData: scriptData, metadata: cached)
            publishCacheState(cached)
            updateMessage = "脚本已更新"
            return ExternalDetectionScript(id: entry.id, name: entry.name,
                                           version: entry.version, scriptURL: entry.scriptURL,
                                           sha256: entry.sha256)
        } catch {
            updateMessage = "更新失败：\(error.localizedDescription)"
            throw error
        }
    }

    func refreshCacheState() {
        publishCacheState(Self.loadCachedMetadata())
    }

    func scriptSource() -> (script: String, metadata: ExternalDetectionScript)? {
        guard let cached = validCachedScript(),
              let source = String(data: cached.data, encoding: .utf8) else { return nil }
        return (source, metadata(from: cached.metadata))
    }

    private func validCachedScript() -> (metadata: CachedScript, data: Data)? {
        guard let metadata = Self.loadCachedMetadata(),
              let data = Self.loadCachedScript(),
              Self.sha256(data) == metadata.sha256.lowercased() else { return nil }
        return (metadata, data)
    }

    private func metadata(from cached: CachedScript) -> ExternalDetectionScript {
        ExternalDetectionScript(id: cached.id,
                                name: "节点解锁检测",
                                version: cached.version,
                                scriptURL: Self.manifestURL,
                                sha256: cached.sha256)
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

    private static func loadCachedScript() -> Data? {
        try? Data(contentsOf: cacheDirectory.appendingPathComponent("node-unlock-detection.js"))
    }

    private static func loadCachedMetadata() -> CachedScript? {
        guard let data = try? Data(contentsOf: cacheDirectory.appendingPathComponent("node-unlock-detection.json")) else { return nil }
        return try? JSONDecoder().decode(CachedScript.self, from: data)
    }

    private static func save(scriptData: Data, metadata: CachedScript) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try scriptData.write(to: cacheDirectory.appendingPathComponent("node-unlock-detection.js"), options: .atomic)
        try JSONEncoder().encode(metadata).write(to: cacheDirectory.appendingPathComponent("node-unlock-detection.json"), options: .atomic)
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
    @Published var result: UnlockTestResult?
    @Published var error: String?

    private init() {}

    func run(nodeName: String, groupName: String) async {
        guard !isRunning else { return }
        let status = CoreStateManager.shared.status
        guard status == .connected || status == .reasserting else {
            error = "连接 VPN 后才能进行解锁测试"
            return
        }
        isRunning = true
        runningNodeName = nodeName
        runningGroupName = groupName
        result = nil
        error = nil
        defer {
            isRunning = false
            runningNodeName = nil
            runningGroupName = nil
        }
        do {
            let store = ExternalScriptStore.shared
            _ = try await store.loadUnlockScript()
            guard let source = store.scriptSource() else {
                throw ExternalScriptStore.ScriptLoadError.invalidManifest
            }
            let output = try await ScriptExecution(
                source: source.script,
                metadata: source.metadata,
                nodeName: nodeName,
                groupName: groupName).start()
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
    private var context: JSContext?
    private var completed = false
    private var requestCount = 0

    init(source: String, metadata: ExternalDetectionScript, nodeName: String, groupName: String) {
        self.source = source
        self.metadata = metadata
        self.nodeName = nodeName
        self.groupName = groupName
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
                self.completed = true
                completion(.failure(ScriptExecutionError.runtime(message)))
            }
        }
        js.exceptionHandler = { _, exception in
            if let exception {
                NSLog("Cora script exception: %@", exception.toString())
            }
            fail(exception?.toString() ?? "脚本运行异常")
        }
        js.setObject(["params": ["node": nodeName]], forKeyedSubscript: "$environment" as NSString)
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
        queue.asyncAfter(deadline: .now() + ExternalScriptLimits.maxExecutionSeconds) { [self] in
            guard !self.completed else { return }
            self.completed = true
            completion(.failure(ScriptExecutionError.timeout))
        }
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
        completed = true
        let object = value.toDictionary() as? [String: Any] ?? [:]
        let title = object["title"] as? String ?? "节点解锁检测"
        let html = object["htmlMessage"] as? String ?? object["message"] as? String ?? "脚本没有返回检测结果"
        completion(.success(UnlockTestResult(nodeName: nodeName,
                                              groupName: groupName,
                                              scriptVersion: metadata.version,
                                              title: title,
                                              message: Self.plainText(html))))
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
