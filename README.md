# Cora

基于 [mihomo](https://github.com/MetaCubeX/mihomo) 内核的 iOS 代理客户端，SwiftUI + MVVM，个人自签测试。

当前版本：**1.0.5**

详细路线见 [PLAN.md](PLAN.md)。

## 构建

工程用 [XcodeGen](https://github.com/yonsm/XcodeGen) 管理，`.xcodeproj` 不入库。开发机为 Windows，靠 GitHub Actions（macos-26 / Xcode 26）构建未签名 ipa。

- 推送到 `main` 或手动触发 `Build unsigned IPA` 工作流。
- Actions 同时产出标准版与 `CoraLegacy`（iOS 16.4+）的普通 IPA、TrollStore IPA。
- 用自有 Apple 开发者证书自行签名后安装（工程内不含任何证书/描述文件/Secrets）。

本地有 Mac 时，先准备 mihomo 框架并生成工程：

```bash
brew install xcodegen
bash scripts/prepare-xcode.sh
open Cora.xcodeproj
```

首次构建前，在 Xcode 的 `Signing & Capabilities` 中为 `Cora`、
`CoraTunnel`、`CoraControl` 三个标准 target 选择同一个开发者团队。若构建
Legacy，则为 `CoraLegacy`、`CoraTunnelLegacy` 选择同一团队。
工程使用自动签名，不需要手动创建或下载 provisioning profile；App Group
`group.com.miclash.app` 和三个 Bundle ID 仍需属于该团队。

`prepare-xcode.sh` 要求 macOS、Xcode 和 XcodeGen。首次构建内核时还需要 Go 1.25.4，
脚本会下载 Go 依赖，并生成标准版 `Vendor/Mihomo.xcframework` 与 Legacy
`VendorLegacy/Mihomo.xcframework`；后续直接复用。MobileCore 或依赖变化后运行：

```bash
bash scripts/prepare-xcode.sh --rebuild-core
```

## 内部 TestFlight

工程的 `Cora` scheme 使用 `InternalTestFlight` Release 配置进行 Archive：

1. 在 App Store Connect 创建与 `com.miclash.app` 对应的 App 记录。
2. 在 Xcode 选择 `Any iOS Device (arm64)`，执行 `Product > Archive`。
3. 在 Organizer 中选择 `Distribute App`，然后选择 `TestFlight Internal Only` 上传。
4. 每次上传使用新的 Build Number，并在 App Store Connect 添加内部测试成员。

内部 TestFlight 构建只能分配给 App Store Connect 团队内的测试人员，不能转为外部测试
或正式发布。若之后需要外部 TestFlight，应重新上传未标记为 Internal Only 的构建。

## iOS 16.4 Legacy

`CoraLegacy` 是面向 iOS 16.4+ 的独立 Scheme，和标准版共用配置、VPN 描述文件、
Bundle ID 与核心代码，二者为替换安装关系，不能同时安装。Legacy 不包含 iOS 18 的
控制中心磁贴；VPN 启停、订阅、策略、测速、记录、日志、外部检测脚本和 Connect On
Demand 自动连接均保留。

GitHub Actions 产物名称如下：

- `Cora-unsigned-ipa`：标准普通 IPA，主 App / Tunnel 最低 iOS 17。
- `Cora-trollstore-ipa`：标准 TrollStore IPA，不含 iOS 18 控制中心磁贴。
- `CoraLegacy-unsigned-ipa`：iOS 16.4+ 普通 IPA。
- `CoraLegacy-trollstore-ipa`：iOS 16.4+ TrollStore IPA。

Legacy 的 mihomo 框架仍使用 ARM64 AES-GCM 加速，要求 A12 或更新芯片；iPhone SE
第三代的 A15 满足此前提。A11 及更早设备不在该加速构建的支持范围内。

## 标识

| 项 | 值 |
|---|---|
| 主 App | `com.miclash.app` |
| NE 扩展 | `com.miclash.app.tunnel` |
| App Group | `group.com.miclash.app` |

## 功能概览

- 总览、策略、节点、记录、设置五个页面；策略组与节点组分开展示并共享选择状态。
- 策略与节点页支持列表/网格模式，网格默认开启；卡片显示最终节点和共享延迟，支持测试本页当前节点、展开分组或单个节点测速。
- 订阅支持远程 Provider 刷新，支持自定义订阅 UA。
- 记录页提供策略和主机流量聚合，并可进入对应的分页连接记录。
- 记录页支持活动连接详情、关闭连接、日志和分页历史。
- 记录使用 App Group SQLite 限制为最近 7 天、最多 20,000 条、约 50 MB；VPN 断开后清空本次会话。
- 支持 GEO/ASN、隧道路由、STUN 直连拦截、混合代理端口和内核诊断；开发者模式默认关闭，开启后才按 5 秒采样并限制为 256KB，可在设置中分析、复制或清理。

## Network Extension 内存策略

开发者内存诊断的压力事件有 20 秒冷却，避免重复 GC 和同步写盘放大内存压力。
连接历史在 Network Extension 中使用有界活动快照（8 秒）和关闭队列（2 秒）分离
处理，SQLite 的过期/WAL 维护每 60 秒执行一次，并使用文件临时存储和小页面缓存。
总览只走 totals-only 连接 IPC；记录页打开时才读取完整活动连接，从而减少 App 与
Network Extension 的重复 JSON 分配。连接历史仍限制最近 7 天、20,000 条和约 50 MB，
不会因清理失败影响 VPN 转发。

## 当前状态

项目已完成主要功能和 CI 无签名 IPA 构建流程。后续以真机签名测试、证书更新和兼容性修复为主。
