// Package mihomo 是 mihomo（Clash.Meta）内核面向 iOS 的 gomobile 薄封装层。
//
// 设计原则：gomobile bind 只能在「导出函数的签名」上使用受限的基础类型
// （string / []byte / int / bool / error 等），不能直接暴露 mihomo 的复杂结构体。
// 因此本包内部 import 整个 mihomo，对外只暴露极简、gomobile 友好的函数。
//
// Phase 1 仅导出 Version()：只要它能在 App 内成功返回，就证明 mihomo 已被正确
// 交叉编译进 Mihomo.xcframework、并能从 Swift 调用——即「核心可加载」这一里程碑。
// Phase 2 起会在此追加 Setup / Start / Stop / Reload 等真正的内核控制函数。
package mihomo

import (
	"runtime"

	// 别名 C 与 mihomo 源码 main.go 的惯例一致；Version 是内核版本变量，
	// mihomo 的构建系统通过 ldflags -X 注入；未注入时为默认占位值。
	C "github.com/metacubex/mihomo/constant"
)

// Version 返回「mihomo 内核版本 / Go 运行时版本」。
//
// 导出给 gomobile：Swift 侧调用为 `MihomoVersion()`，返回 String。
// 内部读取 mihomo 的 constant.Version，这一引用会强制整个 mihomo 被链接进框架，
// 从而真正验证交叉编译链路，而非返回一个与内核无关的常量。
func Version() string {
	v := C.Version
	if v == "" {
		v = "unknown"
	}
	return "mihomo " + v + " / " + runtime.Version()
}
