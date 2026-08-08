import Foundation

/// 用户显式启用 external-controller 后使用的只读诊断客户端。
///
/// 127.0.0.1 是 loopback，不经 tun、跨进程可达；IP 字面量 ATS 不拦明文 HTTP。
/// App 的代理、连接、日志和模式控制全部走 NE IPC，不依赖这个客户端。
enum MihomoAPI {

    struct Configuration: Sendable {
        let port: Int
        let secret: String
    }

    private static let configurationLock = NSLock()
    private static var activeConfiguration = Configuration(port: 9090, secret: "")

    static func configure(port: Int, secret: String) {
        configurationLock.lock()
        activeConfiguration = Configuration(port: normalizedPort(port), secret: secret)
        configurationLock.unlock()
    }

    static func configuration() -> Configuration {
        configurationLock.lock()
        let value = activeConfiguration
        configurationLock.unlock()
        return value
    }

    static var base: URL {
        baseURL(port: configuration().port)
    }

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

    /// 构建带鉴权头的请求。path 形如 "proxies/我的组"——URLComponents 会正确百分号编码
    /// 路径里的中文/空格（保留 "/" 作分隔），避免 appendingPathComponent 误编码。
    static func makeRequest(path: String, method: String = "GET",
                            query: [URLQueryItem] = []) -> URLRequest {
        let active = configuration()
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = active.port
        comps.path = "/" + path
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url ?? baseURL(port: active.port))
        req.httpMethod = method
        if !active.secret.isEmpty {
            req.setValue("Bearer \(active.secret)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private static func normalizedPort(_ port: Int) -> Int {
        (1...65_535).contains(port) ? port : 9090
    }

    private static func baseURL(port: Int) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = normalizedPort(port)
        return components.url ?? URL(string: "http://127.0.0.1:9090")!
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
