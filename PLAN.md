# Cora 实施方案

基于 mihomo 内核的 iOS 代理客户端，SwiftUI + MVVM，面向个人自签测试。

## 约束
- 开发机为 Windows，无本地 Mac；全程靠 GitHub Actions（macos-26 / Xcode 26）构建。
- CI 只产出**未签名 ipa**；签名由用户用自有开发者证书自理，工程内不放证书/描述文件/Secrets。
- 工程用 XcodeGen（`project.yml` 生成 `.xcodeproj`，不入库）。
- 标准主 App 与 Packet Tunnel 部署目标 **iOS 17.0**；Control Widget 扩展保持 iOS 18.0。
- `CoraLegacy` / `CoraTunnelLegacy` 独立部署目标为 **iOS 16.4**，不嵌入 Control Widget；
  两个构建共享 Bundle ID 和业务代码，为替换安装关系。

## 标识
| 项 | 值 |
|---|---|
| 主 App | `com.miclash.app` |
| NE 扩展 | `com.miclash.app.tunnel` |
| App Group | `group.com.miclash.app` |

## 当前架构
标准版的三个产物：
- **Cora**：主 App，SwiftUI + MVVM，UI 与控制面。
- **CoraTunnel**：`NEPacketTunnelProvider` 扩展，接管系统流量，宿主 mihomo 核心。
- **MihomoCore.xcframework**：mihomo 经 `gomobile bind` 薄封装编出，被 NE 链接。

Legacy 使用独立的 `VendorLegacy/Mihomo.xcframework`，以 iOS 16.4 SDK 下限构建，避免
改变标准版框架的 iOS 17 下限。两套框架都采用 A12+ 的 ARM64 AES-GCM 加速；Legacy 的
支持设备应为 A12 或更新机型。

进程间数据流：
- 隧道启停走 `NETunnelProviderManager`；配置、状态、节点/分组、测延迟、流量、日志和连接管理统一使用带协议版本与超时的命令协议，普通签名走 `sendProviderMessage`，TrollStore 包走共享目录文件 IPC。
- App Group 共享容器承载配置与日志文件；不暴露 mihomo external-controller 或 WebUI，App 运行态控制统一走 Network Extension IPC。

`CoreStateManager`（全局单例 `ObservableObject`）负责 VPN 状态、版本化 IPC 和核心状态；
`ProxyController` 负责策略组与节点；`ConnectionsController` 负责记录页的活动连接、
聚合统计和分页历史。

## 已完成功能

- Cora 总览、策略、节点、记录、设置五个页面，支持浅色/深色模式和系统材质背景。
- 策略组与节点组分开展示并共享选择状态；两页支持列表/网格布局，网格默认开启，卡片显示最终节点及共享延迟，并支持本页当前节点批量测速、分组/单节点测速、渐变图案和全部随机图案。
- 网格分组展开为基于原卡片位置的局部弹层，点击弹层外部关闭。
- 订阅配置、远程 Provider 刷新、节点选择、分组/单节点延迟测试和延迟设置。
- 记录页支持活动连接详情、结束连接、策略/主机流量聚合、日志切换。
- 连接详情由 Network Extension 写入 App Group SQLite；单次 VPN 会话最多 20,000 条、
  最近 7 天且数据库不超过约 50 MB，App 被划掉后 NE 仍可继续写入。
- VPN 断开时清空本次会话的记录、统计和本地缓存，下一次连接从零开始。
- GEO/ASN、STUN 直连拦截、隧道路由、混合代理端口和内核诊断设置。开发者内存诊断默认关闭，开启后由 NE 进行 5 秒限量采样，App 侧分析 Go 堆、连接、Provider 与原生内存高水位。

## 构建与发布

项目当前已进入收尾状态。后续只建议做兼容性修复、证书更新和真机回归，不再扩大功能范围。

## ShipSwift 备注
不是 SPM 依赖，而是复制粘贴式 + MCP 配方库（`signerlabs/ShipSwift`，MIT，原组件要求 iOS 18+）。当前 iOS 17 主目标不集成其受限组件。

## 延迟测速内存边界（阶段 1-2）

为降低高流量、多节点测速时 Network Extension 的瞬时内存峰值，延迟测试采用
有界执行模型：Wi-Fi 批量测速最多 4 个 worker、蜂窝批量测速最多 2 个 worker；
Wi-Fi 分组测速最多 8 个 worker、蜂窝分组测速最多 4 个 worker。所有单节点、
分组和批量 `URLTest` 共享最多 8 个并发槽位，避免多个入口同时放大 mihomo、
gVisor 和传输缓冲区。

每次测速会话都注册可取消的生命周期。新的测速或配置写入会取消并等待旧会话
完全退出，避免遗留 goroutine、槽位或网络任务。批量/分组测速按目标数量和
worker 数估算总时长，最长 3 分钟；达到上限时返回已完成结果，未完成节点以
`0`（未测/超时）表示，不保留上一次结果。单节点测速也使用同一会话和槽位，
配置重载或新测试不会留下不可回收的任务。

Swift IPC 对分组和批量测速使用蜂窝场景的保守超时估算，并设置约 190 秒上限，
与核心的 3 分钟安全边界匹配，同时保留 IPC 往返余量。

## NE 内存稳定性（阶段 1-6）

- 开发者模式的 memory-pressure 诊断事件采用 20 秒冷却；冷却期间不重复
  读取 Go 全量统计、同步写盘或强制回收，避免诊断本身形成 GC 风暴。
- 连接历史在 NE 内拆分为两个有界任务：活动连接快照每 8 秒一次，关闭队列
  每 2 秒排空；SQLite 的保留期限、20,000 行和约 50 MiB 上限仍保持不变。
- SQLite 的过期清理、WAL checkpoint 和增量回收改为每 60 秒维护一次；NE
  使用文件临时存储和约 512 KiB 页面缓存，减少聚合查询对 phys_footprint 的影响。
- App 总览只请求 totals-only 连接响应；只有记录页可见时才请求最多 200 条完整
  活动连接。内核总流量由该单一连接轮询更新，不再由 KernelController 重复请求。
- 移除 Cora 自有的 Snell 蜂窝普通 TCP 名单、设置页和 mihomo 专用补丁，恢复
  原生 Snell/TFO 行为，减少热路径状态和维护面。

验证重点：开发者模式压力事件的 `numForcedGC` 不再在数秒内暴增；空闲、测速、
App 后台、CarPlay 与 Wi-Fi/蜂窝切换时，NE phys_footprint 应在回落后保持稳定，
且连接记录、累计流量和分页详情不丢失。
