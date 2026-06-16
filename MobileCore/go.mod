module miclash/mobilecore

go 1.23

// pin 到已验证可为 iOS 构建的 mihomo 版本（首次成功构建于 2026-06-16）。
// 升级时改这里的版本号即可；CI 的 go mod tidy 会补齐间接依赖与 go.sum。
require github.com/metacubex/mihomo v1.19.27
