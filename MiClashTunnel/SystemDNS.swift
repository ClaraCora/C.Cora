import Foundation
import SystemConfiguration

/// 读取 iOS 物理网络的 system DNS（SCDynamicStore 全局主解析器）。
///
/// 用途：订阅 DNS 配置里的 `nameserver: [system]`。Go 内核在 iOS 上读不到
/// 真实系统 DNS（没有可用的 /etc/resolv.conf），需要 NE 侧抓取后经
/// settings JSON（key: systemDNS）注入，Go 合并配置时把 "system" 替换成这些 IP。
enum SystemDNS {
    /// 当前主接口的 DNS 服务器地址（IPv4/IPv6 字面量）。
    ///
    /// 注意时机：隧道建立后系统主解析器会变成隧道自己的 DNS（198.18.0.x），
    /// 所以必须在 setTunnelNetworkSettings 之前抓取；之后的读取请过 excludingTunnel。
    static func currentServers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "MiClash" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(
                store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = global["ServerAddresses"] as? [String] else { return [] }
        return servers.compactMap { server in
            // 去掉 IPv6 zone 后缀（fe80::1%en0），mihomo 不接受带 zone 的地址
            let stripped = server.split(separator: "%", maxSplits: 1).first.map(String.init) ?? server
            return stripped.isEmpty ? nil : stripped
        }
    }

    /// 剔除本隧道自己的 DNS（198.18.0.0/16 fake-ip 网段），避免隧道 DNS 被回喂成 system DNS。
    static func excludingTunnel(_ servers: [String]) -> [String] {
        servers.filter { !$0.hasPrefix("198.18.") }
    }
}
