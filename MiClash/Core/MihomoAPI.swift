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

    private static var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// GET /version —— 连通性探测，返回版本串。
    static func version() async throws -> String {
        let (data, resp) = try await session.data(from: base.appendingPathComponent("version"))
        try check(resp)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["version"] as? String) ?? String(data: data, encoding: .utf8) ?? "?"
    }

    /// GET /proxies —— 返回完整 proxies JSON（HTTP 无 IPC 体积限制）。
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

    private static func check(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.badStatus(http.statusCode) }
    }
}
