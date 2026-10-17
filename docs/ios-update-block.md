# iOS 更新检查拦截

功能默认关闭。设置 → 隧道与隐私下方 → iOS 更新拦截，可保存开关、查看实际拒绝计数、
刷新及清空本次统计。App 设置与 NE 确认后的生效状态分别显示；同步失败可重试。
没有读取到统计时显示未读取，读取成功但没有命中时明确显示尚未观察到请求。

## 范围与依据

仅精确匹配 `gdmf.apple.com`、`mesu.apple.com`，忽略大小写与末尾 DNS 圆点。
依据 [Apple 企业网络服务列表](https://support.apple.com/en-us/101555) 中的更新目录用途。
没有封锁整个 Apple 域名、下载 CDN、共享 IP、额外组件目录或不相关子域名。

经过 Mihomo DNS Service 的查询在 Hosts、缓存、Fake-IP 和上游请求之前返回 REFUSED，
覆盖 A、AAAA、HTTPS/SVCB 等类型。连接层检查已知原始域名、DNS 还原域名和已有嗅探
得到的域名，在 SpecialProxy、规则匹配与全局/直连模式前结束匹配连接；不创建拒绝连接
的长驻 tracker/UDP 会话。开启时仅关闭当前可识别的两个域名连接，不重启 VPN。

沿用当前接管、IPv6 和嗅探设置，未知域名的纯 IP 流量保持原行为。
[Apple 流量接管说明](https://developer.apple.com/documentation/networkextension/routing-your-vpn-network-traffic)
描述了系统 VPN 路由及例外；即使启用全流量接管，也不应宣称覆盖所有系统请求。

系统缓存仍可能显示“有新版本”，Cora 不能清除系统更新缓存或已下载更新，不能保证
“无法连接”的系统文案。VPN 停止、流量绕行、已下载的更新无法由此功能阻止安装。
目录服务也可能兼用于部分系统资源查询，需要真机检查附带影响。

## 生命周期、统计与开销

- 独立、默认关闭的配置写入受保护的共享文件；未授权 App Group 时，经启动 options/IPC
  写入 NE 自己的受保护缓存。系统无 options 启动也读取这份配置，覆盖旧 settings.json。
- 启动在 ApplyConfig 恢复转发前安装策略；失败回滚和停止清理运行状态。
  开关热应用使用现有 runtimeQueue，保留当前会话计数。
  App 在连接中保存的待同步设置，在收到已连接事件时再确认应用一次，避免错过 NE 启动读取窗口；
  这是单次事件同步，不增加轮询或 NE 定时器。
- `configureIOSUpdateBlock`、`iosUpdateBlockStatus`、`resetIOSUpdateBlockStats` 复用轻查询
  调度和 Data 响应。响应带 session、configurationID、configurationGeneration 和 revision；
  App 配置版本、连接 epoch 及响应 revision 防止旧查询覆盖新开关/清空操作。
- 两个域名各保留 DNS 拒绝、连接拒绝次数与最后时间，没有请求日志、域名/IP 列表或
  NE 后台定时器。计数是域名请求数，不能解释为升级次数或特定系统进程。
- 子页面只在可见且前台时每 3 秒读取统计；离开或进入后台立即取消轮询。
  设置入口只在出现/连接状态变化时读取一次。刷新不会探测 Apple，清空不会修改开关。
- 当前路由覆盖信息来自 NE 本次成功启动的协议参数和 IPv6 设置，不使用 App 尚未生效
  的编辑值。没有调整数据面并发、GC、gVisor、IPC 缓存或现有功能。

## 本地验证与后续验收

Windows 使用 Go 1.25.5，CI 仍固定 1.25.4；测试使用隔离的补丁源码，不修改全局模块缓存。

已完成：

- Mihomo policy/DNS/tunnel 默认和低内存测试；专项 30 次循环。
- MobileCore 默认及 `with_gvisor,with_low_memory` 测试，包含针对性关闭和启动回滚。
- 上述受影响包与 MobileCore 的默认、低内存 vet。
- 新增匹配路径的零分配测试；Windows amd64 微基准为 0 B/op、0 allocs/op，
  关闭约 1.2ns、开启后的普通域名约 4.9ns、命中约 16ns。仅表示本机匹配函数开销，
  不能代替 iOS NE 物理内存或吞吐实测。
- Darwin arm64 的 MobileCore 测试二进制交叉编译，以及 Darwin Objective-C 绑定生成；
  确认三个新 Data API 的名称与 NSData 可空声明。

CI 新增 Swift 配置持久化、同步失败、清空、旧轮询与会话切换、实际覆盖状态测试，
以及 Mihomo/封装层专项 race 检查。Windows 无法执行这些 macOS/Swift 测试、完整
XCFramework/Xcode 构建或 iOS 真机测试；此处不把交叉编译当作已运行通过。

真机按以下顺序验收：

1. 打开 VPN 后开启功能，确认状态已启用；前往系统“软件更新”再返回查看真实拒绝记录。
   若请求未经过隧道或系统只显示缓存，允许没有命中，不能据此伪造成功。
2. 覆盖规则、全局、直连，已有 DNS/Fake-IP 缓存及连接；关闭后验证新请求恢复正常。
3. 刷新不产生探测，清空仅清统计。杀掉 App、锁屏后再次检查，会话未结束时继续累积。
   真正新建 VPN 隧道后统计归零，设置继续保存。
4. 覆盖 Wi-Fi/蜂窝、IPv6、弱网切换、VPN 自动启动；检查 App Store、iCloud、推送、
   正常浏览与解锁检测，并测量 NE 物理内存、吞吐与延迟是否有明显变化。

版本绑定补丁、源码及补丁哈希、应用顺序由 `prepare-ios-mihomo.sh` 校验。
完整补丁链验证结果为 18 个补丁、63 项 SHA-256 及脚本语法检查。
