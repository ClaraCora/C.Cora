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
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"gopkg.in/yaml.v3"
)

// 配置文件未指定 external-ui-url 时，默认用 zashboard 面板（gh-pages 构建产物）。
const defaultWebUIURL = "https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"

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

// appSettings 是主 App 下发的设置（JSON）。零值即各项默认。
type appSettings struct {
	Stack             string `json:"stack"`
	IPv6              bool   `json:"ipv6"`
	GeoEnabled        bool   `json:"geoEnabled"`
	GeoLoader         string `json:"geoLoader"`
	GeoAutoUpdate     bool   `json:"geoAutoUpdate"`
	GeoUpdateInterval int    `json:"geoUpdateInterval"`
	LogLevel          string `json:"logLevel"`
	ControllerPort    int    `json:"controllerPort"`
	ControllerSecret  string `json:"controllerSecret"`
	AllowLan          bool   `json:"allowLan"`
}

// parseSettings 解析设置 JSON，缺省值兜底（与主 App SettingsStore 默认一致）。
func parseSettings(settingsJSON string) appSettings {
	s := appSettings{Stack: "gvisor", LogLevel: "info", ControllerPort: 9090,
		GeoLoader: "memconservative", GeoUpdateInterval: 24}
	if strings.TrimSpace(settingsJSON) != "" {
		_ = json.Unmarshal([]byte(settingsJSON), &s)
	}
	if s.Stack == "" {
		s.Stack = "gvisor"
	}
	if s.LogLevel == "" {
		s.LogLevel = "info"
	}
	if s.ControllerPort == 0 {
		s.ControllerPort = 9090
	}
	if s.GeoLoader == "" {
		s.GeoLoader = "memconservative"
	}
	if s.GeoUpdateInterval <= 0 {
		s.GeoUpdateInterval = 24
	}
	return s
}

// StartWithConfig 用订阅/自定义 YAML + 设置启动内核：先把订阅配置与「iOS 必需的安全设置」
// 及用户设置合并、按需剔除 geo 规则，再注入 fd 启动，最后起 external-controller。
// 对应 Swift 侧 `MihomoStartWithConfig(_:_:_:error:)`。
func StartWithConfig(fd int, configYAML string, settingsJSON string) (err error) {
	defer func() {
		if r := recover(); r != nil {
			stack := fmt.Sprintf("panic: %v\n%s", r, debug.Stack())
			appendRunLog("===== mihomo 启动 panic =====\n" + stack)
			err = fmt.Errorf("mihomo panic: %v", r)
		}
	}()

	st := parseSettings(settingsJSON)
	appendRunLog(fmt.Sprintf("StartWithConfig: fd=%d stack=%s ipv6=%v geo=%v(%s) log=%s port=%d",
		fd, st.Stack, st.IPv6, st.GeoEnabled, st.GeoLoader, st.LogLevel, st.ControllerPort))

	merged, err := mergeConfig(configYAML, st)
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

	// 起 external-controller（executor.ApplyConfig 不会自动起，ReCreate 可重复调用）。
	host := "127.0.0.1"
	if st.AllowLan {
		host = "0.0.0.0"
	}
	addr := fmt.Sprintf("%s:%d", host, st.ControllerPort)

	// webui：mihomo 在 /ui 同源提供面板（浏览器访问，无 CORS/混合内容问题）。
	// **优先用配置文件里指定的 external-ui / external-ui-url / external-ui-name**，
	// 配置没指定时默认 zashboard。SetUIPath 必须在 ReCreateServer 之前（注册路由时读取）。
	var uiCfg struct {
		ExternalUI     string `yaml:"external-ui"`
		ExternalUIURL  string `yaml:"external-ui-url"`
		ExternalUIName string `yaml:"external-ui-name"`
	}
	_ = yaml.Unmarshal([]byte(configYAML), &uiCfg)
	externalUI := uiCfg.ExternalUI
	if externalUI == "" {
		externalUI = "ui"
	}
	externalUIURL := uiCfg.ExternalUIURL
	usingDefault := externalUIURL == ""
	if usingDefault {
		externalUIURL = defaultWebUIURL
	}

	uiPath := C.Path.Resolve(externalUI)
	route.SetUIPath(uiPath)
	route.ReCreateServer(&route.Config{
		Addr:   addr,
		Secret: st.ControllerSecret,
		Cors:   route.Cors{AllowOrigins: []string{"*"}, AllowPrivateNetwork: true},
	})
	appendRunLog(fmt.Sprintf("external-controller 已启动: %s (UI: /ui, %s)", addr,
		map[bool]string{true: "默认 zashboard", false: "配置指定"}[usingDefault]))

	// 后台下载面板到 ui 目录（空才下，已有则跳过）。best-effort，失败不影响代理。
	go func() {
		defer func() {
			if r := recover(); r != nil {
				appendRunLog(fmt.Sprintf("webui 下载 panic: %v", r))
			}
		}()
		updater.NewUiUpdater(externalUI, externalUIURL, uiCfg.ExternalUIName).AutoDownloadUI()
		appendRunLog("webui 就绪: /ui/")
	}()
	return nil
}

// mergeConfig 把订阅 YAML 与 iOS 必需设置 + 用户设置合并。
// 强制 tun/dns（tun 必须 fake-ip 才通），其余按设置：栈、ipv6、日志等级、是否剔 geo。
// fd 不在此写入（运行期值），由 StartWithConfig 解析后注入 Tun.FileDescriptor。
func mergeConfig(subYAML string, st appSettings) ([]byte, error) {
	m := map[string]any{}
	if strings.TrimSpace(subYAML) != "" {
		if err := yaml.Unmarshal([]byte(subYAML), &m); err != nil {
			return nil, err
		}
	}

	// 强制 tun（参考能跑满速的 Everywhere）：只设 enable/stack/mtu/dns-hijack/地址。
	// **关键：不设 auto-detect-interface / auto-route**——mihomo 自带接口监控在 iOS NE 不可靠，
	// 会把出站接口错切，导致流量被默认路由兜回 tun 而限速。出站接口改由 NE 的 NWPathMonitor
	// 经 SetDefaultInterface 显式喂入；iOS 路由由 NEPacketTunnelNetworkSettings 负责，无需 auto-route。
	tunCfg := map[string]any{
		"enable":        true,
		"stack":         st.Stack,
		"mtu":           1500,
		"dns-hijack":    []any{"any:53"},
		"inet4-address": []any{"198.18.0.1/16"},
	}
	if st.IPv6 {
		tunCfg["inet6-address"] = []any{"fdfe:dcba:9876::1/126"}
	}
	m["tun"] = tunCfg
	// 强制 dns：tun 必须 fake-ip + 纯 IP 的 DoH 上游（无需二次解析，杜绝死循环）。
	m["dns"] = map[string]any{
		"enable":        true,
		"ipv6":          st.IPv6,
		"enhanced-mode": "fake-ip",
		"fake-ip-range": "198.18.0.1/16",
		"nameserver": []any{
			"https://223.5.5.5/dns-query",
			"https://1.1.1.1/dns-query",
		},
	}
	m["ipv6"] = st.IPv6
	m["log-level"] = st.LogLevel

	if _, ok := m["mode"]; !ok {
		m["mode"] = "rule"
	}

	// geo：默认关 → 剔除 GEOIP/GEOSITE 规则（省内存）。
	// 开启 → 保留规则，按设置配置加载器/自动更新，内核按需下载/加载 geo 库（用 memconservative 省内存）。
	m["geodata-mode"] = false // false=用 mmdb
	if st.GeoEnabled {
		m["geodata-loader"] = st.GeoLoader
		m["geo-auto-update"] = st.GeoAutoUpdate
		m["geo-update-interval"] = st.GeoUpdateInterval
	} else {
		m["geo-auto-update"] = false
		if rules, ok := m["rules"].([]any); ok {
			m["rules"] = filterGeoRules(rules)
		}
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

// SetDefaultInterface 把所有出站绑定到指定物理接口（en0/pdp_ip0…）。
// 由 NE 的 NWPathMonitor 在网络路径变化时调用，取代 mihomo 自带的（iOS 下不可靠的）接口监控。
// 对应 Swift 侧 `MihomoSetDefaultInterface(_:)`。
func SetDefaultInterface(name string) {
	dialer.DefaultInterface.Store(name)
	appendRunLog("默认出站接口 = " + name)
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
