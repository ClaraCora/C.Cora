// 暴露系统 DNS 桥接函数给 Swift（实现见 SystemDNSBridge.c）。
// iOS 的 <resolv.h> 类型 Swift 导入不了，故由 C 侧完成抓取。
#ifndef CoraTunnel_Bridging_Header_h
#define CoraTunnel_Bridging_Header_h

#include "SystemDNSBridge.h"

#endif /* CoraTunnel_Bridging_Header_h */
