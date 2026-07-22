# MiClash

基于 [mihomo](https://github.com/MetaCubeX/mihomo) 内核的 iOS 代理客户端，SwiftUI + MVVM，个人自签自用。

详细路线见 [PLAN.md](PLAN.md)。

## 构建

工程用 [XcodeGen](https://github.com/yonsm/XcodeGen) 管理，`.xcodeproj` 不入库。开发机为 Windows，靠 GitHub Actions（macos-26 / Xcode 26）构建未签名 ipa。

- 推送到 `main` 或手动触发 `Build unsigned IPA` 工作流。
- 产物 `MiClash-unsigned-ipa` 在 Actions artifact 中下载。
- 用自有 Apple 开发者证书自行签名后安装（工程内不含任何证书/描述文件/Secrets）。

本地有 Mac 时：

```bash
brew install xcodegen
xcodegen generate
open MiClash.xcodeproj
```

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
