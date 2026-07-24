import Foundation

/// 主 App 访问 NE 内 mihomo external-controller 的 HTTP 客户端。
///
/// 127.0.0.1 是 loopback，不经 tun、跨进程可达；IP 字面量 ATS 不拦明文 HTTP。
/// 端口/密钥由 SettingsStore 同步到这里的 `port`/`secret`（这里用普通静态量，
/// 以便后台的 MihomoStream 也能无隔离地读取）。
enum MihomoAPI {

    /// 由 SettingsStore 同步。默认 127.0.0.1:9090、无密钥。
    static var port: Int = 9090
    static var secret: String = ""

    static var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

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

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private static let streamSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// 构建带鉴权头的请求。path 形如 "proxies/我的组"——URLComponents 会正确百分号编码
    /// 路径里的中文/空格（保留 "/" 作分隔），避免 appendingPathComponent 误编码。
    static func makeRequest(path: String, method: String = "GET",
                            query: [URLQueryItem] = []) -> URLRequest {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = port
        comps.path = "/" + path
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if !secret.isEmpty { req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        return req
    }

    // MARK: - 一次性请求

    static func version() async throws -> String {
        let (data, resp) = try await session.data(for: makeRequest(path: "version"))
        try check(resp)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["version"] as? String) ?? String(data: data, encoding: .utf8) ?? "?"
    }

    static func proxiesJSON() async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: makeRequest(path: "proxies"))
        try check(resp)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badResponse
        }
        return obj
    }

    static func select(group: String, node: String) async throws {
        var req = makeRequest(path: "proxies/\(group)", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": node])
        let (_, resp) = try await session.data(for: req)
        try check(resp)
    }

    static func connectionsTotals() async throws -> (down: Int64, up: Int64) {
        let (data, resp) = try await session.data(for: makeRequest(path: "connections"))
        try check(resp)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let down = (obj?["downloadTotal"] as? NSNumber)?.int64Value ?? 0
        let up = (obj?["uploadTotal"] as? NSNumber)?.int64Value ?? 0
        return (down, up)
    }

    /// 当前活动连接快照。非 actor 隔离的 API 方法不会占用主线程执行解码。
    static func connectionsSnapshot() async throws -> ConnectionsSnapshot {
        let (data, resp) = try await session.data(for: makeRequest(path: "connections"))
        try check(resp)
        return try JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
    }

    static func closeConnection(id: String) async throws {
        let (_, resp) = try await session.data(
            for: makeRequest(path: "connections/\(id)", method: "DELETE"))
        try check(resp)
    }

    static func closeAllConnections() async throws {
        let (_, resp) = try await session.data(
            for: makeRequest(path: "connections", method: "DELETE"))
        try check(resp)
    }

    static func currentMode() async throws -> String {
        let (data, resp) = try await session.data(for: makeRequest(path: "configs"))
        try check(resp)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["mode"] as? String) ?? "rule"
    }

    static func setMode(_ mode: String) async throws {
        var req = makeRequest(path: "configs", method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["mode": mode])
        let (_, resp) = try await session.data(for: req)
        try check(resp)
    }

    /// GET /group/{name}/delay —— 测全组节点延迟，返回 node→毫秒。
    static func groupDelay(group: String,
                           testURL: String = "http://www.gstatic.com/generate_204",
                           timeout: Int = 5000) async throws -> [String: Int] {
        var req = makeRequest(path: "group/\(group)/delay", query: [
            URLQueryItem(name: "url", value: testURL),
            URLQueryItem(name: "timeout", value: String(timeout)),
        ])
        req.timeoutInterval = TimeInterval(timeout) / 1000 + 5
        let (data, resp) = try await streamSession.data(for: req)
        try check(resp)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var result: [String: Int] = [:]
        for (k, v) in obj where (v as? NSNumber) != nil {
            result[k] = (v as! NSNumber).intValue
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
