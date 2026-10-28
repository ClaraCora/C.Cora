# meow-rs iOS 18 迁移与验收

本文件描述 `meow-rs` 分支的实现边界与验收步骤；不是已完成真机验收的声明。
主 App 版本保持 1.0.7，构建号由 CI 的 run number 和 run attempt 生成。

## 工程边界

- 仅 `Cora`、`CoraTunnel`、`CoraControl`，最低系统均为 iOS 18.0。
- 引擎和 lwIP 固定 `fa7a7d6dc94e886ae0bc43eeb0227082ae5bf2e6`，官方 FFI 来源及许可证见 `MobileCoreRust/UPSTREAM.md`。
- `MobileCoreRust/rust-toolchain.toml` 固定 Rust 1.95.0；两个 Rust crate 均保留 Cargo.lock，CI 使用 `--locked`。
- 只生成设备 arm64 与模拟器 arm64 的 MeowCore.xcframework；主 App 和 Tunnel 静态链接。
- 只打包 `Cora-unsigned.ipa`。Legacy、TrollStore、Go/gomobile 不参与构建或发布。
- 旧 Go 源码、旧框架和 `MobileCore/SwiftReference/` 仅供回退参考。以前的 Legacy targets 共享 App/Tunnel 源码，没有单独源码树。
- `WindowsConfigTool/` 保持未跟踪，不属于本分支提交。

## 数据与生命周期

订阅存储、配置编辑器和 Provider 原文仍保存用户的原始内容。运行时处理使用以下独立文件：

| 文件/目录 | 用途 |
| --- | --- |
| `runtime-<UUID>.yaml` | 当前 NE 会话运行副本，含随机 loopback controller 和 secret |
| `meow-cache/<profile-digest>/` | Rust HTTP Provider 独立缓存，不复用旧 Go 缓存文件 |
| `meow-inline/<profile-digest>/` | inline Proxy Provider 的运行副本物化文件，保留原 `use` 引用 |
| `meow-last-success.json` | 一次原子提交的 source、settings 和 runtime 成功快照 |
| `logs/meow-tunnel.log` | 有大小上限的 Rust 文本日志 |
| `memory-diagnostic*.ndjson` | 仅开发者模式开启的 Rust v2 诊断 |

Profile digest 包含订阅 ID 和源内容，避免不同配置的同名 Provider 互相污染。
运行副本写入前先检查字段、Provider 路径、端口和配置结构；引擎与 packetFlow 都启动后才提交成功快照。
修改配置失败时保留旧快照；App 的重连回滚和系统无 options 重连均读取最后成功的 source/settings。
首次从旧 Go 核心迁移时，允许只读现有 `config.yaml` / `settings.json`，不覆盖它们。

数据路径：`NEPacketTunnelFlow → meow_tun_ingest → Rust lwIP → 本机 mixed listener → 引擎`，输出经 C 回调写回 packetFlow。
停止顺序固定为停止读包、`meow_tun_stop_blocking`、释放 Swift callback context、停止 engine。
`NWPathMonitor` 上报网络类型；路径恢复先执行 FFI health probe，失败后才受控重启，并设置冷却时间。

## 兼容策略

- 保留原 IPC 命令及主要 JSON 字段，由 `CoraCoreAdapter` 转换为 FFI 或经过认证的 loopback API。
- 同名节点按 Provider/策略组来源解析；无法唯一确定时返回歧义错误。
- 原配置中无法等价执行的字段返回 YAML 路径错误，不使用相近字段替代。
- 旧 Cora 专用设置保留；PO0、脚本请求、STUN 特定拦截、旧 TUN/DNS 非等价覆写等禁用或明确提示不可用。
- 源 YAML 的 `geodata-mode: true` 和 `unified-delay: true` 返回具体字段路径错误；不替换 GeoIP 格式，也不把统一延迟曲解为重写策略组测速 URL。旧 App 偏好保留但不可用。
- 不加入 `proxyChain` 或链式代理界面。
- UDP 参与总流量计数，但没有连接明细；连接历史、连接聚合排行只代表能记录的 TCP。
- Rust RSS 与 NE `phys_footprint` 分开显示，不以二进制大小推断内存占用。
- GEO/ASN 在主 App 下载到临时文件、校验后原子替换；已运行引擎不热加载，下次连接读取。
- 不允许通过关闭 GEO 静默删除 GEO 规则。依赖数据库但缺文件或校验失败时拒绝启动。
- HTTP Provider 的下载、周期刷新、失败回滚由固定版本 meow-rs 管理；App 不把运行覆写写回原文。

## 自动验证

可在 Windows 运行：

```powershell
cargo +1.95.0 test --locked --manifest-path MobileCoreRust/cora-config/Cargo.toml
cargo +1.95.0 test --locked --manifest-path MobileCoreRust/meow-ios-ffi/Cargo.toml --lib -- --test-threads=1
python scripts/test-meow-migration.py
python scripts/test-ipa-release.py
```

完整 FFI 主机测试需要本机 C/C++ 工具链、CMake、libclang；Windows 还需 NASM。
测试没有外部代理账号，仅验证主机可覆盖的配置、生命周期、队列、回调和本机数据路径。
FFI 测试中涉及进程级运行时和 home 状态的端到端生命周期用例会在独立子进程运行，避免被其他测试污染；子进程 120 秒无响应会被终止，并输出最后到达的阶段标记。STUN 回环测试绑定第二个回环地址时使用有限重试；系统不支持该地址时会输出提示并跳过依赖双地址的用例。CI 的 FFI 步骤另有 10 分钟总超时，并用 `--nocapture` 保留诊断输出。

macOS 再执行 README 中全部 Swift 回归脚本、XcodeGen、两个 Apple Rust slices 和标准 App 构建。
`scripts/verify-meow-app.sh` 检查三个 bundle 的 iOS 18 下限、纯 arm64、两个扩展、系统 SQLite、旧 Go 框架/符号及 Tunnel 50 MiB 磁盘大小上限。
发布脚本用离线 fake gh 测试，确保缺 IPA 或上传失败不会发布不完整预发布版。

### 2026-10-28 本地主机验证记录

- Windows / Rust 1.95.0：`cora-config` 24 项、FFI 140 项测试通过。
- 工程迁移门禁 6 项、离线发布脚本测试 3 项通过；两个 crate 的 rustfmt 检查通过。
- 覆盖运行副本实际启动、内部 SOCKS 握手、packet callbacks、health probe、本机 HTTP Provider 请求头与刷新失败缓存回滚。
- 当前环境没有 Swift/Xcode，尚未执行 Swift 回归、XcodeGen、Apple slices、IPA 构建或 iPhone 测试。这些仍是合并/发布前的验收项，不能用 Windows 测试结果替代。

## 真机验收表（待执行）

每项记录设备、iOS 版本、配置 SHA-256、构建号、网络类型、步骤、结果和日志。最低设备必须为 iOS 18，iOS 17 不再验收。

| 范围 | 必测场景 |
| --- | --- |
| 协议 | SS、VLESS、Trojan、Hysteria2、VMess、AnyTLS；TCP/UDP 分别验证 |
| 节点来源 | 顶层、HTTP/file/inline Provider、完整 Mihomo 配置作为节点来源 |
| 分流 | Selector、URL-Test、Fallback、GLOBAL；Rule/Direct/Global 模式切换 |
| 网络 | HTTP、HTTPS、TCP、UDP、QUIC；IPv4/IPv6，fake-IP、DoH、UDP DNS |
| 生命周期 | 开关 VPN、后台/唤醒、Wi-Fi/蜂窝切换、主 App 被划掉后系统自动重连 |
| 资源 | Provider 刷新成功/失败、节点删除/改名、同名不同来源、GEO/ASN 更新后重连 |
| 失败恢复 | YAML 错误、缺 GEO、监听端口冲突、启动失败、应用并重连失败后的旧快照恢复 |
| 控制面 | 节点/组/批量测速、选择节点、规则内容、日志增量读取、统计、TCP 连接历史 |
| 稳定性 | 至少 1 小时；发布前再完成 24 小时，包含长时间蜂窝和直连国内 App |

验收前后对原订阅、本地 YAML 与导入的 Provider 原文分别计算 SHA-256，必须不变。
对比源策略组成员、规则顺序及 DIRECT 行为，确认运行覆写没有污染源文件。
使用同一设备、相同流量与配置，与旧 Mihomo 构建对比 `phys_footprint`、CPU、断流/重连次数；主机单测不能替代这一步。
在验收完成前，构建只能标为测试版，不宣称所有协议组合或内存改善已验证。
