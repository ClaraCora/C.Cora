import Foundation

/// 读取 iOS 物理网络的 system DNS（C 桥接，内部走 libresolv 的 res_getservers）。
///
/// 用途：订阅 DNS 配置里的 `nameserver: [system]`。Go 内核在 iOS 上读不到
/// 真实系统 DNS（没有可用的 /etc/resolv.conf），需要 NE 侧抓取后经
/// settings JSON（key: systemDNS）注入，Go 合并配置时把 "system" 替换成这些 IP。
///
/// 为什么经 C 桥接：SCDynamicStore 在 iOS 不可用；libresolv 的
/// res_sockaddr_union / __res_state 等类型 Swift 无法导入，
/// 所以抓取逻辑在 SystemDNSBridge.c，这里只读扁平缓冲区。
enum SystemDNS {
    /// 每个地址槽的字节数（= INET6_ADDRSTRLEN）。
    private static let stride = 46
    private static let maxCount = 8

    /// 当前主接口的 DNS 服务器地址（IPv4/IPv6 字面量）。
    ///
    /// 注意时机：隧道建立后系统主解析器会变成隧道自己的 DNS（198.18.0.x），
    /// 所以必须在 setTunnelNetworkSettings 之前抓取；之后的读取请过 excludingTunnel。
    static func currentServers() -> [String] {
        var buffer = [CChar](repeating: 0, count: stride * maxCount)
        let count = miclash_copy_system_dns(&buffer, Int32(stride), Int32(maxCount))
        guard count > 0 else { return [] }

        var servers: [String] = []
        for index in 0..<Int(count) {
            let start = index * stride
            let bytes = buffer[start..<(start + stride)]
                .prefix { $0 != 0 }
                .map { UInt8(bitPattern: $0) }
            if !bytes.isEmpty {
                servers.append(String(decoding: bytes, as: UTF8.self))
            }
        }
        return servers
    }

    /// 剔除本隧道自己的 DNS（198.18.0.0/16 fake-ip 网段），避免隧道 DNS 被回喂成 system DNS。
    static func excludingTunnel(_ servers: [String]) -> [String] {
        servers.filter { !$0.hasPrefix("198.18.") }
    }
}
