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
    /// 启用 geo 规则（默认关=剔除 GEOIP/GEOSITE 防 NE OOM）。开启则保留规则并按下列 geo 设置加载。
    @Published var geoEnabled: Bool { didSet { d.set(geoEnabled, forKey: K.geoEnabled) } }
    /// geo 加载器：standard / memconservative（小内存优化，NE 推荐）。
    @Published var geoLoader: String { didSet { d.set(geoLoader, forKey: K.geoLoader) } }
    /// 自动更新 geo 数据库。
    @Published var geoAutoUpdate: Bool { didSet { d.set(geoAutoUpdate, forKey: K.geoAuto) } }
    /// 自动更新间隔（小时）。
    @Published var geoUpdateInterval: Int { didSet { d.set(geoUpdateInterval, forKey: K.geoInterval) } }
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
    /// 混合代理端口（HTTP+SOCKS，本机回环）。0=不开。下发给内核 mixed-port。
    @Published var mixedPort: Int { didSet { d.set(mixedPort, forKey: K.mixedPort) } }

    // 以下 5 项是 NETunnelProviderProtocol(NEVPNProtocol) 开关，连接时由主 App 设到隧道协议上，
    // 不经内核（与 mihomo 配置无关）。
    /// 接管所有网络（含系统默认会排除的流量）。
    @Published var includeAllNetworks: Bool { didSet { d.set(includeAllNetworks, forKey: K.inclAll) } }
    /// 排除蜂窝服务（VoLTE 等），默认 true（Apple 建议）。
    @Published var excludeCellularServices: Bool { didSet { d.set(excludeCellularServices, forKey: K.exCell) } }
    /// 排除 APNs（推送），默认 true。
    @Published var excludeAPNs: Bool { didSet { d.set(excludeAPNs, forKey: K.exAPNs) } }
    /// 排除设备间通信（隔空投送/接力等），默认 true。
    @Published var excludeDeviceCommunication: Bool { didSet { d.set(excludeDeviceCommunication, forKey: K.exDev) } }
    /// 强制路由（即使 includeAllNetworks 关，也强制按规则路由）。
    @Published var enforceRoutes: Bool { didSet { d.set(enforceRoutes, forKey: K.enforce) } }

    static let stackOptions = ["gvisor", "system", "mixed"]
    static let logLevelOptions = ["silent", "error", "warning", "info", "debug"]
    static let geoLoaderOptions = ["memconservative", "standard"]

    private let d = UserDefaults.standard
    private enum K {
        static let stack = "set.stack", ipv6 = "set.ipv6"
        static let geoEnabled = "set.geoEnabled", geoLoader = "set.geoLoader"
        static let geoAuto = "set.geoAuto", geoInterval = "set.geoInterval"
        static let logLevel = "set.logLevel", port = "set.port", secret = "set.secret", allowLan = "set.allowLan"
        static let mixedPort = "set.mixedPort"
        static let inclAll = "set.inclAll", exCell = "set.exCell", exAPNs = "set.exAPNs"
        static let exDev = "set.exDev", enforce = "set.enforce"
    }

    private init() {
        stack = d.string(forKey: K.stack) ?? "gvisor"
        ipv6 = d.object(forKey: K.ipv6) as? Bool ?? false
        geoEnabled = d.object(forKey: K.geoEnabled) as? Bool ?? false
        geoLoader = d.string(forKey: K.geoLoader) ?? "memconservative"
        geoAutoUpdate = d.object(forKey: K.geoAuto) as? Bool ?? false
        let gi = d.integer(forKey: K.geoInterval)
        geoUpdateInterval = gi == 0 ? 24 : gi
        logLevel = d.string(forKey: K.logLevel) ?? "info"
        let p = d.integer(forKey: K.port)
        controllerPort = p == 0 ? 9090 : p
        controllerSecret = d.string(forKey: K.secret) ?? ""
        allowLan = d.object(forKey: K.allowLan) as? Bool ?? false
        mixedPort = d.integer(forKey: K.mixedPort) // 默认 0 = 不开
        includeAllNetworks = d.object(forKey: K.inclAll) as? Bool ?? false
        excludeCellularServices = d.object(forKey: K.exCell) as? Bool ?? true
        excludeAPNs = d.object(forKey: K.exAPNs) as? Bool ?? true
        excludeDeviceCommunication = d.object(forKey: K.exDev) as? Bool ?? true
        enforceRoutes = d.object(forKey: K.enforce) as? Bool ?? false

        // 同步给 HTTP 客户端
        MihomoAPI.port = controllerPort
        MihomoAPI.secret = controllerSecret
    }

    /// 序列化为下发给 NE 的 JSON。
    func asJSON() -> String {
        let dict: [String: Any] = [
            "stack": stack,
            "ipv6": ipv6,
            "geoEnabled": geoEnabled,
            "geoLoader": geoLoader,
            "geoAutoUpdate": geoAutoUpdate,
            "geoUpdateInterval": geoUpdateInterval,
            "logLevel": logLevel,
            "controllerPort": controllerPort,
            "controllerSecret": controllerSecret,
            "allowLan": allowLan,
            "mixedPort": mixedPort,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}
