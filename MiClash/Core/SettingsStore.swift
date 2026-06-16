import Foundation

/// 内核相关设置（持久化到 UserDefaults）。
///
/// 这些影响 NE 内 mihomo 的启动配置：连接时序列化为 JSON 经 startVPNTunnel(options) 下发，
/// Go 侧 StartWithConfig 据此覆盖 tun.stack / ipv6 / geo / log-level / external-controller。
/// 因此**修改后需重新连接才生效**。其中外部控制端口/密钥同时被主 App 的 HTTP 客户端读取。
@MainActor
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    /// TCP/IP 栈：gvisor / system / mixed。iOS NE 强烈建议 gvisor（system 栈 TCP 常走不通）。
    @Published var stack: String { didSet { d.set(stack, forKey: K.stack) } }
    @Published var ipv6: Bool { didSet { d.set(ipv6, forKey: K.ipv6) } }
    /// 剔除订阅里的 GEOIP/GEOSITE 规则（默认开，防 NE OOM）。关掉则保留（需 geo 库，自担风险）。
    @Published var stripGeo: Bool { didSet { d.set(stripGeo, forKey: K.stripGeo) } }
    /// 日志等级：silent / error / warning / info / debug。
    @Published var logLevel: String { didSet { d.set(logLevel, forKey: K.logLevel) } }
    /// external-controller 端口（主 App HTTP 客户端也用它）。
    @Published var controllerPort: Int {
        didSet { d.set(controllerPort, forKey: K.port); MihomoAPI.port = controllerPort }
    }
    /// external-controller 密钥（空=无鉴权）。
    @Published var controllerSecret: String {
        didSet { d.set(controllerSecret, forKey: K.secret); MihomoAPI.secret = controllerSecret }
    }
    /// 允许局域网访问控制接口（绑 0.0.0.0 而非仅 127.0.0.1）。
    @Published var allowLan: Bool { didSet { d.set(allowLan, forKey: K.allowLan) } }

    static let stackOptions = ["gvisor", "system", "mixed"]
    static let logLevelOptions = ["silent", "error", "warning", "info", "debug"]

    private let d = UserDefaults.standard
    private enum K {
        static let stack = "set.stack", ipv6 = "set.ipv6", stripGeo = "set.stripGeo"
        static let logLevel = "set.logLevel", port = "set.port", secret = "set.secret", allowLan = "set.allowLan"
    }

    private init() {
        stack = d.string(forKey: K.stack) ?? "gvisor"
        ipv6 = d.object(forKey: K.ipv6) as? Bool ?? false
        stripGeo = d.object(forKey: K.stripGeo) as? Bool ?? true
        logLevel = d.string(forKey: K.logLevel) ?? "info"
        let p = d.integer(forKey: K.port)
        controllerPort = p == 0 ? 9090 : p
        controllerSecret = d.string(forKey: K.secret) ?? ""
        allowLan = d.object(forKey: K.allowLan) as? Bool ?? false

        // 同步给 HTTP 客户端
        MihomoAPI.port = controllerPort
        MihomoAPI.secret = controllerSecret
    }

    /// 序列化为下发给 NE 的 JSON。
    func asJSON() -> String {
        let dict: [String: Any] = [
            "stack": stack,
            "ipv6": ipv6,
            "stripGeo": stripGeo,
            "logLevel": logLevel,
            "controllerPort": controllerPort,
            "controllerSecret": controllerSecret,
            "allowLan": allowLan,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}
