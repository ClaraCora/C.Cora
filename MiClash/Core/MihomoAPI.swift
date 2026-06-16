import Foundation

/// 主 App 访问 NE 内 mihomo external-controller 的 HTTP 客户端。
///
/// 背景：sendProviderMessage IPC 在用户的重签环境下不投递，改走本地回环 HTTP。
/// 127.0.0.1 是 loopback，不经 tun、跨进程可达；且是 IP 字面量，ATS 不拦截明文 HTTP，
/// 无需 Info.plist 例外。地址与 Go 侧 ControllerAddr 一致（127.0.0.1:9090）。
enum MihomoAPI {

    static let base = URL(string: "http://127.0.0.1:9090")!

    enum APIError: LocalizedError {
        case badStatus(Int)
        case badResponse
        var errorDescription: String? {
            switch self {
            case .badStatus(let c): return "内核返回 HTTP \(c)"
            case .badResponse: return "内核响应无法解析"
            }
        }
    }

    /// 普通请求用的短超时 session。
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// 流式请求（/traffic、/logs）用的长超时 session——每秒有数据，不应超时。
    private static let streamSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3600
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    // MARK: - 一次性请求

    /// GET /version —— 连通性探测。
    static func version() async throws -> String {
        let (data, resp) = try await session.data(from: base.appendingPathComponent("version"))
        try check(resp)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["version"] as? String) ?? String(data: data, encoding: .utf8) ?? "?"
    }

    /// GET /proxies —— 完整 proxies JSON（HTTP 无 IPC 体积限制）。
    static func proxiesJSON() async throws -> [String: Any] {
        let (data, resp) = try await session.data(from: base.appendingPathComponent("proxies"))
        try check(resp)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badResponse
        }
        return obj
    }

    /// PUT /proxies/{group} body {"name": node} —— 在策略组里选定节点。
    static func select(group: String, node: String) async throws {
        var req = URLRequest(url: base.appendingPathComponent("proxies").appendingPathComponent(group))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": node])
        let (_, resp) = try await session.data(for: req)
        try check(resp)  // 成功为 204 No Content
    }

    /// GET /configs —— 取当前模式（rule/global/direct）。
    static func currentMode() async throws -> String {
        let (data, resp) = try await session.data(from: base.appendingPathComponent("configs"))
        try check(resp)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["mode"] as? String) ?? "rule"
    }

    /// PATCH /configs body {"mode": ...} —— 切换模式。
    static func setMode(_ mode: String) async throws {
        var req = URLRequest(url: base.appendingPathComponent("configs"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["mode": mode])
        let (_, resp) = try await session.data(for: req)
        try check(resp)
    }

    // MARK: - 流式请求

    /// 打开一个 chunked 流（/traffic、/logs），按行返回 JSON。
    /// 调用方在 for-await 里逐行解析；取消所在 Task 即断流。
    static func lineStream(path: String) async throws -> AsyncThrowingStream<[String: Any], Error> {
        let req = URLRequest(url: base.appendingPathComponent(path))
        let (bytes, resp) = try await streamSession.bytes(for: req)
        try check(resp)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard let d = line.data(using: .utf8),
                              let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any]
                        else { continue }
                        continuation.yield(obj)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func check(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.badStatus(http.statusCode) }
    }
}

/// 字节数/速率的人类可读格式化。
enum ByteFormat {
    static func size(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(bytes); var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(Int(v)) \(units[i])" : String(format: "%.2f %@", v, units[i])
    }
    static func rate(_ bytesPerSec: Int64) -> String { size(bytesPerSec) + "/s" }
}
