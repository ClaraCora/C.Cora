# Cora — meow-rs iOS 18 分支

此分支将标准 Cora App 和 Packet Tunnel 切换到 Rust meow-rs，最低 **iOS 18**。
固定内核提交 `fa7a7d6dc94e886ae0bc43eeb0227082ae5bf2e6`，Cargo.lock 随源码保存。
App 版本保持 1.0.7，CI 构建号使用运行编号与重试编号。

## 构建

需要 macOS、Xcode 26.4.1、Rust 1.95.0、CMake、XcodeGen。
Apple Rust targets 为 `aarch64-apple-ios` 与 `aarch64-apple-ios-sim`。

```sh
bash scripts/prepare-xcode.sh --rebuild-core
xcodebuild -project Cora.xcodeproj -scheme Cora -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
bash scripts/verify-meow-app.sh build/Build/Products/Release-iphoneos/Cora.app
```

本地签名时，在 Xcode 给 Cora、CoraTunnel、CoraControl 选择同一开发团队，确认 Network Extension 与 App Group 权限。
CI 只生成普通未签名 `Cora-unsigned.ipa`，需使用自己的证书签名安装。
`main`、`meow-rs` push 以及 workflow_dispatch 可触发本分支工作流；成功后仅发布一个 IPA 和 SHA-256 校验文件。
不构建 Legacy 或 TrollStore IPA。旧 Go MobileCore、旧框架目录与 Swift 回退参考保留，但未加入新 targets。

## 配置与兼容

- 订阅、本地 YAML 和原 Provider 文件按原文保存；Rust 仅读取它们并生成独立运行副本。
- packetFlow 回调连接 Rust lwIP，不扫描 utun fd，不再链接 Mihomo 或 Go。
- 运行副本固定 iOS DNS/fake-IP、内部 mixed listener 和受认证 loopback controller；不向 App 暴露 controller 凭据。
- HTTP Provider 使用按配置 ID 与内容摘要隔离的 Rust 缓存。inline Proxy Provider 仅在独立运行目录物化为文件，原 payload 与 use 引用保留。
- 不支持的源配置字段带 YAML 路径报错；启动失败保留上次成功 source/settings/runtime 快照，系统重连使用成功快照。
- GEO 使用 geoip.metadb（MMDB）、GeoSite.dat、ASN.mmdb，下载后先校验再原子替换，下次 VPN 连接生效。缺数据库不能静默删除规则。
- 不提供 App 内前置代理或链式代理分组。WindowsConfigTool 不属于此次迁移，也不加入本分支提交。

## 当前功能差异

保留策略组、Provider、规则、模式、测速、日志、统计、TCP 连接历史和系统重连接口。
meow-rs 没有 UDP 连接明细，页面明确显示不可用；总流量包含 UDP，但历史与按连接聚合排行不能代表完整 UDP 用量。
PO0、Cora 检测脚本请求、特殊探测与手动 Go GC 不可用；旧设置不删除，相关入口禁用或返回明确错误。
原 TUN 覆写、direct-nameserver、respect-rules、DoH H3 优先、QUIC 嗅探与旧 GEO 加载器等非等价选项保留并明确标为不可用。
Rust RSS 与 NE phys_footprint 分开显示。内存诊断仅开发者模式采样，文件和日志队列均有上限。

## 验证

```sh
cargo +1.95.0 test --locked --manifest-path MobileCoreRust/cora-config/Cargo.toml
cargo +1.95.0 test --locked --manifest-path MobileCoreRust/meow-ios-ffi/Cargo.toml --lib -- --test-threads=1
python3 scripts/test-meow-migration.py
python3 scripts/test-ipa-release.py
bash scripts/test-connection-history.sh
bash scripts/test-ipc-response-cache.sh
bash scripts/test-ipc-control-scheduler.sh
bash scripts/test-proxy-controller.sh
bash scripts/test-kernel-memory.sh
bash scripts/test-core-compatibility.sh
```

Swift 脚本、Apple slices 与 IPA 门禁须在 macOS 上执行。主机 Rust 测试通过不等于 iOS 构建或真机验证通过。
迁移验收细则见 docs/meow-rs-migration.md；未完成真机验收的构建只能视为测试构建。
第三方来源、MIT 许可证与版本固定信息见 MobileCoreRust/UPSTREAM.md。
