# Cora 实施方案

基于 mihomo 内核的 iOS 代理客户端，SwiftUI + MVVM，个人自签自用。

## 约束
- 开发机为 Windows，无本地 Mac；全程靠 GitHub Actions（macos-15 / Xcode 16）构建。
- CI 只产出**未签名 ipa**；签名由用户用自有开发者证书自理，工程内不放证书/描述文件/Secrets。
- 工程用 XcodeGen（`project.yml` 生成 `.xcodeproj`，不入库）。
- 主 App 与 Packet Tunnel 部署目标 **iOS 17.0**；Control Widget 扩展保持 iOS 18.0。

## 标识
| 项 | 值 |
|---|---|
| 主 App | `com.miclash.app` |
| NE 扩展 | `com.miclash.app.tunnel` |
| App Group | `group.com.miclash.app` |

## 架构
三个产物：
- **Cora**：主 App，SwiftUI + MVVM，UI 与控制面。
- **CoraTunnel**：`NEPacketTunnelProvider` 扩展，接管系统流量，宿主 mihomo 核心。
- **MihomoCore.xcframework**：mihomo 经 `gomobile bind` 薄封装编出，被 NE 链接。

进程间数据流：
- 隧道启停走 `NETunnelProviderManager`；配置、状态、节点/分组、测延迟、流量、日志和连接管理统一使用带协议版本与超时的命令协议，普通签名走 `sendProviderMessage`，TrollStore 包走共享目录文件 IPC。
- App Group 共享容器承载配置与日志文件；不暴露 mihomo external-controller 或 WebUI，App 运行态控制统一走 Network Extension IPC。

`CoreStateManager`（全局单例 `ObservableObject`）= VPN 控制 + API 客户端封装，向所有 ViewModel 供状态。

## 分阶段

### Phase 0 — 地基（进行中）
XcodeGen 双 target + entitlements；主 App 一个连接开关（`NETunnelProviderManager` 启停）；NE 空壳把隧道拉起；CI 出未签名 ipa。
验证：用证书签名装机 → 切开关 → 系统 VPN 图标出现、NE 被拉起。

### Phase 1 — mihomo gomobile 化
`MobileCore/mobile.go` 薄封装导出 `Setup/Start/Stop/Version/Reload`；CI 加 `gomobile bind -target=ios`；App 调 `Version()` 证明核心能加载，暂不接 tun。

### Phase 2 — tun 接管流量
NE 内 `tun.enable=true`，取真实 utun fd 交 mihomo（`stack=gvisor`——iOS NE 里 system 栈 TCP 不通）；`NEPacketTunnelNetworkSettings` 用 **8 段子网路由而非 0.0.0.0/0** 防黑洞断网；DNS 指向 fake-ip。NE 内存限额 ~50MB：Go 侧 `SetMemoryLimit(35MiB)` + `SetGCPercent(50)` 压堆峰值，内存压力事件触发 `ForceGC()` 还页，热重载后延迟 15s `FreeOSMemory()`。

### Phase 3 — UI（MVVM + ShipSwift）
`CoreStateManager` 接 mihomo API。四页：Dashboard（SWChart 流量图）/ Proxies（分组/测延迟/切换）/ Profiles（导入/订阅）/ Settings。ShipSwift 经 MCP 或 `npx skills add` 把自包含组件拷进 `UI/ShipSwift/`。

### Phase 4 — 打磨
订阅更新（下载→解析→存 App Group→热重载）、日志持久化、Profile 管理、后台保活（`NEOnDemandRule`+重连）、前后台状态同步。

## ShipSwift 备注
不是 SPM 依赖，而是复制粘贴式 + MCP 配方库（`signerlabs/ShipSwift`，MIT，原组件要求 iOS 18+）。当前 iOS 17 主目标不集成其受限组件。
