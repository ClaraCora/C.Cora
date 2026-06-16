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
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"sync"
	"time"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
)

// homeDir 是 mihomo 工作目录（= App Group 容器），run.log 也写在这里。
var (
	homeDir      string
	logCaptureMu sync.Once
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

// Setup 设置 mihomo 的工作目录（home dir）并启动日志捕获。
// 必须传 App Group 容器内的可写路径——mihomo 会在此读写 fake-ip 缓存、
// 配置等；同时本封装把内核日志逐条写入 <home>/run.log。须在 StartWithFd 之前调用。
// 对应 Swift 侧 `MihomoSetup(_:)`。
func Setup(home string) {
	homeDir = home
	C.SetHomeDir(home)
	startLogCapture()
}

// startLogCapture 订阅 mihomo 内核日志（官方 log.Subscribe），逐条写入
// <home>/run.log。用户在 Windows 无 Mac/Console，靠这个文件 + 主 App 读取，
// 才能看到内核内部输出（如出站接口选择、bind 失败、DNS 等），不靠猜。
//
// 依据：metacubex/mihomo v1.19.27 log/log.go ——
//   func Subscribe() observable.Subscription[Event]（即 <-chan Event）
//   type Event struct { LogLevel LogLevel; Payload string }
//   func (e *Event) Type() string  // 级别字符串
func startLogCapture() {
	logCaptureMu.Do(func() {
		sub := log.Subscribe()
		go func() {
			f, err := os.OpenFile(filepath.Join(homeDir, "run.log"),
				os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
			if err != nil {
				return
			}
			defer f.Close()
			for elm := range sub {
				_, _ = f.WriteString(fmt.Sprintf("%s [%s] %s\n",
					time.Now().Format("15:04:05.000"), elm.Type(), elm.Payload))
				_ = f.Sync()
			}
		}()
	})
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
// 用 recover 兜住内核启动期可能的 panic（如 gvisor/路由相关），把堆栈写进 run.log
// 并以 error 返回，避免整个 NE 进程静默崩溃、只看到「连接中→已断开」却查不到原因。
//
// 对应 Swift 侧 `MihomoStartWithFd(_:_:error:)`。
func StartWithFd(fd int, configYAML string) (err error) {
	defer func() {
		if r := recover(); r != nil {
			stack := fmt.Sprintf("panic: %v\n%s", r, debug.Stack())
			appendRunLog("===== mihomo 启动 panic =====\n" + stack)
			err = fmt.Errorf("mihomo panic: %v", r)
		}
	}()

	appendRunLog(fmt.Sprintf("StartWithFd: fd=%d 开始解析配置", fd))

	rawCfg, err := config.UnmarshalRawConfig([]byte(configYAML))
	if err != nil {
		appendRunLog("UnmarshalRawConfig 失败: " + err.Error())
		return err
	}

	// 注入运行期信息：iOS 已创建好的 utun fd。
	rawCfg.Tun.Enable = true
	rawCfg.Tun.FileDescriptor = fd

	cfg, err := config.ParseRawConfig(rawCfg)
	if err != nil {
		appendRunLog("ParseRawConfig 失败: " + err.Error())
		return err
	}

	// force=true：强制应用配置、重启所有监听器（含 tun 入站）。
	appendRunLog("ParseRawConfig 成功，开始 ApplyConfig")
	executor.ApplyConfig(cfg, true)
	appendRunLog("ApplyConfig 返回，内核已启动")
	return nil
}

// Stop 关闭内核与所有监听器。对应 Swift 侧 `MihomoStop()`。
func Stop() {
	appendRunLog("Stop: 关闭内核")
	executor.Shutdown()
}

// appendRunLog 追加一行到 <home>/run.log（封装层自己的标记，便于和内核日志混排）。
func appendRunLog(msg string) {
	if homeDir == "" {
		return
	}
	f, err := os.OpenFile(filepath.Join(homeDir, "run.log"),
		os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.WriteString(fmt.Sprintf("%s [WRAP] %s\n",
		time.Now().Format("15:04:05.000"), msg))
}
