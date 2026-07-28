import Foundation

/// 读取 iOS 物理网络的 system DNS（libresolv 的 res_9_getservers）。
///
/// 用途：订阅 DNS 配置里的 `nameserver: [system]`。Go 内核在 iOS 上读不到
/// 真实系统 DNS（没有可用的 /etc/resolv.conf），需要 NE 侧抓取后经
/// settings JSON（key: systemDNS）注入，Go 合并配置时把 "system" 替换成这些 IP。
///
/// 为什么用 libresolv：SCDynamicStore 在 iOS 上不可用；res_9_* 是 iOS 上
/// 唯一能拿到当前物理网络 DNS 服务器列表的公开途径，项目已链接 -lresolv。
enum SystemDNS {
    /// 当前主接口的 DNS 服务器地址（IPv4/IPv6 字面量）。
    ///
    /// 注意时机：隧道建立后系统主解析器会变成隧道自己的 DNS（198.18.0.x），
    /// 所以必须在 setTunnelNetworkSettings 之前抓取；之后的读取请过 excludingTunnel。
    static func currentServers() -> [String] {
        var state = res_9_state()
        guard res_9_ninit(&state) == 0 else { return [] }
        defer { res_9_ndestroy(&state) }

        let capacity: Int32 = 8
        var servers = [res_sockaddr_union](repeating: res_sockaddr_union(), count: Int(capacity))
        let count = res_9_getservers(&state, &servers, capacity)
        guard count > 0 else { return [] }

        var result: [String] = []
        for index in 0..<min(Int(count), Int(capacity)) {
            if let address = string(from: servers[index]) {
                result.append(address)
            }
        }
        return result
    }

    /// 剔除本隧道自己的 DNS（198.18.0.0/16 fake-ip 网段），避免隧道 DNS 被回喂成 system DNS。
    static func excludingTunnel(_ servers: [String]) -> [String] {
        servers.filter { !$0.hasPrefix("198.18.") }
    }

    private static func string(from address: res_sockaddr_union) -> String? {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch Int32(address.sin.sin_family) {
        case AF_INET:
            var v4 = address.sin.sin_addr
            guard inet_ntop(AF_INET, &v4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        case AF_INET6:
            var v6 = address.sin6.sin6_addr
            guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        default:
            return nil
        }
        return String(cString: buffer)
    }
}
