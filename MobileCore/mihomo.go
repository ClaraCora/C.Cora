// Package mihomo 是 mihomo（Clash.Meta）内核面向 iOS 的 gomobile 薄封装层。
//
// 设计原则：gomobile bind 只能在「导出函数的签名」上使用受限的基础类型
// （string / []byte / int / bool / error 等），不能直接暴露 mihomo 的复杂结构体。
// 因此本包内部 import 整个 mihomo，对外只暴露极简、gomobile 友好的函数。
//
// Phase 1：Version() 验证核心可加载。
// Phase 2：Setup/StartWithFd/Stop —— 用 NE 提供的 utun fd 让 mihomo 真正接管流量。
package mihomo

import (
	"runtime"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
)

// Version 返回「mihomo 内核版本 / Go 运行时版本」。
// 对应 Swift 侧 `MihomoVersion()`。
func Version() string {
	v := C.Version
	if v == "" {
		v = "unknown"
	}
	return "mihomo " + v + " / " + runtime.Version()
}

// Setup 设置 mihomo 的工作目录（home dir）。
// 必须传 App Group 容器内的可写路径——mihomo 会在此读写 fake-ip 缓存、
// 配置、geo 数据库等。须在 StartWithFd 之前调用。
// 对应 Swift 侧 `MihomoSetup(_:)`。
func Setup(homeDir string) {
	C.SetHomeDir(homeDir)
}

// StartWithFd 用系统 tun 的文件描述符 fd 与配置 YAML 启动内核。
//
// fd 来自 iOS NEPacketTunnelProvider 创建的 utun 接口——iOS 已经建好该接口并分配
// 了地址/路由，我们把它的 fd 直接交给 mihomo 的 tun 监听器（sing-tun），由内核
// 接管这块网卡的收发，避免再经 packetFlow 拷贝一层。
//
// 关键：fd 是运行期才知道的值，不能写死在 YAML 里，所以这里先把 YAML 反序列化成
// RawConfig，再把 fd 注入 Tun.FileDescriptor，最后解析并下发给 executor。
//
// 对应 Swift 侧 `MihomoStartWithFd(_:_:)`（Go 的 error 返回会映射为 Swift throws）。
func StartWithFd(fd int, configYAML string) error {
	rawCfg, err := config.UnmarshalRawConfig([]byte(configYAML))
	if err != nil {
		return err
	}

	// 注入运行期信息：iOS 已创建好的 utun fd。
	rawCfg.Tun.Enable = true
	rawCfg.Tun.FileDescriptor = fd

	cfg, err := config.ParseRawConfig(rawCfg)
	if err != nil {
		return err
	}

	// force=true：强制应用配置、重启所有监听器（含 tun 入站）。
	executor.ApplyConfig(cfg, true)
	return nil
}

// Stop 关闭内核与所有监听器。对应 Swift 侧 `MihomoStop()`。
func Stop() {
	executor.Shutdown()
}
