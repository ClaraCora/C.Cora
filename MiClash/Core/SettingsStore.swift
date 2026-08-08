import Foundation

/// 内核相关设置（持久化到 UserDefaults）。
///
/// 这些影响 NE 内 mihomo 的启动配置：连接时序列化为 JSON 经 startVPNTunnel(options) 下发，
/// Go 侧 StartWithConfig 据此覆盖 tun.stack / ipv6 / geo / log-level / external-controller。
/// 因此**修改后需重新连接才生效**。
@MainActor
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    /// TCP/IP 栈：gvisor / system / mixed。iOS NE 强烈建议 gvisor（system 栈 TCP 常走不通）。
    @Published var stack: String { didSet { d.set(stack, forKey: K.stack) } }
    @Published var ipv6: Bool { didSet { d.set(ipv6, forKey: K.ipv6) } }
    /// 启用 geo 规则（默认开启）。关闭时剔除 GEOIP/GEOSITE/IP-ASN 规则。
    @Published var geoEnabled: Bool { didSet { d.set(geoEnabled, forKey: K.geoEnabled) } }
    /// geo 加载器：standard / memconservative（小内存优化，NE 推荐）。
    @Published var geoLoader: String { didSet { d.set(geoLoader, forKey: K.geoLoader) } }
    /// true 使用 GeoIP.dat；false 使用 MMDB（geoip.metadb）。
    @Published var geodataMode: Bool { didSet { d.set(geodataMode, forKey: K.geodataMode) } }
    @Published var geoIPDatURL: String { didSet { d.set(geoIPDatURL, forKey: K.geoIPDatURL) } }
    @Published var geoMMDBURL: String { didSet { d.set(geoMMDBURL, forKey: K.geoMMDBURL) } }
    @Published var geoSiteURL: String { didSet { d.set(geoSiteURL, forKey: K.geoSiteURL) } }
    /// 是否忽略 geolocation-!cn / NOT(GEOIP) 等 geo 取反规则。
    @Published var ignoreGeoNegation: Bool {
        didSet { d.set(ignoreGeoNegation, forKey: K.ignoreGeoNegation) }
    }
    /// 由主 App 自动更新 geo 数据库。
    @Published var geoAutoUpdate: Bool { didSet { d.set(geoAutoUpdate, forKey: K.geoAuto) } }
    /// 自动更新间隔（小时）。
    @Published var geoUpdateInterval: Int { didSet { d.set(geoUpdateInterval, forKey: K.geoInterval) } }
    /// 日志等级：silent / error / warning / info / debug。
    @Published var logLevel: String { didSet { d.set(logLevel, forKey: K.logLevel) } }
    /// 是否为第三方 Dashboard/局域网客户端启动 mihomo external-controller。
    @Published var externalControllerEnabled: Bool {
        didSet {
            d.set(externalControllerEnabled, forKey: K.externalController)
            if !externalControllerEnabled && allowLan { allowLan = false }
        }
    }
    /// external-controller 端口。
    @Published var controllerPort: Int {
        didSet {
            let normalized = Self.normalizedControllerPort(controllerPort)
            if controllerPort != normalized {
                controllerPort = normalized
                d.set(normalized, forKey: K.port)
                return
            }
            d.set(controllerPort, forKey: K.port)
            if mixedPort == controllerPort { mixedPort = 0 }
        }
    }
    /// external-controller 密钥（空=无鉴权）。
    @Published var controllerSecret: String {
        didSet {
            d.set(controllerSecret, forKey: K.secret)
            if controllerSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               allowLan {
                allowLan = false
            }
        }
    }
    /// 允许局域网访问控制接口（绑 0.0.0.0 而非仅 127.0.0.1）。
    @Published var allowLan: Bool {
        didSet {
            if allowLan && controllerSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                allowLan = false
                d.set(false, forKey: K.allowLan)
                return
            }
            d.set(allowLan, forKey: K.allowLan)
        }
    }
    /// 混合代理端口（HTTP+SOCKS，本机回环）。0=不开。下发给内核 mixed-port。
    @Published var mixedPort: Int {
        didSet {
            let normalized = min(max(mixedPort, 0), 65_535)
            let effective = normalized == controllerPort ? 0 : normalized
            if mixedPort != effective {
                mixedPort = effective
                d.set(effective, forKey: K.mixedPort)
                return
            }
            d.set(mixedPort, forKey: K.mixedPort)
        }
    }
    /// 拉取订阅时用的 User-Agent（机场常按 UA 返回不同格式）。默认 clash-meta。
    /// 仅主 App 下载订阅用，不经内核。
    @Published var subscriptionUA: String { didSet { d.set(subscriptionUA, forKey: K.subUA) } }

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
    static let defaultGeoIPDatURL =
        "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
    static let defaultGeoMMDBURL =
        "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"
    static let defaultGeoSiteURL =
        "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
    static let defaultASNURL =
        "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb"

    private let d = UserDefaults.standard
    private enum K {
        static let stack = "set.stack", ipv6 = "set.ipv6"
        static let geoEnabled = "set.geoEnabled", geoLoader = "set.geoLoader"
        static let geodataMode = "set.geodataMode"
        static let geoIPDatURL = "set.geoIPDatURL", geoMMDBURL = "set.geoMMDBURL"
        static let geoSiteURL = "set.geoSiteURL"
        static let ignoreGeoNegation = "set.ignoreGeoNegation"
        static let geoAuto = "set.geoAuto", geoInterval = "set.geoInterval"
        static let logLevel = "set.logLevel", externalController = "set.externalController"
        static let port = "set.port", secret = "set.secret", allowLan = "set.allowLan"
        static let mixedPort = "set.mixedPort"
        static let inclAll = "set.inclAll", exCell = "set.exCell", exAPNs = "set.exAPNs"
        static let exDev = "set.exDev", enforce = "set.enforce"
        static let subUA = "set.subUA"
    }

    private init() {
        stack = d.string(forKey: K.stack) ?? "gvisor"
        ipv6 = d.object(forKey: K.ipv6) as? Bool ?? false
        geoEnabled = d.object(forKey: K.geoEnabled) as? Bool ?? true
        geoLoader = d.string(forKey: K.geoLoader) ?? "memconservative"
        geodataMode = d.object(forKey: K.geodataMode) as? Bool ?? true
        geoIPDatURL = d.string(forKey: K.geoIPDatURL) ?? Self.defaultGeoIPDatURL
        geoMMDBURL = d.string(forKey: K.geoMMDBURL) ?? Self.defaultGeoMMDBURL
        geoSiteURL = d.string(forKey: K.geoSiteURL) ?? Self.defaultGeoSiteURL
        ignoreGeoNegation = d.object(forKey: K.ignoreGeoNegation) as? Bool ?? false
        geoAutoUpdate = d.object(forKey: K.geoAuto) as? Bool ?? false
        let gi = d.integer(forKey: K.geoInterval)
        geoUpdateInterval = gi == 0 ? 24 : gi
        logLevel = d.string(forKey: K.logLevel) ?? "info"
        let storedControllerPort = Self.normalizedControllerPort(d.integer(forKey: K.port))
        let storedControllerSecret = d.string(forKey: K.secret) ?? ""
        let storedAllowLan = d.object(forKey: K.allowLan) as? Bool ?? false
        externalControllerEnabled = d.object(forKey: K.externalController) as? Bool
            ?? storedAllowLan
        controllerPort = storedControllerPort
        controllerSecret = storedControllerSecret
        allowLan = storedAllowLan && externalControllerEnabled
            && !storedControllerSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let storedMixedPort = min(max(d.integer(forKey: K.mixedPort), 0), 65_535)
        mixedPort = storedMixedPort == storedControllerPort ? 0 : storedMixedPort
        includeAllNetworks = d.object(forKey: K.inclAll) as? Bool ?? false
        excludeCellularServices = d.object(forKey: K.exCell) as? Bool ?? true
        excludeAPNs = d.object(forKey: K.exAPNs) as? Bool ?? true
        excludeDeviceCommunication = d.object(forKey: K.exDev) as? Bool ?? true
        enforceRoutes = d.object(forKey: K.enforce) as? Bool ?? false
        subscriptionUA = d.string(forKey: K.subUA) ?? "clash-meta"

        if externalControllerEnabled {
            MihomoAPI.configure(port: controllerPort, secret: controllerSecret)
        }
    }

    /// 序列化为下发给 NE 的 JSON。
    func asJSON(geoAvailable: Bool = true, applyOverrides: Bool = true) -> String {
        let dict: [String: Any] = [
            "stack": stack,
            "ipv6": ipv6,
            "geoEnabled": geoEnabled && geoAvailable,
            "geoLoader": geoLoader,
            "geodataMode": geodataMode,
            "geoIPDatURL": geoIPDatURL,
            "geoMMDBURL": geoMMDBURL,
            "geoSiteURL": geoSiteURL,
            "ignoreGeoNegation": ignoreGeoNegation,
            "geoAutoUpdate": geoAutoUpdate,
            "geoUpdateInterval": geoUpdateInterval,
            "logLevel": logLevel,
            "externalController": externalControllerEnabled,
            "controllerPort": controllerPort,
            "controllerSecret": controllerSecret,
            "allowLan": allowLan,
            "mixedPort": mixedPort,
            "applyOverrides": applyOverrides,
            "overrides": ConfigOverrideStore.shared.asDictionary(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    private static func normalizedControllerPort(_ value: Int) -> Int {
        (1...65_535).contains(value) ? value : 9090
    }
}
