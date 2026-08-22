# Cora 实施方案

基于 mihomo 内核的 iOS 代理客户端，SwiftUI + MVVM，面向个人自签测试。

## 约束
- 开发机为 Windows，无本地 Mac；全程靠 GitHub Actions（macos-26 / Xcode 26）构建。
- CI 只产出**未签名 ipa**；签名由用户用自有开发者证书自理，工程内不放证书/描述文件/Secrets。
- 工程用 XcodeGen（`project.yml` 生成 `.xcodeproj`，不入库）。
- 主 App 与 Packet Tunnel 部署目标 **iOS 17.0**；Control Widget 扩展保持 iOS 18.0。

## 标识
| 项 | 值 |
|---|---|
| 主 App | `com.miclash.app` |
| NE 扩展 | `com.miclash.app.tunnel` |
| App Group | `group.com.miclash.app` |

## 当前架构
三个产物：
- **Cora**：主 App，SwiftUI + MVVM，UI 与控制面。
- **CoraTunnel**：`NEPacketTunnelProvider` 扩展，接管系统流量，宿主 mihomo 核心。
- **MihomoCore.xcframework**：mihomo 经 `gomobile bind` 薄封装编出，被 NE 链接。

进程间数据流：
- 隧道启停走 `NETunnelProviderManager`；配置、状态、节点/分组、测延迟、流量、日志和连接管理统一使用带协议版本与超时的命令协议，普通签名走 `sendProviderMessage`，TrollStore 包走共享目录文件 IPC。
- App Group 共享容器承载配置与日志文件；不暴露 mihomo external-controller 或 WebUI，App 运行态控制统一走 Network Extension IPC。

`CoreStateManager`（全局单例 `ObservableObject`）负责 VPN 状态、版本化 IPC 和核心状态；
`ProxyController` 负责策略组与节点；`ConnectionsController` 负责记录页的活动连接、
聚合统计和分页历史。

## 已完成功能

- Cora 总览、策略、节点、记录、设置五个页面，支持浅色/深色模式和系统材质背景。
- 策略组与节点组分开展示并共享选择状态；两页支持列表/网格布局，网格默认开启，分组支持渐变图案、长按测速和全部随机图案。
- 网格分组展开为基于原卡片位置的局部弹层，点击弹层外部关闭。
- 订阅配置、远程 Provider 刷新、节点选择、分组/单节点延迟测试和延迟设置。
- 记录页支持活动连接详情、结束连接、策略/主机流量聚合、日志切换。
- 连接详情由 Network Extension 写入 App Group SQLite；单次 VPN 会话最多 20,000 条、
  最近 7 天且数据库不超过约 50 MB，App 被划掉后 NE 仍可继续写入。
- VPN 断开时清空本次会话的记录、统计和本地缓存，下一次连接从零开始。
- GEO/ASN、STUN 直连拦截、隧道路由、混合代理端口和内核诊断设置。

## 构建与发布

项目当前已进入收尾状态。后续只建议做兼容性修复、证书更新和真机回归，不再扩大功能范围。

## ShipSwift 备注
不是 SPM 依赖，而是复制粘贴式 + MCP 配方库（`signerlabs/ShipSwift`，MIT，原组件要求 iOS 18+）。当前 iOS 17 主目标不集成其受限组件。
