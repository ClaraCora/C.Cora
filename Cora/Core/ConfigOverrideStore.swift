import Foundation

struct HostOverride: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var domain: String
    var address: String

    init(id: UUID = UUID(), domain: String = "", address: String = "") {
        self.id = id
        self.domain = domain
        self.address = address
    }
}

/// 一套全局固定覆写参数。每个配置文件只决定是否应用这套参数。
@MainActor
final class ConfigOverrideStore: ObservableObject {
    static let shared = ConfigOverrideStore()

    /// 覆写参数通过下一次 mihomo 启动应用，设置页据此显示待应用状态。
    @Published private(set) var pendingConnectionApply = false

    @Published var overwriteDNS: Bool { didSet { save(overwriteDNS, Key.overwriteDNS) } }
    @Published var dnsListen: String { didSet { save(dnsListen, Key.dnsListen) } }
    @Published var dnsPreferH3: Bool { didSet { save(dnsPreferH3, Key.dnsPreferH3) } }
    @Published var dnsUseSystemHosts: Bool { didSet { save(dnsUseSystemHosts, Key.dnsUseSystemHosts) } }
    @Published var dnsUseHosts: Bool { didSet { save(dnsUseHosts, Key.dnsUseHosts) } }
    @Published var hosts: [HostOverride] { didSet { saveHosts() } }
    @Published var dnsEnhancedMode: String { didSet { save(dnsEnhancedMode, Key.dnsEnhancedMode) } }
    @Published var fakeIPFilterMode: String { didSet { save(fakeIPFilterMode, Key.fakeIPFilterMode) } }
    @Published var fakeIPFilter: [String] { didSet { save(fakeIPFilter, Key.fakeIPFilter) } }
    @Published var dnsRespectRules: Bool { didSet { save(dnsRespectRules, Key.dnsRespectRules) } }
    @Published var defaultNameservers: [String] { didSet { save(defaultNameservers, Key.defaultNameservers) } }
    @Published var nameservers: [String] { didSet { save(nameservers, Key.nameservers) } }
    @Published var proxyNameservers: [String] { didSet { save(proxyNameservers, Key.proxyNameservers) } }
    @Published var directNameservers: [String] { didSet { save(directNameservers, Key.directNameservers) } }
    @Published var fallbackNameservers: [String] { didSet { save(fallbackNameservers, Key.fallbackNameservers) } }
    @Published var fallbackGeoIP: Bool { didSet { save(fallbackGeoIP, Key.fallbackGeoIP) } }

    @Published var overwriteSniffer: Bool { didSet { save(overwriteSniffer, Key.overwriteSniffer) } }
    @Published var snifferEnabled: Bool { didSet { save(snifferEnabled, Key.snifferEnabled) } }
    @Published var snifferForceDNSMapping: Bool { didSet { save(snifferForceDNSMapping, Key.snifferForceDNSMapping) } }
    @Published var snifferParsePureIP: Bool { didSet { save(snifferParsePureIP, Key.snifferParsePureIP) } }
    @Published var snifferOverrideDestination: Bool { didSet { save(snifferOverrideDestination, Key.snifferOverrideDestination) } }
    @Published var sniffHTTP: Bool { didSet { save(sniffHTTP, Key.sniffHTTP) } }
    @Published var sniffTLS: Bool { didSet { save(sniffTLS, Key.sniffTLS) } }
    @Published var sniffQUIC: Bool { didSet { save(sniffQUIC, Key.sniffQUIC) } }
    @Published var forceSniffDomains: [String] { didSet { save(forceSniffDomains, Key.forceSniffDomains) } }
    @Published var skipSniffDomains: [String] { didSet { save(skipSniffDomains, Key.skipSniffDomains) } }

    @Published var overwriteTun: Bool { didSet { save(overwriteTun, Key.overwriteTun) } }
    @Published var tunDNSHijack: [String] { didSet { save(tunDNSHijack, Key.tunDNSHijack) } }
    @Published var tunStrictRoute: Bool { didSet { save(tunStrictRoute, Key.tunStrictRoute) } }
    @Published var tunICMPForwarding: Bool { didSet { save(tunICMPForwarding, Key.tunICMPForwarding) } }

    static let dnsModeOptions = ["fake-ip", "redir-host"]
    static let fakeIPFilterModeOptions = ["blacklist", "whitelist", "rule"]

    static let commonFakeIPFilter = [
        "*.lan",
        "*.local",
        "*.home.arpa",
        "time.*.com",
        "time.*.gov",
        "time.*.edu.cn",
        "time.*.apple.com",
        "time-ios.apple.com",
        "localhost.ptlogin2.qq.com",
        "localhost.sec.qq.com",
        "localhost.work.weixin.qq.com",
        "+.msftconnecttest.com",
        "+.msftncsi.com",
        "stun.*.*",
        "stun.*.*.*",
        "+.stun.*.*",
        "+.stun.*.*.*",
        "+.stun.*.*.*.*",
        "lens.l.google.com",
        "*.n.n.srv.nintendo.net",
        "+.xboxlive.com",
    ]

    var validationWarnings: [String] {
        var warnings: [String] = []
        if overwriteDNS {
            if !Self.isValidListenAddress(dnsListen) {
                warnings.append("DNS 监听地址无效，应为 host:port，例如 0.0.0.0:1053")
            }
            for (title, values) in [
                ("默认域名解析服务器", defaultNameservers),
                ("域名解析服务器", nameservers),
                ("代理域名解析服务器", proxyNameservers),
                ("直连域名解析服务器", directNameservers),
                ("Fallback 域名解析服务器", fallbackNameservers)
            ] where values.contains(where: { !Self.isValidResolver($0) }) {
                warnings.append("\(title)中存在无法识别的地址")
            }
            if dnsUseHosts && hosts.contains(where: {
                $0.domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !Self.isValidIP($0.address)
            }) {
                warnings.append("Hosts 中存在空域名或无效 IP 地址")
            }
        }
        if overwriteTun && tunDNSHijack.contains(where: { !Self.isValidHijackRule($0) }) {
            warnings.append("DNS 接管规则中存在无效的端口")
        }
        return warnings
    }

    private let defaults = UserDefaults.standard

    private enum Key {
        static let overwriteDNS = "override.dns.enabled"
        static let dnsListen = "override.dns.listen"
        static let dnsPreferH3 = "override.dns.preferH3"
        static let dnsUseSystemHosts = "override.dns.useSystemHosts"
        static let dnsUseHosts = "override.dns.useHosts"
        static let hosts = "override.hosts"
        static let dnsEnhancedMode = "override.dns.enhancedMode"
        static let fakeIPFilterMode = "override.dns.fakeIPFilterMode"
        static let fakeIPFilter = "override.dns.fakeIPFilter"
        static let dnsRespectRules = "override.dns.respectRules"
        static let defaultNameservers = "override.dns.defaultNameservers"
        static let nameservers = "override.dns.nameservers"
        static let proxyNameservers = "override.dns.proxyNameservers"
        static let directNameservers = "override.dns.directNameservers"
        static let fallbackNameservers = "override.dns.fallbackNameservers"
        static let fallbackGeoIP = "override.dns.fallbackGeoIP"
        static let overwriteSniffer = "override.sniffer.enabled"
        static let snifferEnabled = "override.sniffer.runtimeEnabled"
        static let snifferForceDNSMapping = "override.sniffer.forceDNSMapping"
        static let snifferParsePureIP = "override.sniffer.parsePureIP"
        static let snifferOverrideDestination = "override.sniffer.overrideDestination"
        static let sniffHTTP = "override.sniffer.http"
        static let sniffTLS = "override.sniffer.tls"
        static let sniffQUIC = "override.sniffer.quic"
        static let forceSniffDomains = "override.sniffer.forceDomains"
        static let skipSniffDomains = "override.sniffer.skipDomains"
        static let overwriteTun = "override.tun.enabled"
        static let tunDNSHijack = "override.tun.dnsHijack"
        static let tunStrictRoute = "override.tun.strictRoute"
        static let tunICMPForwarding = "override.tun.icmpForwarding"
    }

    private init() {
        overwriteDNS = Self.bool(defaults, Key.overwriteDNS, default: true)
        dnsListen = defaults.string(forKey: Key.dnsListen) ?? "0.0.0.0:1053"
        dnsPreferH3 = Self.bool(defaults, Key.dnsPreferH3, default: false)
        dnsUseSystemHosts = Self.bool(defaults, Key.dnsUseSystemHosts, default: true)
        dnsUseHosts = Self.bool(defaults, Key.dnsUseHosts, default: true)
        if let data = defaults.data(forKey: Key.hosts),
           let decoded = try? JSONDecoder().decode([HostOverride].self, from: data) {
            hosts = decoded
        } else {
            hosts = []
        }
        let storedDNSMode = defaults.string(forKey: Key.dnsEnhancedMode) ?? "fake-ip"
        dnsEnhancedMode = Self.dnsModeOptions.contains(storedDNSMode) ? storedDNSMode : "fake-ip"
        let storedFilterMode = defaults.string(forKey: Key.fakeIPFilterMode) ?? "blacklist"
        fakeIPFilterMode = Self.fakeIPFilterModeOptions.contains(storedFilterMode)
            ? storedFilterMode : "blacklist"
        fakeIPFilter = defaults.stringArray(forKey: Key.fakeIPFilter) ?? Self.commonFakeIPFilter
        dnsRespectRules = Self.bool(defaults, Key.dnsRespectRules, default: false)
        defaultNameservers = defaults.stringArray(forKey: Key.defaultNameservers)
            ?? ["223.5.5.5", "1.1.1.1"]
        nameservers = defaults.stringArray(forKey: Key.nameservers)
            ?? ["https://223.5.5.5/dns-query", "https://1.1.1.1/dns-query"]
        proxyNameservers = defaults.stringArray(forKey: Key.proxyNameservers)
            ?? ["https://1.1.1.1/dns-query"]
        directNameservers = defaults.stringArray(forKey: Key.directNameservers) ?? ["system"]
        fallbackNameservers = defaults.stringArray(forKey: Key.fallbackNameservers) ?? []
        fallbackGeoIP = Self.bool(defaults, Key.fallbackGeoIP, default: true)

        overwriteSniffer = Self.bool(defaults, Key.overwriteSniffer, default: true)
        snifferEnabled = Self.bool(defaults, Key.snifferEnabled, default: true)
        snifferForceDNSMapping = Self.bool(defaults, Key.snifferForceDNSMapping, default: true)
        snifferParsePureIP = Self.bool(defaults, Key.snifferParsePureIP, default: true)
        snifferOverrideDestination = Self.bool(defaults, Key.snifferOverrideDestination, default: true)
        sniffHTTP = Self.bool(defaults, Key.sniffHTTP, default: true)
        sniffTLS = Self.bool(defaults, Key.sniffTLS, default: true)
        sniffQUIC = Self.bool(defaults, Key.sniffQUIC, default: true)
        forceSniffDomains = defaults.stringArray(forKey: Key.forceSniffDomains) ?? []
        skipSniffDomains = defaults.stringArray(forKey: Key.skipSniffDomains) ?? []

        overwriteTun = Self.bool(defaults, Key.overwriteTun, default: true)
        tunDNSHijack = defaults.stringArray(forKey: Key.tunDNSHijack) ?? ["any:53"]
        tunStrictRoute = Self.bool(defaults, Key.tunStrictRoute, default: false)
        tunICMPForwarding = Self.bool(defaults, Key.tunICMPForwarding, default: true)
    }

    func asDictionary() -> [String: Any] {
        var hostMap: [String: String] = [:]
        for host in hosts {
            let domain = host.domain.trimmingCharacters(in: .whitespacesAndNewlines)
            let address = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
            if !domain.isEmpty, !address.isEmpty { hostMap[domain] = address }
        }
        return [
            "dns": [
                "overwrite": overwriteDNS,
                "listen": dnsListen.trimmingCharacters(in: .whitespacesAndNewlines),
                "preferH3": dnsPreferH3,
                "useSystemHosts": dnsUseSystemHosts,
                "useHosts": dnsUseHosts,
                "hosts": hostMap,
                "enhancedMode": dnsEnhancedMode,
                "fakeIPFilterMode": fakeIPFilterMode,
                "fakeIPFilter": cleaned(fakeIPFilter),
                "respectRules": dnsRespectRules,
                "defaultNameservers": cleaned(defaultNameservers),
                "nameservers": cleaned(nameservers),
                "proxyNameservers": cleaned(proxyNameservers),
                "directNameservers": cleaned(directNameservers),
                "fallbackNameservers": cleaned(fallbackNameservers),
                "fallbackGeoIP": fallbackGeoIP,
            ],
            "sniffer": [
                "overwrite": overwriteSniffer,
                "enable": snifferEnabled,
                "forceDNSMapping": snifferForceDNSMapping,
                "parsePureIP": snifferParsePureIP,
                "overrideDestination": snifferOverrideDestination,
                "http": sniffHTTP,
                "tls": sniffTLS,
                "quic": sniffQUIC,
                "forceDomains": cleaned(forceSniffDomains),
                "skipDomains": cleaned(skipSniffDomains),
            ],
            "tun": [
                "overwrite": overwriteTun,
                "dnsHijack": cleaned(tunDNSHijack),
                "strictRoute": tunStrictRoute,
                "icmpForwarding": tunICMPForwarding,
            ],
        ]
    }

    func restoreDefaults() {
        overwriteDNS = true
        dnsListen = "0.0.0.0:1053"
        dnsPreferH3 = false
        dnsUseSystemHosts = true
        dnsUseHosts = true
        hosts = []
        dnsEnhancedMode = "fake-ip"
        fakeIPFilterMode = "blacklist"
        fakeIPFilter = Self.commonFakeIPFilter
        dnsRespectRules = false
        defaultNameservers = ["223.5.5.5", "1.1.1.1"]
        nameservers = ["https://223.5.5.5/dns-query", "https://1.1.1.1/dns-query"]
        proxyNameservers = ["https://1.1.1.1/dns-query"]
        directNameservers = ["system"]
        fallbackNameservers = []
        fallbackGeoIP = true
        overwriteSniffer = true
        snifferEnabled = true
        snifferForceDNSMapping = true
        snifferParsePureIP = true
        snifferOverrideDestination = true
        sniffHTTP = true
        sniffTLS = true
        sniffQUIC = true
        forceSniffDomains = []
        skipSniffDomains = []
        overwriteTun = true
        tunDNSHijack = ["any:53"]
        tunStrictRoute = false
        tunICMPForwarding = true
    }

    func markConnectionSettingsApplied() {
        pendingConnectionApply = false
    }

    private func cleaned(_ values: [String]) -> [String] {
        values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        pendingConnectionApply = true
    }

    private func saveHosts() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        defaults.set(data, forKey: Key.hosts)
        pendingConnectionApply = true
    }

    private static func bool(_ defaults: UserDefaults, _ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    private static func isValidListenAddress(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let separator = trimmed.lastIndex(of: ":") else { return false }
        let host = String(trimmed[..<separator]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let port = Int(trimmed[trimmed.index(after: separator)...]) ?? 0
        return !host.isEmpty && port > 0 && port <= 65_535 && !host.contains(" ")
    }

    private static func isValidResolver(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == "system" || isValidIP(trimmed) { return true }
        if SettingsStore.isValidHTTPURL(trimmed, allowEmpty: false) { return true }
        return !trimmed.contains(where: { $0.isWhitespace }) && !trimmed.contains(",")
    }

    private static func isValidIP(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let ipv4Parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if ipv4Parts.count == 4,
           ipv4Parts.allSatisfy({ part in
               guard let number = Int(part) else { return false }
               return (0...255).contains(number)
           }) {
            return true
        }
        guard trimmed.contains(":"), !trimmed.contains(where: { $0.isWhitespace }) else { return false }
        return trimmed.allSatisfy { $0.isNumber || "abcdefABCDEF:".contains($0) }
    }

    private static func isValidHijackRule(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.lastIndex(of: ":") else { return false }
        let port = Int(trimmed[trimmed.index(after: separator)...]) ?? 0
        return !trimmed[..<separator].isEmpty && port > 0 && port <= 65_535
    }
}
