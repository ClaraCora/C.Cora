# Mihomo v1.19.32 升级记录

实施日期：2026-10-08。上游版本：[v1.19.32](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.32)，
对应提交 `88dcbf7f1614a67c3b36b848ee3592dfa92ada36`。

## 版本与补丁迁移

| 组件 | 本次版本 |
| --- | --- |
| Mihomo | v1.19.32 |
| sing | v0.5.8 |
| sing-tun | v0.4.27 |
| gVisor | v0.0.0-20260922041103-e2cbcd6e7400 |
| sing-shadowsocks2 | v0.2.8，保持不变 |
| CI Go 工具链 | 1.25.4，保持不变 |

`go.mod`、`go.sum`、版本绑定补丁、准备脚本的源码哈希和 CI 嵌套替换同步更新。
XCFramework 构建脚本继续从模块版本读取版本号并注入内核；App 的内核版本显示使用该值。
App 版本仍为 1.0.7。

九个 Mihomo 补丁全部保留，包括 MRS 有界解压、缓冲池、渐进解析、连接关闭队列、
保留地址保护、DNS 原子更新、内存诊断及 Provider/NTP 生命周期清理。
sing 缓冲池和诊断、Shadowsocks reader、gVisor ACK 队列和诊断补丁也继续启用。

sing-tun 诊断补丁围绕新版 `tun_darwin.go` 重新生成，保留上游 `writeAccess` 写锁、
套接字设置和描述符关闭处理，再加入项目原有的诊断源与 Close 清理。
Darwin 接收仍为单处理器，保留原有 512 KiB 接收队列边界和 128 包发送 FIFO。

上游默认 TUN 栈已改为 mips，Cora 继续明确注入 gVisor。新增实际配置解析回归，
覆盖省略栈及配置/settings 传入 mips、system 的情况，最终均为 gVisor。

本次未调整 GOGC、GOMEMLIMIT、DNS/Fake-IP、Provider 更新频率、IPC 预算、测速或
解锁脚本并发、排行榜和历史采样。没有修改用户配置，也没有增加正常运行的后台采样。

## 已完成的本地验证

Windows 本地使用缓存的 Go 1.25.5，项目 CI 仍固定 1.25.4。使用隔离模块副本测试，
未修改全局模块缓存或把本地 replace 写入项目。

- 按准备脚本实际顺序，严格应用 16 个补丁，52 项 SHA-256 校验全部通过。
  同时校验补丁前、功能补丁后及新版 Darwin 诊断补丁后的文件。
- 所有 iOS 准备脚本及 XCFramework 构建脚本通过 Bash 语法检查。
- MobileCore 默认及 `with_gvisor,with_low_memory` 测试与 vet 通过，包含新增 gVisor 配置回归。
- Mihomo 受影响的 19 个包通过默认及 `with_low_memory` 测试与 vet，覆盖配置、DNS、
  Provider/Fetcher、NTP、MRS、连接关闭队列、缓冲池、outboundgroup、AnyTLS 和 OpenVPN。
  Provider、健康检查和 NTP 生命周期回归包含 100 次循环。
- sing 缓冲池、Shadowsocks2 reader 的默认及低内存测试通过；新版 gVisor 的 TCP、
  qdisc 和 FIFO 测试通过。
- MobileCore、sing-tun 及其 Darwin fd endpoint 使用
  `with_gvisor,with_low_memory` 完成 Darwin/arm64 测试二进制交叉编译。
- MobileCore 同时通过 Darwin/amd64 测试二进制交叉编译，覆盖 Intel 模拟器架构。
- gomobile 的 Objective-C 绑定在默认及 Darwin/arm64 低内存目标下生成成功；
  核对 NE 使用的 14 个字节响应接口，
  继续生成 `NSData` 桥接声明。

以上结果证明本地源码与绑定兼容，不等同于完整 iOS 构建或真机运行结果。
历史内存与吞吐测量仍见原记录，未将旧版本数据改称 v1.19.32 测量。

## macOS 与真机待确认

Windows 无法执行完整标准/Legacy XCFramework、Swift/Xcode 构建、macOS race 检查或
iOS 真机验证。相关 CI 检查保留，并补充 outboundgroup、AnyTLS 和 OpenVPN 回归。

新版 sing-tun Darwin 套接字接收缓冲目标上限为 8 MiB，pending packet 上限为 64；
这是上游的容量设置，不能解读为启动时必然预分配或常驻 8 MiB。保留上游修复，
其实际 NE 物理工作集影响需要同配置真机测量。

后续同配置对比 `phys_footprint` 峰值与闲置值、Go 堆/GC、Goroutines、吞吐和延迟，
验证 Provider、SS/Snell/VLESS/Hysteria2、解锁脚本、排行榜、锁屏及 5G→4G 弱网恢复。
持续运行 48～72 小时，确认重连后的生命周期指标回到基线及没有功能或性能回退。

生命周期清理与控制面行为见 [NE 生命周期记录](ne-runtime-lifecycle.md)；
当前补丁及回退方式见 [第三方补丁档案](../MobileCore/THIRD_PARTY_PATCHES.md)。
