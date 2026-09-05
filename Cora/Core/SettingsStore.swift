import Foundation

/// 内核相关设置（持久化到 UserDefaults）。
///
/// 这些影响 NE 内 mihomo 的启动配置：连接时序列化为 JSON 经 startVPNTunnel(options) 下发，
/// Go 侧 StartWithConfig 据此覆盖 tun.stack / ipv6 / geo / log-level 等运行设置。
/// 因此**修改后需重新连接才生效**。
@MainActor
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    /// iOS Packet Tunnel 只支持经过验证的 gVisor 栈。保留字段用于兼容旧版本，
    /// 但不向用户暴露 system/mixed，避免保存不可用的网络配置。
    static let fixedStack = "gvisor"

    /// 当前连接尚未应用的运行设置。设置页用它显示“下次连接生效”。
    @Published private(set) var pendingConnectionApply = false

    /// TCP/IP 栈。iOS NE 只使用经过验证的 gVisor，system/mixed 会被强制回退。
    @Published var stack: String {
        didSet {
            guard stack == Self.fixedStack else {
                stack = Self.fixedStack
                return
            }
            d.set(stack, forKey: K.stack)
            markConnectionSettingsPending()
        }
    }
    @Published var ipv6: Bool {
        didSet { d.set(ipv6, forKey: K.ipv6); markConnectionSettingsPending() }
    }
    /// 启用 geo 规则（默认开启）。关闭时剔除 GEOIP/GEOSITE/IP-ASN 规则。
    @Published var geoEnabled: Bool {
        didSet { d.set(geoEnabled, forKey: K.geoEnabled); markConnectionSettingsPending() }
    }
    /// geo 加载器：standard / memconservative（小内存优化，NE 推荐）。
    @Published var geoLoader: String {
        didSet {
            guard Self.geoLoaderOptions.contains(geoLoader) else {
                geoLoader = "memconservative"
                return
            }
            d.set(geoLoader, forKey: K.geoLoader)
            markConnectionSettingsPending()
        }
    }
    /// true 使用 GeoIP.dat；false 使用 MMDB（geoip.metadb）。
    @Published var geodataMode: Bool {
        didSet { d.set(geodataMode, forKey: K.geodataMode); markConnectionSettingsPending() }
    }
    @Published var geoIPDatURL: String {
        didSet { d.set(geoIPDatURL, forKey: K.geoIPDatURL); markConnectionSettingsPending() }
    }
    @Published var geoMMDBURL: String {
        didSet { d.set(geoMMDBURL, forKey: K.geoMMDBURL); markConnectionSettingsPending() }
    }
    @Published var geoSiteURL: String {
        didSet { d.set(geoSiteURL, forKey: K.geoSiteURL); markConnectionSettingsPending() }
    }
    /// 是否忽略 geolocation-!cn / NOT(GEOIP) 等 geo 取反规则。
    @Published var ignoreGeoNegation: Bool {
        didSet { d.set(ignoreGeoNegation, forKey: K.ignoreGeoNegation); markConnectionSettingsPending() }
    }
    /// 由主 App 自动更新 geo 数据库。
    @Published var geoAutoUpdate: Bool { didSet { d.set(geoAutoUpdate, forKey: K.geoAuto) } }
    /// 自动更新间隔（小时）。
    @Published var geoUpdateInterval: Int {
        didSet {
            let normalized = min(max(geoUpdateInterval, 1), 168)
            if geoUpdateInterval != normalized {
                geoUpdateInterval = normalized
                return
            }
            d.set(geoUpdateInterval, forKey: K.geoInterval)
        }
    }
    /// 远程 Provider 更新策略：inherit=遵从配置，disabled=关闭，fixed=统一间隔。
    @Published var remoteResourceUpdatePolicy: String {
        didSet {
            let normalized = Self.remoteResourceUpdatePolicyOptions.contains(remoteResourceUpdatePolicy)
                ? remoteResourceUpdatePolicy
                : "inherit"
            if remoteResourceUpdatePolicy != normalized {
                remoteResourceUpdatePolicy = normalized
                return
            }
            d.set(normalized, forKey: K.remoteResourcePolicy)
            markConnectionSettingsPending()
        }
    }
    /// 远程 Provider 固定更新间隔（小时），仅策略为 fixed 时使用。
    @Published var remoteResourceUpdateInterval: Int {
        didSet {
            let normalized = min(max(remoteResourceUpdateInterval, 1), 168)
            if remoteResourceUpdateInterval != normalized {
                remoteResourceUpdateInterval = normalized
                return
            }
            d.set(normalized, forKey: K.remoteResourceInterval)
            markConnectionSettingsPending()
        }
    }
    /// 日志等级：silent / error / warning / info / debug。
    @Published var logLevel: String {
        didSet {
            guard Self.logLevelOptions.contains(logLevel) else {
                logLevel = "info"
                return
            }
            d.set(logLevel, forKey: K.logLevel)
            markConnectionSettingsPending()
        }
    }
    /// 开发者内存诊断。默认关闭；开启后才会在 Network Extension 中按 5 秒间隔
    /// 采集有限的物理内存、Go 堆、连接和 goroutine 快照。
    @Published var developerMode: Bool {
        didSet {
            d.set(developerMode, forKey: K.developerMode)
            // 系统重连可能没有携带 options；把开关同步到 App Group 的单字节标记，
            // 让 NE 在没有主 App 参与时也能保持关闭状态。
            if let stateURL = AppGroup.containerURL?.appendingPathComponent("developer-mode.state") {
                let value = developerMode ? "1" : "0"
                try? value.write(to: stateURL, atomically: true, encoding: .utf8)
            }
        }
    }
    /// 策略组与节点测速使用的 HTTP(S) 地址，仅由主 App 的测速 IPC 使用，无需重连。
    @Published var delayTestURL: String { didSet { d.set(delayTestURL, forKey: K.delayTestURL) } }
    /// DIRECT/国内直连节点使用的测速地址，仅由主 App 的测速 IPC 使用。
    @Published var directDelayTestURL: String {
        didSet { d.set(directDelayTestURL, forKey: K.directDelayTestURL) }
    }
    /// 让各策略组使用同一测速地址，默认开启并在下次连接时写入内核配置。
    @Published var unifiedDelay: Bool {
        didSet { d.set(unifiedDelay, forKey: K.unifiedDelay); markConnectionSettingsPending() }
    }
    /// 策略组与节点测速的 IPC 超时（秒）。仅影响主 App 测速，无需重连。
    @Published var delayTestTimeout: Int {
        didSet {
            let normalized = min(max(delayTestTimeout, 1), 60)
            if delayTestTimeout != normalized {
                delayTestTimeout = normalized
                d.set(normalized, forKey: K.delayTestTimeout)
                return
            }
            d.set(delayTestTimeout, forKey: K.delayTestTimeout)
        }
    }
    /// 混合代理端口（HTTP+SOCKS，本机回环）。0=不开。下发给内核 mixed-port。
    @Published var mixedPort: Int {
        didSet {
            let normalized = min(max(mixedPort, 0), 65_535)
            if mixedPort != normalized {
                mixedPort = normalized
                d.set(normalized, forKey: K.mixedPort)
                return
            }
            d.set(mixedPort, forKey: K.mixedPort)
            markConnectionSettingsPending()
        }
    }
    /// 仅拒绝已知公网 WebRTC/STUN 探测端点，不按端口封锁通用 ICE 流量。
    @Published var blockDirectSTUN: Bool {
        didSet { d.set(blockDirectSTUN, forKey: K.blockDirectSTUN); markConnectionSettingsPending() }
    }
    /// 拉取订阅时用的 User-Agent（机场常按 UA 返回不同格式）。默认 clash-meta。
    /// 仅主 App 下载订阅用，不经内核。
    @Published var subscriptionUA: String { didSet { d.set(subscriptionUA, forKey: K.subUA) } }

    // 以下 5 项是 NETunnelProviderProtocol(NEVPNProtocol) 开关，连接时由主 App 设到隧道协议上，
    // 不经内核（与 mihomo 配置无关）。
    /// 接管所有网络（含系统默认会排除的流量）。
    @Published var includeAllNetworks: Bool {
        didSet { d.set(includeAllNetworks, forKey: K.inclAll); markConnectionSettingsPending() }
    }
    /// 排除蜂窝服务（VoLTE 等），默认 true（Apple 建议）。
    @Published var excludeCellularServices: Bool {
        didSet { d.set(excludeCellularServices, forKey: K.exCell); markConnectionSettingsPending() }
    }
    /// 排除 APNs（推送），默认 true。
    @Published var excludeAPNs: Bool {
        didSet { d.set(excludeAPNs, forKey: K.exAPNs); markConnectionSettingsPending() }
    }
    /// 排除设备间通信（隔空投送/接力等），默认 true。
    @Published var excludeDeviceCommunication: Bool {
        didSet { d.set(excludeDeviceCommunication, forKey: K.exDev); markConnectionSettingsPending() }
    }
    /// 强制路由（即使 includeAllNetworks 关，也强制按规则路由）。
    @Published var enforceRoutes: Bool {
        didSet { d.set(enforceRoutes, forKey: K.enforce); markConnectionSettingsPending() }
    }
    /// 使用 iOS Connect On Demand 在重启或网络变化后自动连接。
    @Published var alwaysOnVPN: Bool {
        didSet {
            d.set(alwaysOnVPN, forKey: K.alwaysOnVPN)
            AppGroupState.alwaysOnVPNEnabled = alwaysOnVPN
            if !alwaysOnVPN {
                AppGroupState.vpnAutoConnectSuspended = false
            }
        }
    }

    static let logLevelOptions = ["silent", "error", "warning", "info", "debug"]
    static let geoLoaderOptions = ["memconservative", "standard"]
    static let remoteResourceUpdatePolicyOptions = ["inherit", "disabled", "fixed"]
    static let defaultGeoIPDatURL =
        "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
    static let defaultGeoMMDBURL =
        "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"
    static let defaultGeoSiteURL =
        "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
    static let defaultASNURL =
        "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb"
    static let defaultDelayTestURL = "https://www.gstatic.com/generate_204"
    static let defaultDirectDelayTestURL =
        "https://connectivitycheck.platform.hicloud.com/generate_204"

    private let d = UserDefaults.standard
    private enum K {
        static let stack = "set.stack", ipv6 = "set.ipv6"
        static let geoEnabled = "set.geoEnabled", geoLoader = "set.geoLoader"
        static let geodataMode = "set.geodataMode"
        static let geoIPDatURL = "set.geoIPDatURL", geoMMDBURL = "set.geoMMDBURL"
        static let geoSiteURL = "set.geoSiteURL"
        static let ignoreGeoNegation = "set.ignoreGeoNegation"
        static let geoAuto = "set.geoAuto", geoInterval = "set.geoInterval"
        static let remoteResourcePolicy = "set.remoteResourceUpdatePolicy"
        static let remoteResourceInterval = "set.remoteResourceUpdateInterval"
        static let logLevel = "set.logLevel"
        static let developerMode = "set.developerMode"
        static let delayTestURL = "set.delayTestURL"
        static let directDelayTestURL = "set.directDelayTestURL"
        static let unifiedDelay = "set.unifiedDelay"
        static let delayTestTimeout = "set.delayTestTimeout"
        static let mixedPort = "set.mixedPort"
        static let blockDirectSTUN = "set.blockDirectSTUN"
        static let inclAll = "set.inclAll", exCell = "set.exCell", exAPNs = "set.exAPNs"
        static let exDev = "set.exDev", enforce = "set.enforce"
        static let alwaysOnVPN = "set.alwaysOnVPN"
        static let subUA = "set.subUA"
    }

    private init() {
        let storedStack = d.string(forKey: K.stack)
        stack = Self.fixedStack
        if storedStack != Self.fixedStack { d.set(Self.fixedStack, forKey: K.stack) }
        ipv6 = d.object(forKey: K.ipv6) as? Bool ?? false
        geoEnabled = d.object(forKey: K.geoEnabled) as? Bool ?? true
        let storedGeoLoader = d.string(forKey: K.geoLoader) ?? "memconservative"
        geoLoader = Self.geoLoaderOptions.contains(storedGeoLoader) ? storedGeoLoader : "memconservative"
        if storedGeoLoader != geoLoader { d.set(geoLoader, forKey: K.geoLoader) }
        geodataMode = d.object(forKey: K.geodataMode) as? Bool ?? true
        geoIPDatURL = d.string(forKey: K.geoIPDatURL) ?? Self.defaultGeoIPDatURL
        geoMMDBURL = d.string(forKey: K.geoMMDBURL) ?? Self.defaultGeoMMDBURL
        geoSiteURL = d.string(forKey: K.geoSiteURL) ?? Self.defaultGeoSiteURL
        ignoreGeoNegation = d.object(forKey: K.ignoreGeoNegation) as? Bool ?? false
        geoAutoUpdate = d.object(forKey: K.geoAuto) as? Bool ?? false
        let gi = d.integer(forKey: K.geoInterval)
        geoUpdateInterval = gi == 0 ? 24 : min(max(gi, 1), 168)
        let remotePolicy = d.string(forKey: K.remoteResourcePolicy) ?? "inherit"
        remoteResourceUpdatePolicy = Self.remoteResourceUpdatePolicyOptions.contains(remotePolicy)
            ? remotePolicy
            : "inherit"
        let remoteInterval = d.integer(forKey: K.remoteResourceInterval)
        remoteResourceUpdateInterval = remoteInterval == 0
            ? 24
            : min(max(remoteInterval, 1), 168)
        let storedLogLevel = d.string(forKey: K.logLevel) ?? "info"
        logLevel = Self.logLevelOptions.contains(storedLogLevel) ? storedLogLevel : "info"
        if storedLogLevel != logLevel { d.set(logLevel, forKey: K.logLevel) }
        developerMode = d.object(forKey: K.developerMode) as? Bool ?? false
        delayTestURL = d.string(forKey: K.delayTestURL) ?? Self.defaultDelayTestURL
        directDelayTestURL = d.string(forKey: K.directDelayTestURL)
            ?? Self.defaultDirectDelayTestURL
        unifiedDelay = d.object(forKey: K.unifiedDelay) as? Bool ?? true
        let delayTimeout = d.integer(forKey: K.delayTestTimeout)
        delayTestTimeout = delayTimeout == 0 ? 5 : min(max(delayTimeout, 1), 60)
        mixedPort = min(max(d.integer(forKey: K.mixedPort), 0), 65_535)
        blockDirectSTUN = d.object(forKey: K.blockDirectSTUN) as? Bool ?? false
        includeAllNetworks = d.object(forKey: K.inclAll) as? Bool ?? false
        excludeCellularServices = d.object(forKey: K.exCell) as? Bool ?? true
        excludeAPNs = d.object(forKey: K.exAPNs) as? Bool ?? true
        excludeDeviceCommunication = d.object(forKey: K.exDev) as? Bool ?? true
        enforceRoutes = d.object(forKey: K.enforce) as? Bool ?? false
        alwaysOnVPN = d.object(forKey: K.alwaysOnVPN) as? Bool ?? false
        subscriptionUA = d.string(forKey: K.subUA) ?? "clash-meta"
        AppGroupState.alwaysOnVPNEnabled = alwaysOnVPN
    }

    /// 序列化为下发给 NE 的 JSON。
    func asJSON(geoAvailable: Bool = true,
                applyOverrides: Bool = true,
                proxySelections: [String: String] = [:]) -> String {
        let dict: [String: Any] = [
            "stack": Self.fixedStack,
            "ipv6": ipv6,
            "geoEnabled": geoEnabled && geoAvailable,
            "geoLoader": geoLoader,
            "geodataMode": geodataMode,
            "geoIPDatURL": Self.effectiveHTTPURL(geoIPDatURL, fallback: Self.defaultGeoIPDatURL),
            "geoMMDBURL": Self.effectiveHTTPURL(geoMMDBURL, fallback: Self.defaultGeoMMDBURL),
            "geoSiteURL": Self.effectiveHTTPURL(geoSiteURL, fallback: Self.defaultGeoSiteURL),
            "ignoreGeoNegation": ignoreGeoNegation,
            "geoAutoUpdate": geoAutoUpdate,
            "geoUpdateInterval": geoUpdateInterval,
            "remoteResourceUpdatePolicy": remoteResourceUpdatePolicy,
            "remoteResourceUpdateInterval": remoteResourceUpdateInterval,
            "logLevel": logLevel,
            "developerMode": developerMode,
            "unifiedDelay": unifiedDelay,
            "mixedPort": mixedPort,
            "blockDirectSTUN": blockDirectSTUN,
            "proxySelections": proxySelections,
            "applyOverrides": applyOverrides,
            "overrides": ConfigOverrideStore.shared.asDictionary(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    func markConnectionSettingsApplied() {
        pendingConnectionApply = false
    }

    private func markConnectionSettingsPending() {
        pendingConnectionApply = true
    }

    static func isValidHTTPURL(_ value: String, allowEmpty: Bool = true) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return allowEmpty }
        guard !trimmed.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else { return false }
        return true
    }

    static func effectiveHTTPURL(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidHTTPURL(trimmed) ? trimmed : fallback
    }

    static func httpURLValidationMessage(_ value: String, allowEmpty: Bool = true) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !allowEmpty else { return nil }
        return isValidHTTPURL(trimmed, allowEmpty: allowEmpty)
            ? nil
            : "请输入有效的 HTTP/HTTPS 地址"
    }
}
