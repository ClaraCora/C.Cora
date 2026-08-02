#ifndef SYSTEM_DNS_BRIDGE_H
#define SYSTEM_DNS_BRIDGE_H

/// 把当前系统 DNS 服务器（IPv4/IPv6 字面量）写入扁平缓冲区 out。
/// out 容量为 stride * maxCount 字节，每个服务器占 stride 字节（含 NUL 结尾，
/// IPv6 link-local 地址会附加 `%<interface>` scope，建议 stride >= 64）。
/// 返回实际写入个数，失败返回 0。
///
/// 为什么用 C：iOS 的 <resolv.h> 里 res_sockaddr_union / __res_state 等类型
/// Swift 无法导入（头文件本身在 C 侧可用），抓取逻辑只能放在 C 实现。
int miclash_copy_system_dns(char *out, int stride, int maxCount);

/// Read DNS servers from the scoped resolver associated with interfaceName.
/// This remains usable after the packet tunnel installs its own default DNS.
/// Returns the number of addresses written, or 0 when no scoped resolver is
/// available. The private resolver symbols are loaded dynamically at runtime.
int miclash_copy_scoped_dns(const char *interfaceName,
                            char *out, int stride, int maxCount);

/// Read routable unicast IPv4/IPv6 addresses assigned to interfaceName.
/// Returns the number of addresses written.
int miclash_copy_interface_addresses(const char *interfaceName,
                                     char *out, int stride, int maxCount);

#endif /* SYSTEM_DNS_BRIDGE_H */
