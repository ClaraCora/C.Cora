import Foundation

/// Phase 2 用的最小化 mihomo 配置构建器。
///
/// 目标：先用 **DIRECT 模式**（所有流量直连、不走任何代理节点）打通 tun 接管链路，
/// 证明「系统流量 → utun → mihomo → 物理网卡出网」整条路通。节点/订阅留到后续阶段。
///
/// 这份配置是上一轮真机调试得出的可工作配方的精简版，关键点：
/// - stack=gvisor：默认使用已验证的 gVisor；设置页可切换 system / mixed 做兼容性测试。
/// - fake-ip + 纯 IP 的 DoH 上游：IP 无需二次解析，杜绝 DNS 死循环。
/// - 地址统一 198.18.0.x：tun 网关、DNS、fake-ip-range 同段，避免 bind 失败。
/// - 不含任何 geoip/geosite 规则：geo 数据库在 NE 里加载会 OOM；DIRECT 测试用 MATCH。
enum MihomoConfig {

    /// 与 NEPacketTunnelNetworkSettings 对齐的常量。
    static let tunGatewayIP = "198.18.0.1"
    static let tunSubnetMask = "255.255.0.0"
    static let dnsServerIP = "198.18.0.2"
    static let fallbackMTU = 1500

    /// 生成 DIRECT 直连模式的最小配置 YAML。
    /// 注意：tun.file-descriptor 不在此处填写——它是运行期值，由 Go 侧
    /// StartWithFd 注入到 Tun.FileDescriptor。
    static func directModeYAML() -> String {
        """
        mode: direct
        log-level: info
        ipv6: false
        # iOS 上进程匹配不可用，关掉省开销
        find-process-mode: off
        geo-auto-update: false

        tun:
          enable: true
          # 默认使用已验证的 gvisor；Go 合并设置时可覆盖为 system / mixed
          stack: gvisor
          dns-hijack:
            - any:53
          auto-route: true
          auto-detect-interface: true

        dns:
          enable: true
          ipv6: false
          enhanced-mode: fake-ip
          fake-ip-range: 198.18.0.1/16
          cache-max-size: 512
          # 纯 IP 的 DoH：上游本身就是 IP，无需再解析，避免死循环
          nameserver:
            - https://223.5.5.5/dns-query
            - https://1.1.1.1/dns-query

        profile:
          store-selected: false

        proxies: []
        proxy-groups: []
        proxy-providers: {}
        rule-providers: {}
        sub-rules: {}

        # DIRECT 测试：全部直连，零 geo 规则（geo 在 NE 里会 OOM）
        rules:
          - MATCH,DIRECT
        """
    }

    /// 覆盖安装后，旧版内建 DIRECT 缓存仍带固定的 mtu: 1500。
    /// 仅匹配 App 自己生成的完整旧模板，避免改动用户自定义配置。
    static func migrateLegacyDirectModeYAML(_ yaml: String) -> String? {
        let current = directModeYAML()
        let marker = "  auto-detect-interface: true"
        let legacy = current.replacingOccurrences(
            of: marker,
            with: marker + "\n  mtu: 1500"
        )
        return yaml == legacy ? current : nil
    }
}
