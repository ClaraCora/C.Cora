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
	"context"
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
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
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

	// 最近一次合并配置时收集的：不适用内容提示 + 各节点协议摘要（供主 App 经 IPC 取用）。
	configNotices   []string
	proxyDetailsMap = map[string]string{}
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

// ValidateGeoDatabase 使用 mihomo 自身的解析器校验主 App 下载的 GEO 文件。
// 主 App 只在校验通过后安装文件，避免 NE 遇到损坏文件时触发内核下载。
func ValidateGeoDatabase(path string, kind string) error {
	defer runtime.GC()
	normalizedKind := strings.ToLower(strings.TrimSpace(kind))
	switch normalizedKind {
	case "mmdb":
		if !mmdb.Verify(path) {
			return fmt.Errorf("invalid MMDB database")
		}
		return nil
	case "geoip", "geosite":
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		loader, err := geodata.GetGeoDataLoader("standard")
		if err != nil {
			return err
		}
		if normalizedKind == "geoip" {
			_, err = loader.LoadIPByBytes(data, "cn")
		} else {
			_, err = loader.LoadSiteByBytes(data, "cn")
		}
		if err != nil {
			return fmt.Errorf("invalid %s database: %w", normalizedKind, err)
		}
		return nil
	default:
		return fmt.Errorf("unknown GEO database kind: %s", normalizedKind)
	}
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
//
//	func Subscribe() observable.Subscription[Event]（即 <-chan Event）
//	type Event struct { LogLevel LogLevel; Payload string }
//	func (e *Event) Type() string  // 级别字符串
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
				// 总线收所有级别（mihomo 的 logCh 无条件推送），这里按配置级别过滤，
				// 让 run.log 以「设置里的日志级别」为天花板——复刻 print 的 `< Level()` 逻辑。
				if elm.LogLevel < log.Level() {
					continue
				}
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
	GeodataMode       bool   `json:"geodataMode"`
	GeoIPDatURL       string `json:"geoIPDatURL"`
	GeoMMDBURL        string `json:"geoMMDBURL"`
	GeoSiteURL        string `json:"geoSiteURL"`
	IgnoreGeoNegation bool   `json:"ignoreGeoNegation"`
	GeoAutoUpdate     bool   `json:"geoAutoUpdate"`
	GeoUpdateInterval int    `json:"geoUpdateInterval"`
	LogLevel          string `json:"logLevel"`
	ControllerPort    int    `json:"controllerPort"`
	ControllerSecret  string `json:"controllerSecret"`
	AllowLan          bool   `json:"allowLan"`
	MixedPort         int    `json:"mixedPort"`
}

// parseSettings 解析设置 JSON，缺省值兜底（与主 App SettingsStore 默认一致）。
func parseSettings(settingsJSON string) appSettings {
	s := appSettings{Stack: "gvisor", LogLevel: "info", ControllerPort: 9090,
		GeoLoader: "memconservative", IgnoreGeoNegation: true, GeoUpdateInterval: 24,
		GeoIPDatURL: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat",
		GeoMMDBURL:  "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb",
		GeoSiteURL:  "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"}
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
	if s.GeoIPDatURL == "" {
		s.GeoIPDatURL = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
	}
	if s.GeoMMDBURL == "" {
		s.GeoMMDBURL = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"
	}
	if s.GeoSiteURL == "" {
		s.GeoSiteURL = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
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
	appendRunLog(fmt.Sprintf("StartWithConfig: fd=%d stack=%s ipv6=%v geo=%v(mode=%v,%s,ignoreNegation=%v) log=%s port=%d",
		fd, st.Stack, st.IPv6, st.GeoEnabled, st.GeodataMode, st.GeoLoader,
		st.IgnoreGeoNegation, st.LogLevel, st.ControllerPort))

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

	// 主 App 可能已替换 GEO 文件；清掉上次连接遗留的 matcher/MMDB 缓存后再解析。
	geodata.ClearGeoSiteCache()
	geodata.ClearGeoIPCache()
	mmdb.ReloadIP()
	runtime.GC()

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
	// 优先用配置文件指定的 external-ui；未指定 URL 时使用默认 zashboard。
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
		"enable":         true,
		"ipv6":           st.IPv6,
		"enhanced-mode":  "fake-ip",
		"fake-ip-range":  "198.18.0.1/16",
		"cache-max-size": 512,
		"nameserver": []any{
			"https://223.5.5.5/dns-query",
			"https://1.1.1.1/dns-query",
		},
	}
	m["ipv6"] = st.IPv6
	m["log-level"] = st.LogLevel

	// 混合代理端口（HTTP+SOCKS，本机回环）。0=不开。
	if st.MixedPort > 0 {
		m["mixed-port"] = st.MixedPort
	} else {
		delete(m, "mixed-port")
	}

	if _, ok := m["mode"]; !ok {
		m["mode"] = "rule"
	}

	// 普通订阅默认持久化策略组选择；DIRECT 明确传 false 时保留，避免无意义打开 cache。
	profile, _ := m["profile"].(map[string]any)
	if profile == nil {
		profile = map[string]any{}
	}
	if _, specified := profile["store-selected"]; !specified {
		profile["store-selected"] = true
	}
	m["profile"] = profile

	// 收集本次合并的「不适用内容」提示。
	configNotices = nil

	// iOS 沙盒拿不到其它进程信息 → PROCESS-NAME/PROCESS-PATH 规则无效，剔除并提示。
	if rules, ok := m["rules"].([]any); ok {
		m["rules"] = filterUnsupportedRules(rules)
	}

	// geo 规则处理：
	//   开 → 保留普通 geo 规则；IgnoreGeoNegation 开启时再剔除 geolocation-!cn /
	//        NOT,((GEOIP,CN)) 等取反规则，并配置加载器和下载地址；
	//   关 → 剔除**所有** GEOIP/GEOSITE/GEODATA 规则（含逻辑规则里嵌的），省内存。
	m["geodata-mode"] = st.GeodataMode
	m["geodata-loader"] = st.GeoLoader
	m["geo-auto-update"] = false // GEO 下载/定时更新统一由主 App 完成
	m["geo-update-interval"] = st.GeoUpdateInterval
	geoXURL, _ := m["geox-url"].(map[string]any)
	if geoXURL == nil {
		geoXURL = map[string]any{}
	}
	geoXURL["geoip"] = st.GeoIPDatURL
	geoXURL["mmdb"] = st.GeoMMDBURL
	geoXURL["geosite"] = st.GeoSiteURL
	m["geox-url"] = geoXURL
	if st.GeoEnabled {
		if st.IgnoreGeoNegation {
			if rules, ok := m["rules"].([]any); ok {
				m["rules"] = filterGeoNegationRules(rules)
			}
		}
	} else {
		if rules, ok := m["rules"].([]any); ok {
			m["rules"] = filterGeoRules(rules)
		}
	}

	// 解析各节点协议摘要（如 "VLESS · TCP · Reality · Vision"），供节点页副标题。
	buildProxyDetails(m)

	return yaml.Marshal(m)
}

// filterUnsupportedRules 剔除 iOS 上无效的规则类型（按进程匹配），并登记提示。
func filterUnsupportedRules(rules []any) []any {
	out := make([]any, 0, len(rules))
	dropped := 0
	for _, r := range rules {
		if s, ok := r.(string); ok {
			u := strings.ToUpper(strings.TrimSpace(s))
			if strings.HasPrefix(u, "PROCESS-NAME,") || strings.HasPrefix(u, "PROCESS-PATH,") {
				dropped++
				continue
			}
		}
		out = append(out, r)
	}
	if dropped > 0 {
		configNotices = append(configNotices,
			fmt.Sprintf("已忽略 %d 条按进程分流规则（PROCESS-NAME/PATH，iOS 无法获取其它 App 进程）", dropped))
	}
	return out
}

// buildProxyDetails 从 proxies 段解析每个节点的协议摘要。
func buildProxyDetails(m map[string]any) {
	proxyDetailsMap = map[string]string{}
	list, ok := m["proxies"].([]any)
	if !ok {
		return
	}
	for _, item := range list {
		p, ok := item.(map[string]any)
		if !ok {
			continue
		}
		name, _ := p["name"].(string)
		if name == "" {
			continue
		}
		proxyDetailsMap[name] = summarizeProxy(p)
	}
}

// summarizeProxy 拼出 "VLESS · TCP · Reality · Vision" 这类协议摘要。
func summarizeProxy(p map[string]any) string {
	parts := []string{}
	typ, _ := p["type"].(string)
	if typ != "" {
		parts = append(parts, strings.ToUpper(typ))
	}
	// 传输层 network；vless/vmess/trojan 缺省即 tcp。
	network, _ := p["network"].(string)
	if network == "" {
		switch strings.ToLower(typ) {
		case "vless", "vmess", "trojan":
			network = "tcp"
		}
	}
	if network != "" {
		parts = append(parts, strings.ToUpper(network))
	}
	// 安全层：reality > tls。
	if _, hasReality := p["reality-opts"]; hasReality {
		parts = append(parts, "Reality")
	} else if tls, _ := p["tls"].(bool); tls {
		parts = append(parts, "TLS")
	}
	// flow：xtls-rprx-vision → Vision。
	if flow, _ := p["flow"].(string); flow != "" {
		if strings.Contains(strings.ToLower(flow), "vision") {
			parts = append(parts, "Vision")
		} else {
			parts = append(parts, flow)
		}
	}
	return strings.Join(parts, " · ")
}

// ConfigNotices 返回最近一次合并配置时的不适用内容提示（JSON 字符串数组）。
// 对应 Swift 侧 `MihomoConfigNotices()`。
func ConfigNotices() string {
	out, err := json.Marshal(configNotices)
	if err != nil {
		return "[]"
	}
	return string(out)
}

// ProxyDetails 返回 {节点名: 协议摘要} 的 JSON。对应 Swift 侧 `MihomoProxyDetails()`。
func ProxyDetails() string {
	out, err := json.Marshal(proxyDetailsMap)
	if err != nil {
		return "{}"
	}
	return string(out)
}

// filterGeoNegationRules 仅在 geo **开启**时用：保留普通 geo 规则，只剔除「取反」的——
// 即既引用 geo（含 GEOIP,/GEOSITE,/GEODATA,）又带否定语义的：
//   - 类目取反：GEOSITE,geolocation-!cn,…  / GEOIP,!cn,…（含 "!"）
//   - 逻辑取反：NOT,((GEOIP,CN)),…  / AND,((NOT,(GEOSITE,cn)),…),…（含 "NOT,"）
//
// 这类在 50MB 的 NE 里加载/求值「非某地区」易出问题，普通 GEOIP,CN / GEOSITE,cn 仍保留。
func filterGeoNegationRules(rules []any) []any {
	out := make([]any, 0, len(rules))
	dropped := 0
	for _, r := range rules {
		if s, ok := r.(string); ok {
			u := strings.ToUpper(strings.TrimSpace(s))
			hasGeo := strings.Contains(u, "GEOIP,") || strings.Contains(u, "GEOSITE,") || strings.Contains(u, "GEODATA,")
			negated := strings.Contains(u, "!") || strings.Contains(u, "NOT,")
			if hasGeo && negated {
				dropped++
				continue
			}
		}
		out = append(out, r)
	}
	if dropped > 0 {
		appendRunLog(fmt.Sprintf("剔除 geo 取反规则 %d 条", dropped))
		configNotices = append(configNotices,
			fmt.Sprintf("已忽略 %d 条 geo 取反规则（geolocation-!cn / NOT(GEOIP) 等，NE 内易出问题）", dropped))
	}
	return out
}

// filterGeoRules 删除任何**包含** GEOIP,/GEOSITE,/GEODATA, 的规则条目（不分大小写）。
// 用 Contains 而非 HasPrefix：除了 `GEOSITE,geolocation-!cn,…` `GEOIP,CN,…` 这种直接形式，
// 还要抓住**逻辑规则里嵌的 geo**，如 `NOT,((GEOIP,CN)),节点`、`AND,((GEOSITE,cn),(…)),节点`
// （即用户说的「geo 取反/组合」）——这些 geo 关闭时也必须剔除，否则内核仍会去加载 geo 库，
// 在 50MB 的 NE 里 OOM/下载失败导致连不上。非 geo 规则正文几乎不可能含 "GEOIP," 子串，误伤可忽略。
func filterGeoRules(rules []any) []any {
	out := make([]any, 0, len(rules))
	dropped := 0
	for _, r := range rules {
		if s, ok := r.(string); ok {
			u := strings.ToUpper(strings.TrimSpace(s))
			if strings.Contains(u, "GEOIP,") || strings.Contains(u, "GEOSITE,") || strings.Contains(u, "GEODATA,") {
				dropped++
				continue
			}
		}
		out = append(out, r)
	}
	if dropped > 0 {
		appendRunLog(fmt.Sprintf("剔除 geo 规则 %d 条", dropped))
		configNotices = append(configNotices,
			fmt.Sprintf("已忽略 %d 条 GEOIP/GEOSITE 规则（geo 未启用，可在设置里开启）", dropped))
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
			"icon": p["icon"], // 策略组图标 URL（配置里的）
		}
	}

	// 顺带带上当前模式，UI 一次 IPC 即可拿到「组 + 模式」，省一次往返。
	out, err := json.Marshal(map[string]any{
		"proxies": groups,
		"mode":    tunnel.Mode().String(),
	})
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
	if err := selector.Set(name); err != nil {
		return err
	}
	// 关键：Set() 只改运行态，**持久化要显式写 cache**（mihomo 的 REST 也是这么做的），
	// 否则 store-selected 启动时没东西可恢复 → 重连回默认。
	cachefile.Cache().SetSelected(group, name)
	return nil
}

// GroupDelay 对策略组里所有节点做延迟测试（等价 REST GET /group/{name}/delay），
// 返回 {<节点名>: 毫秒} 的 JSON；失败返回 {"error":...}。
// 对应 Swift 侧 `MihomoGroupDelay(_:_:_:)`。
func GroupDelay(group, url string, timeoutMs int) string {
	p, exist := tunnel.Proxies()[group]
	if !exist {
		return `{"error":"策略组不存在"}`
	}
	g, ok := p.Adapter().(outboundgroup.ProxyGroup)
	if !ok {
		return `{"error":"不是策略组"}`
	}
	if url == "" {
		url = "https://www.gstatic.com/generate_204"
	}
	if timeoutMs <= 0 {
		timeoutMs = 5000
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Millisecond*time.Duration(timeoutMs))
	defer cancel()

	var expectedStatus utils.IntRanges[uint16] // 零值=不限定状态码，与不带 expected 的 REST 行为一致
	dm, err := g.URLTest(ctx, url, expectedStatus)
	if err != nil {
		return `{"error":"` + err.Error() + `"}`
	}
	out, err := json.Marshal(dm)
	if err != nil {
		return `{"error":"marshal: ` + err.Error() + `"}`
	}
	return string(out)
}

// Mode 返回当前模式字符串（rule/global/direct）。对应 Swift 侧 `MihomoMode()`。
func Mode() string {
	return tunnel.Mode().String()
}

// SetMode 设置模式（rule/global/direct，大小写不敏感，未知按 rule）。
// 对应 Swift 侧 `MihomoSetMode(_:)`。
func SetMode(mode string) {
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "global":
		tunnel.SetMode(tunnel.Global)
	case "direct":
		tunnel.SetMode(tunnel.Direct)
	default:
		tunnel.SetMode(tunnel.Rule)
	}
}

// TrafficNow 返回当前每秒上下行速率（字节）：{"up":..,"down":..}。
// 取自 mihomo 统计管理器（与 REST /traffic 同源），对应 Swift 侧 `MihomoTrafficNow()`。
func TrafficNow() string {
	up, down := statistic.DefaultManager.Now()
	out, err := json.Marshal(map[string]int64{"up": up, "down": down})
	if err != nil {
		return `{"up":0,"down":0}`
	}
	return string(out)
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
