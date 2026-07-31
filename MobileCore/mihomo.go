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
	"io"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"github.com/oschwald/maxminddb-golang"
	"gopkg.in/yaml.v3"
)

const defaultASNURL = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb"

const defaultTunnelMTU = 1500

const minimumTunnelMTU = 576

const maxRunLogBytes int64 = 2 << 20

const maxRunLogLineBytes = 64 << 10

// ControllerAddr 是 NE 内 mihomo external-controller 的监听地址。
// 主 App 经 sendProviderMessage IPC 在重签环境下不投递，改用本地回环 HTTP 直连——
// 127.0.0.1 是 loopback，不经 tun，跨进程可达，是 clash 类 iOS App 的通用做法。
const ControllerAddr = "127.0.0.1:9090"

// homeDir 是 mihomo 工作目录（= App Group 容器），run.log 也写在这里。
var (
	homeDir       string
	logCaptureMu  sync.Once
	logFileMu     sync.Mutex
	configApplyMu sync.Mutex

	// 最近一次合并配置时收集的：不适用内容提示 + 各节点协议摘要（供主 App 经 IPC 取用）。
	configNotices   []string
	proxyDetailsMap = map[string]string{}
	controllerState = appSettings{ControllerPort: 9090}
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

// ConfiguredTunMTU 返回配置文件显式声明的 tun.mtu。
// 0 表示未声明或值无效，供 Network Extension 决定是否让 iOS 选择系统 MTU。
func ConfiguredTunMTU(configYAML string) int {
	m := map[string]any{}
	if err := yaml.Unmarshal([]byte(configYAML), &m); err != nil {
		return 0
	}
	tun, ok := m["tun"].(map[string]any)
	if !ok {
		return 0
	}
	mtu, ok := validTunnelMTU(tun["mtu"])
	if !ok {
		return 0
	}
	return mtu
}

func validTunnelMTU(value any) (int, bool) {
	var mtu int
	switch typed := value.(type) {
	case int:
		mtu = typed
	case int64:
		mtu = int(typed)
	case uint64:
		if typed > 65535 {
			return 0, false
		}
		mtu = int(typed)
	default:
		return 0, false
	}
	return mtu, mtu >= minimumTunnelMTU && mtu <= 65535
}

func normalizedTunnelMTU(mtu int) int {
	if mtu < minimumTunnelMTU || mtu > 65535 {
		return defaultTunnelMTU
	}
	return mtu
}

func tunnelMTUIsUnset(value any) bool {
	if value == nil {
		return true
	}
	switch typed := value.(type) {
	case int:
		return typed == 0
	case int64:
		return typed == 0
	case uint64:
		return typed == 0
	default:
		return false
	}
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
	case "asn":
		reader, err := maxminddb.Open(path)
		if err != nil {
			return fmt.Errorf("invalid ASN database: %w", err)
		}
		defer reader.Close()
		switch reader.Metadata.DatabaseType {
		case "GeoLite2-ASN", "DBIP-ASN-Lite (compat=GeoLite2-ASN)", "ipinfo generic_asn_free.mmdb":
			return nil
		default:
			return fmt.Errorf("unsupported ASN database type: %s", reader.Metadata.DatabaseType)
		}
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
	configureMemoryLimits()
	homeDir = home
	C.SetHomeDir(home)
	startLogCapture()
}

// configureMemoryLimits 给 Go 运行时设软性内存上限。iOS NE 的 jetsam 线约
// 50MB（按 phys_footprint 计），Go 默认 GOGC=100 会让堆涨到 live set 两倍才
// 回收、且还页消极。35MiB 软上限让 GC 提前加压，给 Swift/NE 基座与 gVisor
// 栈外内存留出余量；SetGCPercent(50) 进一步压低堆峰值。若真机观测到 GC
// 过于频繁（CPU 发热），可上调上限或回调 GCPercent。
func configureMemoryLimits() {
	debug.SetMemoryLimit(35 << 20)
	debug.SetGCPercent(50)
}

// ForceGC 供 Swift 侧内存压力事件（warning/critical）调用：立即 full GC
// 并把空闲页归还 OS，压低 phys_footprint，降低被 jetsam 的概率。
func ForceGC() {
	runtime.GC()
	debug.FreeOSMemory()
}

// startLogCapture 订阅 mihomo 内核日志（官方 log.Subscribe），逐条写入
// <home>/run.log。用户在 Windows 无 Mac/Console，靠这个文件 + 主 App 读取，
// 才能看到内核内部输出（如出站接口选择、bind 失败、DNS 等），不靠猜。
//
// 依据：metacubex/mihomo v1.19.29 log/log.go ——
//
//	func Subscribe() observable.Subscription[Event]（即 <-chan Event）
//	type Event struct { LogLevel LogLevel; Payload string }
//	func (e *Event) Type() string  // 级别字符串
func startLogCapture() {
	logCaptureMu.Do(func() {
		f, err := os.OpenFile(filepath.Join(homeDir, "run.log"),
			os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			return
		}
		sub := log.Subscribe()
		go func() {
			defer f.Close()
			for elm := range sub {
				// 总线收所有级别（mihomo 的 logCh 无条件推送），这里按配置级别过滤，
				// 让 run.log 以「设置里的日志级别」为天花板——复刻 print 的 `< Level()` 逻辑。
				if elm.LogLevel < log.Level() {
					continue
				}
				line := fmt.Sprintf("%s [%s] %s\n",
					time.Now().Format("15:04:05.000"), elm.Type(), elm.Payload)
				logFileMu.Lock()
				writeRunLogLine(f, line)
				logFileMu.Unlock()
				// WriteString 已立即写入系统页缓存，主 App 可以读取；逐行 Sync 会在
				// 高日志量时强制刷盘，拖慢 Tunnel 和前台 UI。
			}
		}()
	})
}

// appSettings 是主 App 下发的设置（JSON）。零值即各项默认。
type appSettings struct {
	Stack             string   `json:"stack"`
	IPv6              bool     `json:"ipv6"`
	GeoEnabled        bool     `json:"geoEnabled"`
	GeoLoader         string   `json:"geoLoader"`
	GeodataMode       bool     `json:"geodataMode"`
	GeoIPDatURL       string   `json:"geoIPDatURL"`
	GeoMMDBURL        string   `json:"geoMMDBURL"`
	GeoSiteURL        string   `json:"geoSiteURL"`
	IgnoreGeoNegation bool     `json:"ignoreGeoNegation"`
	GeoAutoUpdate     bool     `json:"geoAutoUpdate"`
	GeoUpdateInterval int      `json:"geoUpdateInterval"`
	LogLevel          string   `json:"logLevel"`
	ControllerPort    int      `json:"controllerPort"`
	ControllerSecret  string   `json:"controllerSecret"`
	AllowLan          bool     `json:"allowLan"`
	MixedPort         int      `json:"mixedPort"`
	SystemDNS         []string `json:"systemDNS"`
}

// parseSettings 解析设置 JSON，缺省值兜底（与主 App SettingsStore 默认一致）。
func parseSettings(settingsJSON string) appSettings {
	s := appSettings{Stack: "gvisor", LogLevel: "info", ControllerPort: 9090,
		GeoEnabled: true, GeoLoader: "memconservative", GeodataMode: true,
		IgnoreGeoNegation: false, GeoUpdateInterval: 24,
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
	if s.ControllerPort < 1 || s.ControllerPort > 65535 {
		s.ControllerPort = 9090
	}
	if s.MixedPort < 0 || s.MixedPort > 65535 {
		s.MixedPort = 0
	}
	if s.MixedPort == s.ControllerPort {
		s.MixedPort = 0
	}
	if s.AllowLan && strings.TrimSpace(s.ControllerSecret) == "" {
		s.AllowLan = false
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

type geoDownloadURLs struct {
	GeoIP       string `json:"geoip"`
	MMDB        string `json:"mmdb"`
	GeoSite     string `json:"geosite"`
	ASN         string `json:"asn"`
	GeoRequired bool   `json:"geoRequired"`
	ASNRequired bool   `json:"asnRequired"`
}

// ResolveGeoDownloadURLs returns the database URLs that the main App should use.
// Values declared by the active YAML's geox-url take priority over App fallbacks.
func ResolveGeoDownloadURLs(configYAML string, settingsJSON string) string {
	resolved := resolveGeoDownloadURLs(configYAML, parseSettings(settingsJSON))
	out, err := json.Marshal(resolved)
	if err != nil {
		return "{}"
	}
	return string(out)
}

func resolveGeoDownloadURLs(configYAML string, st appSettings) geoDownloadURLs {
	resolved := geoDownloadURLs{
		GeoIP:   st.GeoIPDatURL,
		MMDB:    st.GeoMMDBURL,
		GeoSite: st.GeoSiteURL,
		ASN:     defaultASNURL,
	}
	m := map[string]any{}
	if strings.TrimSpace(configYAML) != "" {
		_ = yaml.Unmarshal([]byte(configYAML), &m)
	}
	if urls, ok := m["geox-url"].(map[string]any); ok {
		if value := stringValue(urls["geoip"]); value != "" {
			resolved.GeoIP = value
		}
		if value := stringValue(urls["mmdb"]); value != "" {
			resolved.MMDB = value
		}
		if value := stringValue(urls["geosite"]); value != "" {
			resolved.GeoSite = value
		}
		if value := stringValue(urls["asn"]); value != "" {
			resolved.ASN = value
		}
	}
	resolved.GeoRequired = rulesUseGeo(m["rules"]) || rulesUseGeo(m["sub-rules"]) || rulesUseGeo(m["dns"])
	resolved.ASNRequired = resolved.ASNRequired || rulesUseASN(m["rules"]) || rulesUseASN(m["sub-rules"])
	return resolved
}

func stringValue(value any) string {
	s, _ := value.(string)
	return strings.TrimSpace(s)
}

func rulesUseASN(value any) bool {
	switch typed := value.(type) {
	case string:
		u := strings.ToUpper(strings.TrimSpace(typed))
		return strings.Contains(u, "IP-ASN,") || strings.Contains(u, "SRC-IP-ASN,")
	case []any:
		for _, item := range typed {
			if rulesUseASN(item) {
				return true
			}
		}
	case map[string]any:
		for _, item := range typed {
			if rulesUseASN(item) {
				return true
			}
		}
	}
	return false
}

func rulesUseGeo(value any) bool {
	switch typed := value.(type) {
	case string:
		u := strings.ToUpper(strings.TrimSpace(typed))
		return strings.Contains(u, "GEOIP,") ||
			strings.Contains(u, "GEOSITE,") ||
			strings.Contains(u, "GEODATA,") ||
			strings.HasPrefix(u, "GEOSITE:")
	case []any:
		for _, item := range typed {
			if rulesUseGeo(item) {
				return true
			}
		}
	case map[string]any:
		for key, item := range typed {
			normalizedKey := strings.ToUpper(strings.TrimSpace(key))
			switch normalizedKey {
			case "GEOIP":
				if enabled, ok := item.(bool); !ok || enabled {
					return true
				}
			case "GEOIP-CODE", "GEOSITE":
				return true
			}
			if rulesUseGeo(key) || rulesUseGeo(item) {
				return true
			}
		}
	}
	return false
}

// StartWithConfig 用订阅/自定义 YAML + 设置启动内核：先把订阅配置与「iOS 必需的安全设置」
// 及用户设置合并、按需剔除 geo 规则，再注入 fd 启动，最后起 external-controller。
// 对应 Swift 侧 `MihomoStartWithConfig(_:_:_:_:error:)`。
func StartWithConfig(fd int, tunnelMTU int, configYAML string, settingsJSON string) (err error) {
	defer func() {
		if r := recover(); r != nil {
			stack := fmt.Sprintf("panic: %v\n%s", r, debug.Stack())
			appendRunLog("===== mihomo 启动 panic =====\n" + stack)
			err = fmt.Errorf("mihomo panic: %v", r)
		}
	}()
	configApplyMu.Lock()
	defer configApplyMu.Unlock()

	resetError := resetRunLog()
	st := parseSettings(settingsJSON)
	appendRunLog(fmt.Sprintf("StartWithConfig: fd=%d mtu=%d stack=%s ipv6=%v geo=%v(mode=%v,%s,ignoreNegation=%v) log=%s port=%d",
		fd, tunnelMTU, st.Stack, st.IPv6, st.GeoEnabled, st.GeodataMode, st.GeoLoader,
		st.IgnoreGeoNegation, st.LogLevel, st.ControllerPort))
	if resetError != nil {
		appendRunLog("run.log 重置失败: " + resetError.Error())
	}

	if err := applyRuntimeConfig(fd, tunnelMTU, configYAML, st, "启动", false); err != nil {
		return err
	}
	configureController(configYAML, st)
	return nil
}

// ReloadConfig 在当前 utun 上重新合并并应用主 App 下发的配置。
// 与 StartWithConfig 共用同一条 iOS 配置处理路径，但不会清空现有日志或重复下载 Web UI。
func ReloadConfig(fd int, tunnelMTU int, configYAML string, settingsJSON string) (err error) {
	defer func() {
		if r := recover(); r != nil {
			stack := fmt.Sprintf("panic: %v\n%s", r, debug.Stack())
			appendRunLog("===== mihomo 重载 panic =====\n" + stack)
			err = fmt.Errorf("mihomo reload panic: %v", r)
		}
	}()
	configApplyMu.Lock()
	defer configApplyMu.Unlock()

	st := parseSettings(settingsJSON)
	appendRunLog(fmt.Sprintf("ReloadConfig: fd=%d mtu=%d stack=%s ipv6=%v geo=%v(mode=%v,%s,ignoreNegation=%v) log=%s port=%d",
		fd, tunnelMTU, st.Stack, st.IPv6, st.GeoEnabled, st.GeodataMode, st.GeoLoader,
		st.IgnoreGeoNegation, st.LogLevel, st.ControllerPort))
	if err := applyRuntimeConfig(fd, tunnelMTU, configYAML, st, "重载", true); err != nil {
		return err
	}
	configureController(configYAML, st)
	appendRunLog("配置重载完成")
	return nil
}

func applyRuntimeConfig(fd int, tunnelMTU int, configYAML string, st appSettings, operation string, preserveTun bool) (err error) {
	previousNotices := append([]string(nil), configNotices...)
	previousDetails := make(map[string]string, len(proxyDetailsMap))
	for name, detail := range proxyDetailsMap {
		previousDetails[name] = detail
	}
	applied := false
	defer func() {
		if !applied {
			configNotices = previousNotices
			proxyDetailsMap = previousDetails
		}
	}()

	merged, err := mergeConfig(configYAML, st, tunnelMTU)
	if err != nil {
		appendRunLog(operation + "合并配置失败: " + err.Error())
		return err
	}

	rawCfg, err := config.UnmarshalRawConfig(merged)
	if err != nil {
		appendRunLog(operation + " UnmarshalRawConfig 失败: " + err.Error())
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
		appendRunLog(operation + " ParseRawConfig 失败: " + err.Error())
		return err
	}
	if preserveTun {
		if !listener.LastTunConf.Enable || listener.LastTunConf.FileDescriptor == 0 {
			return fmt.Errorf("当前 TUN 配置不可用，请重新连接 VPN")
		}
		// 热重载不能让 ReCreateTun 关闭 iOS 交给扩展的原始 utun fd。
		// 固定为当前运行配置后，mihomo 会命中 Tun.OnReload，仅更新其余组件。
		cfg.General.Tun = listener.LastTunConf
	}

	appendRunLog(operation + " ParseRawConfig 成功，开始 ApplyConfig")
	executor.ApplyConfig(cfg, true)
	if !preserveTun {
		// Parsing and applying a large configuration can leave temporary heap
		// pages resident. Return them once during startup.
		debug.FreeOSMemory()
	} else {
		// 热重载时立刻 full GC 会中断转发；延迟 15s 等重载稳定后再还页，
		// 避免大订阅重载后的临时堆页常驻不还。
		go func() {
			time.Sleep(15 * time.Second)
			debug.FreeOSMemory()
		}()
	}
	applied = true
	appendRunLog(operation + " ApplyConfig 返回")
	return nil
}

// configureController 让主 App 的控制接口跟随当前设置。NE 内不下载或解压 Web UI，
// 避免在 Packet Tunnel 的小内存预算内产生不可取消的后台任务。
func configureController(configYAML string, st appSettings) {
	host := "127.0.0.1"
	if st.AllowLan && strings.TrimSpace(st.ControllerSecret) != "" {
		host = "0.0.0.0"
	}
	addr := fmt.Sprintf("%s:%d", host, st.ControllerPort)

	// webui：mihomo 在 /ui 同源提供面板（浏览器访问，无 CORS/混合内容问题）。
	// 优先用配置文件指定的 external-ui；未指定 URL 时使用默认 zashboard。
	var uiCfg struct {
		ExternalUI string `yaml:"external-ui"`
	}
	_ = yaml.Unmarshal([]byte(configYAML), &uiCfg)
	externalUI := uiCfg.ExternalUI
	if externalUI == "" {
		externalUI = "ui"
	}
	uiPath := C.Path.Resolve(externalUI)
	route.SetUIPath(uiPath)
	route.ReCreateServer(&route.Config{
		Addr:   addr,
		Secret: st.ControllerSecret,
		Cors:   route.Cors{AllowOrigins: []string{}, AllowPrivateNetwork: false},
	})
	controllerState = st
	appendRunLog(fmt.Sprintf("external-controller 已启动: %s", addr))
}

// ControllerInfo 返回当前实际监听端点，供主 App 在系统/控制中心拉起隧道后同步客户端。
func ControllerInfo() string {
	configApplyMu.Lock()
	defer configApplyMu.Unlock()
	out, err := json.Marshal(map[string]any{
		"port":     controllerState.ControllerPort,
		"secret":   controllerState.ControllerSecret,
		"allowLan": controllerState.AllowLan,
	})
	if err != nil {
		return `{"port":9090,"secret":"","allowLan":false}`
	}
	return string(out)
}

// mergeConfig 把订阅 YAML 与 iOS 必需设置 + 用户设置合并。
// 强制 iOS TUN 与 DNS 接管所需参数；DNS enhanced-mode 保留配置值，未配置时使用 Mihomo 默认值。
// fd 不在此写入（运行期值）；MTU 优先使用配置值，缺省时使用 iOS utun 的实际值。
func mergeConfig(subYAML string, st appSettings, tunnelMTU int) ([]byte, error) {
	m := map[string]any{}
	if strings.TrimSpace(subYAML) != "" {
		if err := yaml.Unmarshal([]byte(subYAML), &m); err != nil {
			return nil, err
		}
	}

	// 重建 iOS tun 的核心参数；保留订阅显式声明的路由开关，方便配置审计并尊重
	// auto-route=false。auto-redirect 在非 Linux 平台会由 sing-tun 强制关闭，strict-route
	// 在 iOS FD 模式下也不负责系统路由；实际路由仍由 NEPacketTunnelNetworkSettings 下发。
	sourceTun, _ := m["tun"].(map[string]any)
	tunCfg := map[string]any{
		"enable":        true,
		"stack":         st.Stack,
		"dns-hijack":    []any{"any:53"},
		"inet4-address": []any{"198.18.0.1/16"},
	}
	if value, exists := sourceTun["mtu"]; exists && !tunnelMTUIsUnset(value) {
		mtu, valid := validTunnelMTU(value)
		if !valid {
			return nil, fmt.Errorf("tun.mtu must be an integer between %d and 65535", minimumTunnelMTU)
		}
		tunCfg["mtu"] = mtu
	} else {
		tunCfg["mtu"] = normalizedTunnelMTU(tunnelMTU)
	}
	if st.IPv6 {
		tunCfg["inet6-address"] = []any{"fdfe:dcba:9876::1/126"}
	}
	for _, key := range []string{"auto-route", "auto-redirect", "strict-route"} {
		if value, exists := sourceTun[key]; exists {
			tunCfg[key] = value
		}
	}
	m["tun"] = tunCfg
	// 保留订阅中的 enhanced-mode、nameserver、nameserver-policy 等 DNS 配置。
	// fake-ip-range 同时决定 Mihomo 内部 TUN 地址，必须与 iOS 固定的 198.18.0.x 网段一致；
	// 配置未提供 nameserver 时才使用纯 IP DoH 兜底。
	dnsCfg, _ := m["dns"].(map[string]any)
	if dnsCfg == nil {
		dnsCfg = map[string]any{}
	}
	dnsCfg["enable"] = true
	dnsCfg["ipv6"] = st.IPv6
	dnsCfg["fake-ip-range"] = "198.18.0.1/16"
	dnsCfg["cache-max-size"] = 512
	rawNameservers, hasNameservers := dnsCfg["nameserver"]
	nameservers, isList := rawNameservers.([]any)
	if !hasNameservers || rawNameservers == nil || (isList && len(nameservers) == 0) {
		dnsCfg["nameserver"] = []any{
			"https://223.5.5.5/dns-query",
			"https://1.1.1.1/dns-query",
		}
	}
	// 订阅可能写 `nameserver: [system]`。iOS 没有可供 Go 读取的 /etc/resolv.conf，
	// 内核无法解析 "system"；NE 启动时会抓取物理网络 DNS 注入（st.SystemDNS），
	// 这里据此替换。未注入（如抓取失败）时原样保留，行为与旧版一致。
	for _, key := range []string{"nameserver", "fallback", "default-nameserver", "proxy-server-nameserver", "direct-nameserver"} {
		if v, exists := dnsCfg[key]; exists {
			dnsCfg[key] = replaceSystemNameserver(v, st.SystemDNS, key)
		}
	}
	for _, key := range []string{"nameserver-policy", "proxy-server-nameserver-policy"} {
		if policy, ok := dnsCfg[key].(map[string]any); ok {
			for k, v := range policy {
				policy[k] = replaceSystemNameserver(v, st.SystemDNS, key)
			}
		}
	}
	m["dns"] = dnsCfg
	m["ipv6"] = st.IPv6
	m["log-level"] = st.LogLevel

	// 混合代理端口（HTTP+SOCKS，本机回环）。0=不开。
	for _, key := range []string{"port", "socks-port", "redir-port", "tproxy-port"} {
		delete(m, key)
	}
	m["allow-lan"] = false
	m["bind-address"] = "127.0.0.1"
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
	filterUnsupportedRulesFromConfig(m)

	// geo 规则处理：
	//   开 → 保留普通 geo 规则；IgnoreGeoNegation 开启时再剔除 geolocation-!cn /
	//        NOT,((GEOIP,CN)) 等取反规则，并配置加载器和下载地址；
	//   关 → 移除 geo 配置，并剔除 rules/sub-rules 中全部 GEOIP/GEOSITE/GEODATA 规则。
	// 自动下载始终关闭，GEO 文件只允许主 App 管理。
	m["geo-auto-update"] = false
	if st.GeoEnabled {
		resolvedURLs := resolveGeoDownloadURLs(subYAML, st)
		m["geodata-mode"] = st.GeodataMode
		m["geodata-loader"] = st.GeoLoader
		m["geo-update-interval"] = st.GeoUpdateInterval
		geoXURL, _ := m["geox-url"].(map[string]any)
		if geoXURL == nil {
			geoXURL = map[string]any{}
		}
		geoXURL["geoip"] = resolvedURLs.GeoIP
		geoXURL["mmdb"] = resolvedURLs.MMDB
		geoXURL["geosite"] = resolvedURLs.GeoSite
		geoXURL["asn"] = resolvedURLs.ASN
		m["geox-url"] = geoXURL
		if st.IgnoreGeoNegation {
			filterGeoNegationRulesFromConfig(m)
		}
	} else {
		delete(m, "geodata-mode")
		delete(m, "geodata-loader")
		delete(m, "geo-update-interval")
		if geoXURL, ok := m["geox-url"].(map[string]any); ok {
			delete(geoXURL, "geoip")
			delete(geoXURL, "mmdb")
			delete(geoXURL, "geosite")
			if len(geoXURL) == 0 {
				delete(m, "geox-url")
			} else {
				m["geox-url"] = geoXURL
			}
		}
		filterGeoRulesFromConfig(m)
	}

	// 解析各节点协议摘要（如 "VLESS · TCP · Reality · Vision"），供节点页副标题。
	buildProxyDetails(m)

	return yaml.Marshal(m)
}

// replaceSystemNameserver 把 DNS 服务器列表（或单字符串值）中的 "system" 展开为
// NE 侧注入的物理网络 DNS（system 参数）。未注入时原样返回，行为与旧版一致。
func replaceSystemNameserver(value any, system []string, field string) any {
	if len(system) == 0 {
		return value
	}
	if s, ok := value.(string); ok {
		if strings.EqualFold(strings.TrimSpace(s), "system") {
			appendRunLog("dns." + field + " 的 system 已替换为 " + strings.Join(system, ","))
			return stringsToAnyList(system)
		}
		return value
	}
	list, ok := value.([]any)
	if !ok {
		return value
	}
	out := make([]any, 0, len(list))
	for _, item := range list {
		if s, ok := item.(string); ok && strings.EqualFold(strings.TrimSpace(s), "system") {
			appendRunLog("dns." + field + " 的 system 已替换为 " + strings.Join(system, ","))
			out = append(out, stringsToAnyList(system)...)
			continue
		}
		out = append(out, item)
	}
	return out
}

func stringsToAnyList(ss []string) []any {
	out := make([]any, 0, len(ss))
	for _, s := range ss {
		out = append(out, s)
	}
	return out
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

func filterUnsupportedRulesFromConfig(m map[string]any) {
	if rules, ok := m["rules"].([]any); ok {
		m["rules"] = filterUnsupportedRules(rules)
	}
	if subRules, ok := m["sub-rules"].(map[string]any); ok {
		for name, raw := range subRules {
			if rules, ok := raw.([]any); ok {
				subRules[name] = filterUnsupportedRules(rules)
			}
		}
		m["sub-rules"] = subRules
	}
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
	configApplyMu.Lock()
	defer configApplyMu.Unlock()
	out, err := json.Marshal(configNotices)
	if err != nil {
		return "[]"
	}
	return string(out)
}

// ProxyDetails 返回 {节点名: 协议摘要} 的 JSON。对应 Swift 侧 `MihomoProxyDetails()`。
func ProxyDetails() string {
	configApplyMu.Lock()
	defer configApplyMu.Unlock()
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

func filterGeoNegationRulesFromConfig(m map[string]any) {
	if rules, ok := m["rules"].([]any); ok {
		m["rules"] = filterGeoNegationRules(rules)
	}
	if subRules, ok := m["sub-rules"].(map[string]any); ok {
		for name, raw := range subRules {
			if rules, ok := raw.([]any); ok {
				subRules[name] = filterGeoNegationRules(rules)
			}
		}
		m["sub-rules"] = subRules
	}
}

// filterGeoRulesFromConfig 删除 rules、sub-rules 与 DNS 配置中所有依赖 GEO 数据库的条目。
// DNS 也能通过 nameserver-policy/fallback-filter/fake-ip-filter 引用 GeoSite/GeoIP；
// 若只过滤分流规则，geo 关闭后仍会在 DNS 初始化阶段加载数据库并导致 NE 内存冲高。
func filterGeoRulesFromConfig(m map[string]any) {
	dropped := 0
	if rules, ok := m["rules"].([]any); ok {
		var count int
		m["rules"], count = filterGeoRules(rules)
		dropped += count
	}
	if subRules, ok := m["sub-rules"].(map[string]any); ok {
		for name, raw := range subRules {
			if rules, ok := raw.([]any); ok {
				filtered, count := filterGeoRules(rules)
				subRules[name] = filtered
				dropped += count
			}
		}
		m["sub-rules"] = subRules
	}
	dropped += filterGeoDNSConfig(m)
	if dropped > 0 {
		appendRunLog(fmt.Sprintf("剔除 geo/ASN 规则或 DNS 策略 %d 条", dropped))
		configNotices = append(configNotices,
			fmt.Sprintf("已忽略 %d 条 GEOIP/GEOSITE/IP-ASN 规则或 DNS 策略（geo 未启用，可在设置里开启）", dropped))
	}
}

func filterGeoDNSConfig(m map[string]any) int {
	dnsCfg, ok := m["dns"].(map[string]any)
	if !ok {
		return 0
	}

	dropped := 0
	for _, name := range []string{"nameserver-policy", "proxy-server-nameserver-policy"} {
		policy, ok := dnsCfg[name].(map[string]any)
		if !ok {
			continue
		}
		for key := range policy {
			if strings.HasPrefix(strings.ToLower(strings.TrimSpace(key)), "geosite:") {
				delete(policy, key)
				dropped++
			}
		}
		if len(policy) == 0 {
			delete(dnsCfg, name)
		} else {
			dnsCfg[name] = policy
		}
	}

	if fallback, ok := dnsCfg["fallback-filter"].(map[string]any); ok {
		if enabled, _ := fallback["geoip"].(bool); enabled {
			dropped++
		}
		delete(fallback, "geoip")
		delete(fallback, "geoip-code")
		if geosite, ok := fallback["geosite"].([]any); ok {
			dropped += len(geosite)
			delete(fallback, "geosite")
		}
		dnsCfg["fallback-filter"] = fallback
	}

	if filters, ok := dnsCfg["fake-ip-filter"].([]any); ok {
		kept := make([]any, 0, len(filters))
		for _, raw := range filters {
			value, isString := raw.(string)
			upper := strings.ToUpper(strings.TrimSpace(value))
			if isString && (strings.Contains(upper, "GEOSITE:") || strings.Contains(upper, "GEOSITE,")) {
				dropped++
				continue
			}
			kept = append(kept, raw)
		}
		dnsCfg["fake-ip-filter"] = kept
	}

	m["dns"] = dnsCfg
	return dropped
}

func filterGeoRules(rules []any) ([]any, int) {
	out := make([]any, 0, len(rules))
	dropped := 0
	for _, r := range rules {
		if s, ok := r.(string); ok {
			u := strings.ToUpper(strings.TrimSpace(s))
			if strings.Contains(u, "GEOIP,") || strings.Contains(u, "GEOSITE,") ||
				strings.Contains(u, "GEODATA,") || strings.Contains(u, "IP-ASN,") {
				dropped++
				continue
			}
		}
		out = append(out, r)
	}
	return out, dropped
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

// RuntimeStats returns a compact process snapshot for the Network Extension's
// persistent OOM diagnostics. It reads runtime/statistic counters without
// forcing a garbage collection.
func RuntimeStats() string {
	var mem runtime.MemStats
	runtime.ReadMemStats(&mem)

	connections := 0
	tcpConnections := 0
	udpConnections := 0
	statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
		connections++
		info := tracker.Info()
		if info == nil || info.Metadata == nil {
			return true
		}
		switch info.Metadata.NetWork {
		case C.TCP:
			tcpConnections++
		case C.UDP:
			udpConnections++
		}
		return true
	})

	up, down := statistic.DefaultManager.Now()
	upTotal, downTotal := statistic.DefaultManager.Total()
	var lastPause uint64
	if mem.NumGC != 0 {
		lastPause = mem.PauseNs[(mem.NumGC-1)%uint32(len(mem.PauseNs))]
	}

	snapshot := struct {
		HeapAlloc      uint64  `json:"heapAlloc"`
		HeapObjects    uint64  `json:"heapObjects"`
		HeapInuse      uint64  `json:"heapInuse"`
		HeapIdle       uint64  `json:"heapIdle"`
		HeapReleased   uint64  `json:"heapReleased"`
		HeapSys        uint64  `json:"heapSys"`
		StackInuse     uint64  `json:"stackInuse"`
		StackSys       uint64  `json:"stackSys"`
		MSpanInuse     uint64  `json:"mspanInuse"`
		MCacheInuse    uint64  `json:"mcacheInuse"`
		BuckHashSys    uint64  `json:"buckHashSys"`
		GCSys          uint64  `json:"gcSys"`
		OtherSys       uint64  `json:"otherSys"`
		Sys            uint64  `json:"sys"`
		TotalAlloc     uint64  `json:"totalAlloc"`
		Mallocs        uint64  `json:"mallocs"`
		Frees          uint64  `json:"frees"`
		NextGC         uint64  `json:"nextGC"`
		LastGC         uint64  `json:"lastGC"`
		NumGC          uint32  `json:"numGC"`
		NumForcedGC    uint32  `json:"numForcedGC"`
		PauseTotalNs   uint64  `json:"pauseTotalNs"`
		LastPauseNs    uint64  `json:"lastPauseNs"`
		GCCPUFraction  float64 `json:"gcCPUFraction"`
		Goroutines     int     `json:"goroutines"`
		Connections    int     `json:"connections"`
		TCPConnections int     `json:"tcpConnections"`
		UDPConnections int     `json:"udpConnections"`
		Upload         int64   `json:"up"`
		Download       int64   `json:"down"`
		UploadTotal    int64   `json:"upTotal"`
		DownloadTotal  int64   `json:"downTotal"`
	}{
		HeapAlloc:      mem.HeapAlloc,
		HeapObjects:    mem.HeapObjects,
		HeapInuse:      mem.HeapInuse,
		HeapIdle:       mem.HeapIdle,
		HeapReleased:   mem.HeapReleased,
		HeapSys:        mem.HeapSys,
		StackInuse:     mem.StackInuse,
		StackSys:       mem.StackSys,
		MSpanInuse:     mem.MSpanInuse,
		MCacheInuse:    mem.MCacheInuse,
		BuckHashSys:    mem.BuckHashSys,
		GCSys:          mem.GCSys,
		OtherSys:       mem.OtherSys,
		Sys:            mem.Sys,
		TotalAlloc:     mem.TotalAlloc,
		Mallocs:        mem.Mallocs,
		Frees:          mem.Frees,
		NextGC:         mem.NextGC,
		LastGC:         mem.LastGC,
		NumGC:          mem.NumGC,
		NumForcedGC:    mem.NumForcedGC,
		PauseTotalNs:   mem.PauseTotalNs,
		LastPauseNs:    lastPause,
		GCCPUFraction:  mem.GCCPUFraction,
		Goroutines:     runtime.NumGoroutine(),
		Connections:    connections,
		TCPConnections: tcpConnections,
		UDPConnections: udpConnections,
		Upload:         up,
		Download:       down,
		UploadTotal:    upTotal,
		DownloadTotal:  downTotal,
	}
	out, err := json.Marshal(snapshot)
	if err != nil {
		return `{}`
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
	configApplyMu.Lock()
	defer configApplyMu.Unlock()
	appendRunLog("Stop: 关闭内核")
	executor.Shutdown()
}

// appendRunLog 追加一行到 <home>/run.log（封装层自己的标记，便于和内核日志混排）。
func appendRunLog(msg string) {
	if homeDir == "" {
		return
	}
	logFileMu.Lock()
	defer logFileMu.Unlock()
	f, err := os.OpenFile(filepath.Join(homeDir, "run.log"),
		os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	writeRunLogLine(f, fmt.Sprintf("%s [WRAP] %s\n",
		time.Now().Format("15:04:05.000"), msg))
}

func writeRunLogLine(file *os.File, line string) {
	if len(line) > maxRunLogLineBytes {
		const truncationSuffix = "... (line truncated)\n"
		end := maxRunLogLineBytes - len(truncationSuffix)
		for end > 0 && !utf8.RuneStart(line[end]) {
			end--
		}
		line = line[:end] + truncationSuffix
	}
	seekWhence := io.SeekEnd
	if info, err := file.Stat(); err == nil && info.Size()+int64(len(line)) > maxRunLogBytes {
		if err := file.Truncate(0); err == nil {
			seekWhence = io.SeekStart
		}
	}
	_, _ = file.Seek(0, seekWhence)
	_, _ = file.WriteString(line)
}

// 每次真实启动都开启新的 run.log 会话。日志页在内存中保留上一会话，因此这里截断
// 不会让用户断开后看不到日志，同时避免同一 NE 进程重连时重复读取历史内容。
func resetRunLog() error {
	if homeDir == "" {
		return nil
	}
	logFileMu.Lock()
	defer logFileMu.Unlock()
	f, err := os.OpenFile(filepath.Join(homeDir, "run.log"),
		os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	return f.Close()
}
