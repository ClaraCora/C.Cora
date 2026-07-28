// 把 libresolv 的解析器 API 暴露给 Swift：读取 iOS 物理网络 DNS
// （配置里 `nameserver: [system]` 的实际来源）。项目已链接 -lresolv。
#ifndef MiClashTunnel_Bridging_Header_h
#define MiClashTunnel_Bridging_Header_h

#include <resolv.h>
#include <arpa/inet.h>

#endif /* MiClashTunnel_Bridging_Header_h */
