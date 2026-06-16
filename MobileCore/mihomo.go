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
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"gopkg.in/yaml.v3"
)

// ControllerAddr 是 NE 内 mihomo external-controller 的监听地址。
// 主 App 经 sendProviderMessage IPC 在重签环境下不投递，改用本地回环 HTTP 直连——
// 127.0.0.1 是 loopback，不经 tun，跨进程可达，是 clash 类 iOS App 的通用做法。
const ControllerAddr = "127.0.0.1:9090"

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

	// executor.ApplyConfig 不会起 external-controller，需手动起（ReCreate 可重复调用）。
	// 无 secret，仅绑 127.0.0.1，个人本机用。主 App 据此 HTTP 直连查/切策略组。
	route.ReCreateServer(&route.Config{Addr: ControllerAddr})
	appendRunLog("external-controller 已启动: " + ControllerAddr)
	return nil
}

// StartWithConfig 用订阅/自定义 YAML 启动内核：先把订阅配置与「iOS 必需的安全设置」
// 合并、并剔除 geo 规则，再注入 fd 启动。对应 Swift 侧 `MihomoStartWithConfig(_:_:error:)`。
//
// 为什么在 Go 侧统一覆盖：tun/dns/fake-ip/gvisor 这些 iOS NE 约束不能让订阅随意改写，
// 否则 tun 不通或 OOM；集中在这里强制，订阅只贡献 proxies/proxy-groups/rules。
func StartWithConfig(fd int, configYAML string) (err error) {
	defer func() {
		if r := recover(); r != nil {
			stack := fmt.Sprintf("panic: %v\n%s", r, debug.Stack())
			appendRunLog("===== mihomo 启动 panic =====\n" + stack)
			err = fmt.Errorf("mihomo panic: %v", r)
		}
	}()

	appendRunLog(fmt.Sprintf("StartWithConfig: fd=%d 合并 iOS 安全设置并剔除 geo 规则", fd))

	merged, err := mergeConfig(configYAML)
	if err != nil {
		appendRunLog("合并配置失败: " + err.Error())
		return err
	}

	rawCfg, err := config.UnmarshalRawConfig(merged)
	if err != nil {
		appendRunLog("UnmarshalRawConfig 失败: " + err.Error())
		return err
	}
	rawCfg.Tun.Enable = true
	rawCfg.Tun.FileDescriptor = fd

	cfg, err := config.ParseRawConfig(rawCfg)
	if err != nil {
		appendRunLog("ParseRawConfig 失败: " + err.Error())
		return err
	}

	appendRunLog("ParseRawConfig 成功，开始 ApplyConfig")
	executor.ApplyConfig(cfg, true)
	appendRunLog("ApplyConfig 返回，内核已启动")

	// executor.ApplyConfig 不会起 external-controller，需手动起（ReCreate 可重复调用）。
	// 无 secret，仅绑 127.0.0.1，个人本机用。主 App 据此 HTTP 直连查/切策略组。
	route.ReCreateServer(&route.Config{Addr: ControllerAddr})
	appendRunLog("external-controller 已启动: " + ControllerAddr)
	return nil
}

// mergeConfig 把订阅 YAML 与 iOS 必需设置合并：强制 tun/dns、关 geo 下载、剔除 geo 规则。
// fd 不在此写入（运行期值），由 StartWithConfig 解析后注入 Tun.FileDescriptor。
func mergeConfig(subYAML string) ([]byte, error) {
	m := map[string]any{}
	if strings.TrimSpace(subYAML) != "" {
		if err := yaml.Unmarshal([]byte(subYAML), &m); err != nil {
			return nil, err
		}
	}

	// 强制 tun：gvisor 栈（iOS NE 里 system 栈 TCP 不通），dns 劫持，自动路由。
	m["tun"] = map[string]any{
		"enable":                true,
		"stack":                 "gvisor",
		"dns-hijack":            []any{"any:53"},
		"auto-route":            true,
		"auto-detect-interface": true,
		"mtu":                   1500,
	}
	// 强制 dns：tun 必须 fake-ip + 纯 IP 的 DoH 上游（无需二次解析，杜绝死循环）。
	m["dns"] = map[string]any{
		"enable":        true,
		"ipv6":          false,
		"enhanced-mode": "fake-ip",
		"fake-ip-range": "198.18.0.1/16",
		"nameserver": []any{
			"https://223.5.5.5/dns-query",
			"https://1.1.1.1/dns-query",
		},
	}
	// 关 geo 数据库下载/更新（NE 内会 OOM）。
	m["geo-auto-update"] = false
	m["geodata-mode"] = false
	if _, ok := m["mode"]; !ok {
		m["mode"] = "rule"
	}
	// 剔除 geo 规则（GEOIP/GEOSITE 需 geo 库，NE 50MB 限制下易 OOM）。
	if rules, ok := m["rules"].([]any); ok {
		m["rules"] = filterGeoRules(rules)
	}

	return yaml.Marshal(m)
}

// filterGeoRules 删除以 GEOIP,/GEOSITE,/GEODATA, 开头的规则条目（不分大小写）。
func filterGeoRules(rules []any) []any {
	out := make([]any, 0, len(rules))
	dropped := 0
	for _, r := range rules {
		if s, ok := r.(string); ok {
			u := strings.ToUpper(strings.TrimSpace(s))
			if strings.HasPrefix(u, "GEOIP,") || strings.HasPrefix(u, "GEOSITE,") || strings.HasPrefix(u, "GEODATA,") {
				dropped++
				continue
			}
		}
		out = append(out, r)
	}
	if dropped > 0 {
		appendRunLog(fmt.Sprintf("剔除 geo 规则 %d 条", dropped))
	}
	return out
}

// QueryProxies 返回**精简**的策略组 JSON：{"proxies":{<组名>:{type,now,all}}}。
//
// 为什么精简：完整 tunnel.Proxies() 含每个节点对象 + 测速 history + GLOBAL 列全部节点，
// 多节点订阅可达数百 KB，超过 sendProviderMessage IPC 的响应体积上限会被丢成空响应。
// UI 只需各策略组的 type/当前选中/成员名，这里只保留这三项，体积砍到几十分之一。
// 实现：先按官方方式整体 Marshal（各代理用自身 MarshalJSON 吐出 all/now/type），
// 再筛出带 "all" 的（即策略组），只取三字段重新打包。
func QueryProxies() string {
	raw, err := json.Marshal(tunnel.Proxies())
	if err != nil {
		return `{"proxies":{},"error":"marshal: ` + err.Error() + `"}`
	}
	var full map[string]map[string]any
	if err := json.Unmarshal(raw, &full); err != nil {
		return `{"proxies":{},"error":"unmarshal: ` + err.Error() + `"}`
	}

	groups := map[string]any{}
	for name, p := range full {
		if _, isGroup := p["all"]; !isGroup {
			continue // 只有策略组带 all
		}
		groups[name] = map[string]any{
			"type": p["type"],
			"now":  p["now"],
			"all":  p["all"],
		}
	}

	out, err := json.Marshal(map[string]any{"proxies": groups})
	if err != nil {
		return `{"proxies":{},"error":"repack: ` + err.Error() + `"}`
	}
	return string(out)
}

// SelectProxy 在指定策略组里选定某节点（等价 REST PUT /proxies/{name}）。
// 仅 Selector 类策略组可选；URLTest/Fallback 等自动组不支持。
// 对应 Swift 侧 `MihomoSelectProxy(_:_:error:)`。
func SelectProxy(group, name string) error {
	proxies := tunnel.Proxies()
	p, exist := proxies[group]
	if !exist {
		return fmt.Errorf("策略组不存在: %s", group)
	}
	selector, ok := p.Adapter().(outboundgroup.SelectAble)
	if !ok {
		return fmt.Errorf("%s 不是可选择的策略组（Selector）", group)
	}
	return selector.Set(name)
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
