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

    /// GET /connections —— 取累计上下行字节（普通 GET 快照，可轮询算速率，比 WS 稳）。
    static func connectionsTotals() async throws -> (down: Int64, up: Int64) {
        let (data, resp) = try await session.data(from: base.appendingPathComponent("connections"))
        try check(resp)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let down = (obj?["downloadTotal"] as? NSNumber)?.int64Value ?? 0
        let up = (obj?["uploadTotal"] as? NSNumber)?.int64Value ?? 0
        return (down, up)
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

    /// GET /group/{name}/delay —— 测试策略组内所有节点延迟，返回 node→毫秒（不通的节点不在 map 里）。
    static func groupDelay(group: String,
                           testURL: String = "http://www.gstatic.com/generate_204",
                           timeout: Int = 5000) async throws -> [String: Int] {
        let url = base.appendingPathComponent("group").appendingPathComponent(group).appendingPathComponent("delay")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "url", value: testURL),
            URLQueryItem(name: "timeout", value: String(timeout)),
        ]
        // 测速可能数秒，用更宽松的超时
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = TimeInterval(timeout) / 1000 + 5
        let (data, resp) = try await streamSession.data(for: req)
        try check(resp)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var result: [String: Int] = [:]
        for (k, v) in obj {
            if let n = (v as? NSNumber)?.intValue { result[k] = n }
        }
        return result
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
