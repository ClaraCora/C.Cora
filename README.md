# MiClash

基于 [mihomo](https://github.com/MetaCubeX/mihomo) 内核的 iOS 代理客户端，SwiftUI + MVVM，个人自签自用。

详细路线见 [PLAN.md](PLAN.md)。

## 构建

工程用 [XcodeGen](https://github.com/yonsm/XcodeGen) 管理，`.xcodeproj` 不入库。开发机为 Windows，靠 GitHub Actions（macos-26 / Xcode 26）构建未签名 ipa。

- 推送到 `main` 或手动触发 `Build unsigned IPA` 工作流。
- 产物 `MiClash-unsigned-ipa` 在 Actions artifact 中下载。
- 用自有 Apple 开发者证书自行签名后安装（工程内不含任何证书/描述文件/Secrets）。

本地有 Mac 时，先准备 mihomo 框架并生成工程：

```bash
brew install xcodegen
bash scripts/prepare-xcode.sh
open MiClash.xcodeproj
```

首次构建前，在 Xcode 的 `Signing & Capabilities` 中为 `MiClash`、
`MiClashTunnel`、`MiClashControl` 三个 target 选择同一个开发者团队。
工程使用自动签名，不需要手动创建或下载 provisioning profile；App Group
`group.com.miclash.app` 和三个 Bundle ID 仍需属于该团队。

`prepare-xcode.sh` 要求 macOS、Xcode 和 XcodeGen。首次构建内核时还需要 Go 1.25.4，
脚本会下载 Go 依赖并生成 `Vendor/Mihomo.xcframework`；后续直接复用。MobileCore 或依赖变化后运行：

```bash
bash scripts/prepare-xcode.sh --rebuild-core
```

## 内部 TestFlight

工程的 `MiClash` scheme 使用 `InternalTestFlight` Release 配置进行 Archive：

1. 在 App Store Connect 创建与 `com.miclash.app` 对应的 App 记录。
2. 在 Xcode 选择 `Any iOS Device (arm64)`，执行 `Product > Archive`。
3. 在 Organizer 中选择 `Distribute App`，然后选择 `TestFlight Internal Only` 上传。
4. 每次上传使用新的 Build Number，并在 App Store Connect 添加内部测试成员。

内部 TestFlight 构建只能分配给 App Store Connect 团队内的测试人员，不能转为外部测试
或正式发布。若之后需要外部 TestFlight，应重新上传未标记为 Internal Only 的构建。

## 标识

| 项 | 值 |
|---|---|
| 主 App | `com.miclash.app` |
| NE 扩展 | `com.miclash.app.tunnel` |
| App Group | `group.com.miclash.app` |

## 进度

- **Phase 0（进行中）**：工程地基 + CI + NE 空壳，验证 VPN 权限链路。
- Phase 1：mihomo `gomobile bind` 化为 MihomoCore.xcframework。
- Phase 2：tun 接管流量。
- Phase 3：UI（ShipSwift）。
- Phase 4：订阅/保活/打磨。
