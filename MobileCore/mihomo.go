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
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/dlclark/regexp2"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/iface"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	mdns "github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/hub/executor"
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

const controlProtocolVersion = 1

const defaultConnectionSnapshotLimit = 200

const maxConnectionSnapshotLimit = 500

const defaultRunLogChunkBytes = 48 << 10

// homeDir 是 mihomo 工作目录（= App Group 容器），run.log 也写在这里。
var (
	homeDir          string
	logCaptureMu     sync.Once
	logFileMu        sync.Mutex
	runLogFile       *os.File
	runLogBytes      int64 = -1
	runLogGeneration int64
	configApplyMu    sync.RWMutex
	interfaceMu      sync.RWMutex
	physicalIface    string

	// 最近一次合并配置时收集的：不适用内容提示 + 各节点协议摘要（供主 App 经 IPC 取用）。
	configNotices        []string
	proxyDetailsMap      = map[string]string{}
	activeDNSConfig      *config.DNS
	activeGeneralIPv6    bool
	activeSystemDNS      []string
	activeUsesSystemDNS  bool
	pendingUsesSystemDNS bool
	coreStartedAt        time.Time
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

// ControlInfo advertises the app-owned IPC contract.
func ControlInfo() string {
	out, err := json.Marshal(map[string]any{
		"protocolVersion": controlProtocolVersion,
		"coreVersion":     Version(),
		"capabilities": []string{
			"connections", "logs", "proxies", "runtime",
		},
	})
	if err != nil {
		return `{"protocolVersion":1,"capabilities":[]}`
	}
	return string(out)
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
		logFileMu.Lock()
		runLogFile = f
		if info, statErr := f.Stat(); statErr == nil {
			runLogBytes = info.Size()
		} else {
			runLogBytes = -1
		}
		_, _ = f.Seek(0, io.SeekEnd)
		logFileMu.Unlock()
		sub := log.Subscribe()
		go func() {
			defer func() {
				logFileMu.Lock()
				if runLogFile == f {
					runLogFile = nil
					runLogBytes = -1
				}
				_ = f.Close()
				logFileMu.Unlock()
			}()
			for elm := range sub {
				// 总线收所有级别（mihomo 的 logCh 无条件推送），这里按配置级别过滤，
				// 让 run.log 以「设置里的日志级别」为天花板——复刻 print 的 `< Level()` 逻辑。
				if elm.LogLevel < log.Level() {
					continue
				}
				line := fmt.Sprintf("%s [%s] %s\n",
					logTimestamp(), elm.Type(), elm.Payload)
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
	Stack             string                 `json:"stack"`
	IPv6              bool                   `json:"ipv6"`
	GeoEnabled        bool                   `json:"geoEnabled"`
	GeoLoader         string                 `json:"geoLoader"`
	GeodataMode       bool                   `json:"geodataMode"`
	GeoIPDatURL       string                 `json:"geoIPDatURL"`
	GeoMMDBURL        string                 `json:"geoMMDBURL"`
	GeoSiteURL        string                 `json:"geoSiteURL"`
	IgnoreGeoNegation bool                   `json:"ignoreGeoNegation"`
	GeoAutoUpdate     bool                   `json:"geoAutoUpdate"`
	GeoUpdateInterval int                    `json:"geoUpdateInterval"`
	LogLevel          string                 `json:"logLevel"`
	MixedPort         int                    `json:"mixedPort"`
	BlockDirectSTUN   bool                   `json:"blockDirectSTUN"`
	SystemDNS         []string               `json:"systemDNS"`
	ApplyOverrides    bool                   `json:"applyOverrides"`
	Overrides         configOverrideSettings `json:"overrides"`
	ProxySelections   map[string]string      `json:"proxySelections"`
}

type configOverrideSettings struct {
	DNS     dnsOverrideSettings     `json:"dns"`
	Sniffer snifferOverrideSettings `json:"sniffer"`
	Tun     tunOverrideSettings     `json:"tun"`
}

type dnsOverrideSettings struct {
	Overwrite           bool              `json:"overwrite"`
	Listen              string            `json:"listen"`
	PreferH3            bool              `json:"preferH3"`
	UseSystemHosts      bool              `json:"useSystemHosts"`
	UseHosts            bool              `json:"useHosts"`
	Hosts               map[string]string `json:"hosts"`
	EnhancedMode        string            `json:"enhancedMode"`
	FakeIPFilterMode    string            `json:"fakeIPFilterMode"`
	FakeIPFilter        []string          `json:"fakeIPFilter"`
	RespectRules        bool              `json:"respectRules"`
	DefaultNameservers  []string          `json:"defaultNameservers"`
	Nameservers         []string          `json:"nameservers"`
	ProxyNameservers    []string          `json:"proxyNameservers"`
	DirectNameservers   []string          `json:"directNameservers"`
	FallbackNameservers []string          `json:"fallbackNameservers"`
	FallbackGeoIP       bool              `json:"fallbackGeoIP"`
}

type snifferOverrideSettings struct {
	Overwrite           bool     `json:"overwrite"`
	Enable              bool     `json:"enable"`
	ForceDNSMapping     bool     `json:"forceDNSMapping"`
	ParsePureIP         bool     `json:"parsePureIP"`
	OverrideDestination bool     `json:"overrideDestination"`
	HTTP                bool     `json:"http"`
	TLS                 bool     `json:"tls"`
	QUIC                bool     `json:"quic"`
	ForceDomains        []string `json:"forceDomains"`
	SkipDomains         []string `json:"skipDomains"`
}

type tunOverrideSettings struct {
	Overwrite      bool     `json:"overwrite"`
	DNSHijack      []string `json:"dnsHijack"`
	StrictRoute    bool     `json:"strictRoute"`
	ICMPForwarding bool     `json:"icmpForwarding"`
}

// parseSettings 解析设置 JSON，缺省值兜底（与主 App SettingsStore 默认一致）。
func parseSettings(settingsJSON string) appSettings {
	s := appSettings{Stack: "gvisor", LogLevel: "info",
		ApplyOverrides: true,
		GeoEnabled:     true, GeoLoader: "memconservative", GeodataMode: true,
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
	if s.MixedPort < 0 || s.MixedPort > 65535 {
		s.MixedPort = 0
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
	m := map[string]any{}
	if strings.TrimSpace(configYAML) != "" {
		_ = yaml.Unmarshal([]byte(configYAML), &m)
	}
	return resolveGeoDownloadURLsFromMap(m, st)
}

// mergeConfig 已经解析过完整 YAML，复用该映射避免大订阅在一次配置应用中
// 为 GEO URL 与规则依赖扫描再次执行 yaml.Unmarshal。
func resolveGeoDownloadURLsFromMap(m map[string]any, st appSettings) geoDownloadURLs {
	resolved := geoDownloadURLs{
		GeoIP:   st.GeoIPDatURL,
		MMDB:    st.GeoMMDBURL,
		GeoSite: st.GeoSiteURL,
		ASN:     defaultASNURL,
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
	scanConfig := m
	if st.ApplyOverrides && st.Overrides.DNS.Overwrite {
		scanConfig = make(map[string]any, len(m)+1)
		for key, value := range m {
			scanConfig[key] = value
		}
		scanDNS := map[string]any{}
		if sourceDNS, ok := m["dns"].(map[string]any); ok {
			for key, value := range sourceDNS {
				scanDNS[key] = value
			}
		}
		applyDNSOverride(scanConfig, scanDNS, st.Overrides.DNS)
		scanConfig["dns"] = scanDNS
	}
	requirements := configRuleRequirements(scanConfig)
	resolved.GeoRequired = requirements.geo
	resolved.ASNRequired = requirements.asn
	return resolved
}

func stringValue(value any) string {
	s, _ := value.(string)
	return strings.TrimSpace(s)
}

func rulesUseASN(value any) bool {
	return inspectRuleRequirements(value).asn
}

func rulesUseGeo(value any) bool {
	return inspectRuleRequirements(value).geo
}

type ruleRequirements struct {
	geo bool
	asn bool
}

func configRuleRequirements(config map[string]any) ruleRequirements {
	result := ruleRequirements{}
	for _, value := range []any{config["rules"], config["sub-rules"]} {
		result.merge(inspectRuleRequirements(value))
		if result.geo && result.asn {
			break
		}
	}
	// DNS 配置只会引用 GEO 数据；ASN 需求保持仅由 rules/sub-rules 决定。
	if !result.geo {
		result.geo = inspectRuleRequirements(config["dns"]).geo
	}
	return result
}

func (r *ruleRequirements) merge(other ruleRequirements) {
	r.geo = r.geo || other.geo
	r.asn = r.asn || other.asn
}

// GEO 与 ASN 依赖共享一次递归扫描，避免数千条规则被分别大写化和遍历。
func inspectRuleRequirements(value any) ruleRequirements {
	result := ruleRequirements{}
	switch typed := value.(type) {
	case string:
		u := strings.ToUpper(strings.TrimSpace(typed))
		result.geo = strings.Contains(u, "GEOIP,") ||
			strings.Contains(u, "GEOSITE,") ||
			strings.Contains(u, "GEODATA,") ||
			strings.HasPrefix(u, "GEOSITE:")
		result.asn = strings.Contains(u, "IP-ASN,") || strings.Contains(u, "SRC-IP-ASN,")
	case []any:
		for _, item := range typed {
			result.merge(inspectRuleRequirements(item))
			if result.geo && result.asn {
				break
			}
		}
	case map[string]any:
		for key, item := range typed {
			normalizedKey := strings.ToUpper(strings.TrimSpace(key))
			switch normalizedKey {
			case "GEOIP":
				if enabled, ok := item.(bool); !ok || enabled {
					result.geo = true
				}
			case "GEOIP-CODE", "GEOSITE":
				result.geo = true
			}
			result.merge(inspectRuleRequirements(key))
			result.merge(inspectRuleRequirements(item))
			if result.geo && result.asn {
				break
			}
		}
	}
	return result
}

// StartWithConfig 用订阅/自定义 YAML + 设置启动内核：先把订阅配置与「iOS 必需的安全设置」
// 及用户设置合并、按需剔除 geo 规则，再注入 fd 启动。
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
	appendRunLog(fmt.Sprintf("StartWithConfig: fd=%d mtu=%d stack=%s ipv6=%v geo=%v(mode=%v,%s,ignoreNegation=%v) log=%s",
		fd, tunnelMTU, st.Stack, st.IPv6, st.GeoEnabled, st.GeodataMode, st.GeoLoader,
		st.IgnoreGeoNegation, st.LogLevel))
	if resetError != nil {
		appendRunLog("run.log 重置失败: " + resetError.Error())
	}
	for group, name := range st.ProxySelections {
		if strings.TrimSpace(group) != "" && strings.TrimSpace(name) != "" {
			cachefile.Cache().SetSelected(group, name)
		}
	}

	if err := applyRuntimeConfig(fd, tunnelMTU, configYAML, st); err != nil {
		return err
	}
	coreStartedAt = time.Now()
	return nil
}

func applyRuntimeConfig(fd int, tunnelMTU int, configYAML string, st appSettings) error {
	merged, err := mergeConfig(configYAML, st, tunnelMTU)
	if err != nil {
		appendRunLog("启动合并配置失败: " + err.Error())
		return err
	}

	rawCfg, err := config.UnmarshalRawConfig(merged)
	if err != nil {
		appendRunLog("启动 UnmarshalRawConfig 失败: " + err.Error())
		return err
	}
	rawCfg.Tun.Enable = true
	rawCfg.Tun.FileDescriptor = fd
	merged = nil

	// 主 App 可能已替换 GEO 文件；清掉上次连接遗留的 matcher/MMDB 缓存后再解析。
	geodata.ClearGeoSiteCache()
	geodata.ClearGeoIPCache()
	mmdb.ReloadIP()
	runtime.GC()

	cfg, err := config.ParseRawConfig(rawCfg)
	if err != nil {
		appendRunLog("启动 ParseRawConfig 失败: " + err.Error())
		return err
	}

	appendRunLog("启动 ParseRawConfig 成功，开始 ApplyConfig")
	executor.ApplyConfig(cfg, true)
	for group, name := range st.ProxySelections {
		proxy, exists := tunnel.Proxies()[group]
		if !exists {
			appendRunLog(fmt.Sprintf("跳过已失效的离线选择：%s -> %s（策略组不存在）", group, name))
			continue
		}
		selector, ok := proxy.Adapter().(outboundgroup.SelectAble)
		if !ok {
			continue
		}
		if err := selector.Set(name); err != nil {
			appendRunLog(fmt.Sprintf("跳过已失效的离线选择：%s -> %s（%v）", group, name, err))
			continue
		}
		cachefile.Cache().SetSelected(group, name)
	}
	activeDNSConfig = cfg.DNS
	activeGeneralIPv6 = cfg.General.IPv6
	activeSystemDNS = append(activeSystemDNS[:0], st.SystemDNS...)
	activeUsesSystemDNS = pendingUsesSystemDNS
	// ApplyConfig 会按 YAML 重写 DefaultInterface；恢复 NWPathMonitor 选出的物理接口。
	if name := currentPhysicalInterface(); name != "" {
		dialer.DefaultInterface.Store(name)
		iface.FlushCache()
		resolver.ResetConnection()
		appendRunLog("启动后恢复物理出站接口 = " + name)
	}
	debug.FreeOSMemory()
	appendRunLog("启动 ApplyConfig 返回")
	return nil
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
	for _, key := range []string{
		"auto-route", "auto-redirect", "strict-route", "dns-hijack",
		"disable-icmp-forwarding",
	} {
		if value, exists := sourceTun[key]; exists {
			tunCfg[key] = value
		}
	}
	if _, exists := tunCfg["dns-hijack"]; !exists {
		tunCfg["dns-hijack"] = []any{"any:53"}
	}
	if st.ApplyOverrides && st.Overrides.Tun.Overwrite {
		tunCfg["dns-hijack"] = stringsToAny(st.Overrides.Tun.DNSHijack)
		tunCfg["strict-route"] = st.Overrides.Tun.StrictRoute
		tunCfg["disable-icmp-forwarding"] = !st.Overrides.Tun.ICMPForwarding
	}
	m["tun"] = tunCfg
	// 保留订阅中的 enhanced-mode、nameserver、nameserver-policy 等 DNS 配置。
	// fake-ip-range 同时决定 Mihomo 内部 TUN 地址，必须与 iOS 固定的 198.18.0.x 网段一致；
	// 配置未提供 nameserver 时才使用纯 IP DoH 兜底。
	dnsCfg, _ := m["dns"].(map[string]any)
	if dnsCfg == nil {
		dnsCfg = map[string]any{}
	}
	if st.ApplyOverrides && st.Overrides.DNS.Overwrite {
		applyDNSOverride(m, dnsCfg, st.Overrides.DNS)
	}
	dnsCfg["enable"] = true
	dnsCfg["ipv6"] = st.IPv6
	dnsCfg["fake-ip-range"] = "198.18.0.1/16"
	dnsCfg["cache-max-size"] = 512
	pendingUsesSystemDNS = dnsConfigUsesSystem(dnsCfg)
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
	if st.ApplyOverrides && st.Overrides.Sniffer.Overwrite {
		m["sniffer"] = buildSnifferOverride(st.Overrides.Sniffer)
	}
	m["ipv6"] = st.IPv6
	m["log-level"] = st.LogLevel

	// WebUI/external-controller is intentionally unavailable in the extension.
	// Strip subscription-owned endpoints so no HTTP control listener is exposed.
	for _, key := range []string{
		"external-controller", "external-controller-tls", "external-controller-unix",
		"external-controller-pipe", "external-controller-routing-mark",
		"external-controller-cors", "external-doh-server", "secret",
		"external-ui", "external-ui-url", "external-ui-name",
	} {
		delete(m, key)
	}

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
		resolvedURLs := resolveGeoDownloadURLsFromMap(m, st)
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
	if st.BlockDirectSTUN {
		injectDirectSTUNBlockRules(m)
	}

	// 解析各节点协议摘要（如 "VLESS · TCP · Reality · Vision"），供节点页副标题。
	buildProxyDetails(m)

	return yaml.Marshal(m)
}

var publicSTUNLeakEndpoints = []string{
	"stun.l.google.com",
	"stun1.l.google.com",
	"stun2.l.google.com",
	"stun3.l.google.com",
	"stun4.l.google.com",
	"stun.cloudflare.com",
	"stun.services.mozilla.com",
	"global.stun.twilio.com",
	"stun.stunprotocol.org",
}

func injectDirectSTUNBlockRules(root map[string]any) {
	rules, _ := root["rules"].([]any)
	mode, _ := root["mode"].(string)
	if strings.EqualFold(strings.TrimSpace(mode), "direct") {
		root["mode"] = "rule"
		rules = append(rules, "MATCH,DIRECT")
	}
	injected := make([]any, 0, len(publicSTUNLeakEndpoints))
	existing := map[string]bool{}
	for _, raw := range rules {
		if rule, ok := raw.(string); ok {
			existing[strings.ToUpper(strings.TrimSpace(rule))] = true
		}
	}
	for _, domain := range publicSTUNLeakEndpoints {
		rule := "DOMAIN," + domain + ",REJECT"
		if !existing[strings.ToUpper(rule)] {
			injected = append(injected, rule)
		}
	}
	merged := make([]any, 0, len(rules)+len(injected))
	merged = append(merged, injected...)
	merged = append(merged, rules...)
	root["rules"] = merged
}

func applyDNSOverride(root map[string]any, dns map[string]any, override dnsOverrideSettings) {
	if listen := strings.TrimSpace(override.Listen); listen != "" {
		dns["listen"] = listen
	} else {
		delete(dns, "listen")
	}
	dns["prefer-h3"] = override.PreferH3
	dns["use-system-hosts"] = override.UseSystemHosts
	dns["use-hosts"] = override.UseHosts

	hosts := make(map[string]any, len(override.Hosts))
	for domain, address := range override.Hosts {
		domain = strings.TrimSpace(domain)
		address = strings.TrimSpace(address)
		if domain != "" && address != "" {
			hosts[domain] = address
		}
	}
	root["hosts"] = hosts

	switch override.EnhancedMode {
	case "fake-ip", "redir-host":
		dns["enhanced-mode"] = override.EnhancedMode
	default:
		dns["enhanced-mode"] = "fake-ip"
	}
	switch override.FakeIPFilterMode {
	case "blacklist", "whitelist", "rule":
		dns["fake-ip-filter-mode"] = override.FakeIPFilterMode
	default:
		dns["fake-ip-filter-mode"] = "blacklist"
	}
	dns["fake-ip-filter"] = stringsToAny(override.FakeIPFilter)
	dns["respect-rules"] = override.RespectRules
	dns["default-nameserver"] = stringsToAny(override.DefaultNameservers)
	dns["nameserver"] = stringsToAny(override.Nameservers)
	dns["proxy-server-nameserver"] = stringsToAny(override.ProxyNameservers)
	dns["direct-nameserver"] = stringsToAny(override.DirectNameservers)
	fallbackNameservers := stringsToAny(override.FallbackNameservers)
	dns["fallback"] = fallbackNameservers

	if len(fallbackNameservers) == 0 {
		delete(dns, "fallback-filter")
		return
	}
	fallbackFilter, _ := dns["fallback-filter"].(map[string]any)
	if fallbackFilter == nil {
		fallbackFilter = map[string]any{}
	}
	fallbackFilter["geoip"] = override.FallbackGeoIP
	fallbackFilter["geoip-code"] = "CN"
	dns["fallback-filter"] = fallbackFilter
}

func buildSnifferOverride(override snifferOverrideSettings) map[string]any {
	protocols := map[string]any{}
	if override.HTTP {
		protocols["HTTP"] = map[string]any{"ports": []any{80, "8080-8880"}}
	}
	if override.TLS {
		protocols["TLS"] = map[string]any{"ports": []any{443, 8443}}
	}
	if override.QUIC {
		protocols["QUIC"] = map[string]any{"ports": []any{443, 8443}}
	}
	return map[string]any{
		"enable":               override.Enable,
		"force-dns-mapping":    override.ForceDNSMapping,
		"parse-pure-ip":        override.ParsePureIP,
		"override-destination": override.OverrideDestination,
		"sniff":                protocols,
		"force-domain":         stringsToAny(override.ForceDomains),
		"skip-domain":          stringsToAny(override.SkipDomains),
	}
}

func stringsToAny(values []string) []any {
	out := make([]any, 0, len(values))
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			out = append(out, value)
		}
	}
	return out
}

// replaceSystemNameserver 把 DNS 服务器列表（或单字符串值）中的 "system" 展开为
// NE 侧注入的物理网络 DNS（system 参数）。未注入时原样返回，行为与旧版一致。
func replaceSystemNameserver(value any, system []string, field string) any {
	if len(system) == 0 {
		return value
	}
	if s, ok := value.(string); ok {
		if isSystemDNSValue(s) {
			appendRunLog("dns." + field + " 的 system 已替换为 " + strings.Join(system, ","))
			return systemDNSToAnyList(system)
		}
		return value
	}
	list, ok := value.([]any)
	if !ok {
		return value
	}
	out := make([]any, 0, len(list))
	for _, item := range list {
		if s, ok := item.(string); ok && isSystemDNSValue(s) {
			appendRunLog("dns." + field + " 的 system 已替换为 " + strings.Join(system, ","))
			out = append(out, systemDNSToAnyList(system)...)
			continue
		}
		out = append(out, item)
	}
	return out
}

func dnsConfigUsesSystem(dnsConfig map[string]any) bool {
	for _, key := range []string{
		"nameserver", "fallback", "default-nameserver",
		"proxy-server-nameserver", "direct-nameserver",
	} {
		if valueUsesSystemDNS(dnsConfig[key]) {
			return true
		}
	}
	for _, key := range []string{"nameserver-policy", "proxy-server-nameserver-policy"} {
		if policies, ok := dnsConfig[key].(map[string]any); ok {
			for _, value := range policies {
				if valueUsesSystemDNS(value) {
					return true
				}
			}
		}
	}
	return false
}

func valueUsesSystemDNS(value any) bool {
	switch typed := value.(type) {
	case string:
		return isSystemDNSValue(typed)
	case []any:
		for _, item := range typed {
			if valueUsesSystemDNS(item) {
				return true
			}
		}
	}
	return false
}

func isSystemDNSValue(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "system", "system://", "dhcp://system":
		return true
	default:
		return false
	}
}

func systemDNSToAnyList(ss []string) []any {
	out := make([]any, 0, len(ss))
	for _, s := range ss {
		// mihomo parses nameservers as URLs. Encode the '%' introducing an
		// IPv6 zone so url.Parse turns %25en0 back into the runtime form %en0.
		out = append(out, strings.ReplaceAll(s, "%", "%25"))
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
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
	out, err := json.Marshal(configNotices)
	if err != nil {
		return "[]"
	}
	return string(out)
}

// ProxyDetails 返回 {节点名: 协议摘要} 的 JSON。对应 Swift 侧 `MihomoProxyDetails()`。
func ProxyDetails() string {
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
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

// QueryProxies returns only the group fields used by the app. It traverses the
// group interfaces directly so a large subscription is never fully serialized
// and decoded again inside the extension.
func QueryProxies() string {
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
	groups := map[string]any{}
	for name, proxy := range tunnel.Proxies() {
		group, isGroup := proxy.Adapter().(outboundgroup.ProxyGroup)
		if !isGroup {
			continue
		}
		members := group.Proxies()
		all := make([]string, 0, len(members))
		for _, member := range members {
			all = append(all, member.Name())
		}
		groups[name] = map[string]any{
			"type": proxy.Type().String(),
			"now":  group.Now(),
			"all":  all,
			"icon": group.Icon(),
		}
	}

	// 顺带带上当前模式，UI 一次 IPC 即可拿到「组 + 模式」，省一次往返。
	out, err := json.Marshal(map[string]any{
		"proxies": groups,
		"mode":    tunnel.Mode().String(),
	})
	if err != nil {
		return `{"proxies":{},"error":"marshal: ` + err.Error() + `"}`
	}
	return string(out)
}

type remoteProxyProvider struct {
	Name   string              `json:"name"`
	URL    string              `json:"url"`
	Header map[string][]string `json:"header,omitempty"`
}

// ProxyProviderManifest extracts the HTTP proxy providers that the main App
// may download and cache while the tunnel is disconnected. It only parses
// YAML and never initializes mihomo runtime providers.
func ProxyProviderManifest(configYAML string) string {
	var raw map[string]any
	if err := yaml.Unmarshal([]byte(configYAML), &raw); err != nil {
		return marshalJSON(map[string]any{"providers": []remoteProxyProvider{}, "error": err.Error()})
	}
	providers, _ := raw["proxy-providers"].(map[string]any)
	names := make([]string, 0, len(providers))
	for name := range providers {
		names = append(names, name)
	}
	sort.Strings(names)
	out := make([]remoteProxyProvider, 0, len(names))
	for _, name := range names {
		definition, _ := providers[name].(map[string]any)
		providerType, _ := definition["type"].(string)
		providerURL, _ := definition["url"].(string)
		if !strings.EqualFold(strings.TrimSpace(providerType), "http") || strings.TrimSpace(providerURL) == "" {
			continue
		}
		headers := map[string][]string{}
		if rawHeaders, ok := definition["header"].(map[string]any); ok {
			for key, rawValue := range rawHeaders {
				values := stringList(rawValue)
				if text, ok := rawValue.(string); ok {
					values = []string{text}
				}
				if len(values) > 0 {
					headers[key] = values
				}
			}
		}
		out = append(out, remoteProxyProvider{Name: name, URL: strings.TrimSpace(providerURL), Header: headers})
	}
	return marshalJSON(map[string]any{"providers": out})
}

// ValidateProxyProviderPayload verifies the common provider payload shape
// before the main App replaces its last known-good offline cache.
func ValidateProxyProviderPayload(payload string) error {
	_, err := parseProviderPayload(payload)
	return err
}

// UpdateProxyProviders refreshes the active runtime's HTTP proxy providers.
// File, inline and the reserved compatible provider are intentionally skipped.
func UpdateProxyProviders() string {
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
	providers := tunnel.Providers()
	names := make([]string, 0, len(providers))
	for name, provider := range providers {
		if provider.VehicleType() == P.HTTP {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	updated := make([]string, 0, len(names))
	failures := map[string]string{}
	for _, name := range names {
		if err := providers[name].Update(); err != nil {
			failures[name] = err.Error()
			continue
		}
		updated = append(updated, name)
	}
	return marshalJSON(map[string]any{
		"ok":       len(failures) == 0,
		"updated":  updated,
		"failures": failures,
	})
}

// OfflineProxySnapshot builds the subset of /proxies consumed by the App from
// saved YAML and cached provider payloads. It is safe in the main App process:
// no config.ParseRawConfig, provider initialization or network access occurs.
func OfflineProxySnapshot(configYAML, providerPayloadsJSON, selectionsJSON string) string {
	var raw map[string]any
	if err := yaml.Unmarshal([]byte(configYAML), &raw); err != nil {
		return marshalJSON(map[string]any{"proxies": map[string]any{}, "details": map[string]string{}, "mode": "rule", "error": err.Error()})
	}

	details := map[string]string{}
	inlineNames := make([]string, 0)
	inlineTypes := map[string]string{}
	if proxies, ok := raw["proxies"].([]any); ok {
		for _, item := range proxies {
			proxy, _ := item.(map[string]any)
			name, _ := proxy["name"].(string)
			if name == "" {
				continue
			}
			inlineNames = append(inlineNames, name)
			details[name] = summarizeProxy(proxy)
			inlineTypes[name], _ = proxy["type"].(string)
		}
	}

	providerPayloads := map[string]string{}
	_ = json.Unmarshal([]byte(providerPayloadsJSON), &providerPayloads)
	selections := map[string]string{}
	_ = json.Unmarshal([]byte(selectionsJSON), &selections)
	providerDefinitions, _ := raw["proxy-providers"].(map[string]any)
	providerNames := make([]string, 0, len(providerDefinitions))
	for name := range providerDefinitions {
		providerNames = append(providerNames, name)
	}
	sort.Strings(providerNames)
	providerNodes := map[string][]string{}
	providerNodeTypes := map[string]string{}
	missingProviders := make([]string, 0)
	for _, providerName := range providerNames {
		payload, exists := providerPayloads[providerName]
		if !exists {
			definition, _ := providerDefinitions[providerName].(map[string]any)
			providerType, _ := definition["type"].(string)
			if strings.EqualFold(providerType, "http") {
				missingProviders = append(missingProviders, providerName)
			}
			continue
		}
		proxies, err := parseProviderPayload(payload)
		if err != nil {
			continue
		}
		definition, _ := providerDefinitions[providerName].(map[string]any)
		for _, proxy := range filterOfflineProxies(proxies, definition) {
			name, _ := proxy["name"].(string)
			if name == "" {
				continue
			}
			providerNodes[providerName] = append(providerNodes[providerName], name)
			details[name] = summarizeProxy(proxy)
			providerNodeTypes[name], _ = proxy["type"].(string)
		}
	}

	groups := map[string]any{}
	groupNames := make([]string, 0)
	groupList, _ := raw["proxy-groups"].([]any)
	for _, item := range groupList {
		group, _ := item.(map[string]any)
		name, _ := group["name"].(string)
		if name == "" {
			continue
		}
		explicitMembers := stringList(group["proxies"])
		members := make([]string, 0, len(explicitMembers))
		for _, member := range explicitMembers {
			if providerMembers, isProvider := providerNodes[member]; isProvider {
				members = append(members,
					filterOfflineNames(providerMembers, group, inlineTypes, providerNodeTypes)...)
				continue
			}
			members = append(members, member)
		}
		uses := stringList(group["use"])
		if include, _ := group["include-all"].(bool); include {
			group["include-all-proxies"] = true
			group["include-all-providers"] = true
		}
		if include, _ := group["include-all-proxies"].(bool); include {
			members = append(members,
				filterOfflineNames(inlineNames, group, inlineTypes, providerNodeTypes)...)
		}
		if include, _ := group["include-all-providers"].(bool); include {
			uses = append(uses, providerNames...)
		}
		providerMembers := make([]string, 0)
		for _, providerName := range uses {
			providerMembers = append(providerMembers, providerNodes[providerName]...)
		}
		members = append(members, filterOfflineNames(providerMembers, group, inlineTypes, providerNodeTypes)...)
		members = uniqueStrings(members)
		typ, _ := group["type"].(string)
		icon, _ := group["icon"].(string)
		now := ""
		if selected := selections[name]; strings.EqualFold(typ, "select") && containsString(members, selected) {
			now = selected
		} else if strings.EqualFold(typ, "select") && len(members) > 0 {
			now = members[0]
		}
		groups[name] = map[string]any{
			"type": offlineGroupType(typ), "now": now, "all": members, "icon": icon,
		}
		groupNames = append(groupNames, name)
	}

	globalMembers := append([]string{}, groupNames...)
	globalMembers = append(globalMembers, inlineNames...)
	for _, providerName := range providerNames {
		globalMembers = append(globalMembers, providerNodes[providerName]...)
	}
	globalMembers = uniqueStrings(globalMembers)
	globalNow := ""
	if selected := selections["GLOBAL"]; containsString(globalMembers, selected) {
		globalNow = selected
	} else if len(globalMembers) > 0 {
		globalNow = globalMembers[0]
	}
	groups["GLOBAL"] = map[string]any{
		"type": "Selector", "now": globalNow, "all": globalMembers, "icon": "",
	}
	mode, _ := raw["mode"].(string)
	if mode == "" {
		mode = "rule"
	}
	return marshalJSON(map[string]any{
		"proxies": groups, "details": details, "mode": strings.ToLower(mode),
		"missingProviders": missingProviders, "nodeCount": len(details),
	})
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func parseProviderPayload(payload string) ([]map[string]any, error) {
	var root map[string]any
	if err := yaml.Unmarshal([]byte(payload), &root); err != nil {
		return nil, err
	}
	raw, ok := root["proxies"].([]any)
	if !ok {
		return nil, fmt.Errorf("provider payload 缺少 proxies 列表")
	}
	proxies := make([]map[string]any, 0, len(raw))
	for _, item := range raw {
		if proxy, ok := item.(map[string]any); ok {
			proxies = append(proxies, proxy)
		}
	}
	return proxies, nil
}

func filterOfflineProxies(proxies []map[string]any, definition map[string]any) []map[string]any {
	include := compileOptionalRegex(definition["filter"])
	exclude := compileOptionalRegex(definition["exclude-filter"])
	includeTypes := lowerStringSet(definition["include-type"])
	excludeTypes := lowerStringSet(definition["exclude-type"])
	out := make([]map[string]any, 0, len(proxies))
	for _, proxy := range proxies {
		name, _ := proxy["name"].(string)
		typ, _ := proxy["type"].(string)
		lowerType := strings.ToLower(typ)
		if len(include) > 0 && !matchesAnyRegex(include, name) || matchesAnyRegex(exclude, name) {
			continue
		}
		if len(includeTypes) > 0 && !includeTypes[lowerType] || excludeTypes[lowerType] {
			continue
		}
		out = append(out, proxy)
	}
	return out
}

func filterOfflineNames(names []string, group map[string]any, inlineTypes, providerTypes map[string]string) []string {
	include := compileOptionalRegex(group["filter"])
	exclude := compileOptionalRegex(group["exclude-filter"])
	includeTypes := lowerStringSet(group["include-type"])
	excludeTypes := lowerStringSet(group["exclude-type"])
	out := make([]string, 0, len(names))
	for _, name := range names {
		typ := strings.ToLower(inlineTypes[name])
		if typ == "" {
			typ = strings.ToLower(providerTypes[name])
		}
		if len(include) > 0 && !matchesAnyRegex(include, name) || matchesAnyRegex(exclude, name) {
			continue
		}
		if len(includeTypes) > 0 && typ != "" && !includeTypes[typ] || (typ != "" && excludeTypes[typ]) {
			continue
		}
		out = append(out, name)
	}
	return out
}

func compileOptionalRegex(value any) []*regexp2.Regexp {
	pattern, _ := value.(string)
	if strings.TrimSpace(pattern) == "" {
		return nil
	}
	patterns := strings.Split(pattern, "`")
	compiled := make([]*regexp2.Regexp, 0, len(patterns))
	for _, part := range patterns {
		regex, err := regexp2.Compile(part, regexp2.None)
		if err != nil {
			return nil
		}
		compiled = append(compiled, regex)
	}
	return compiled
}

func matchesAnyRegex(patterns []*regexp2.Regexp, value string) bool {
	for _, pattern := range patterns {
		if matched, _ := pattern.MatchString(value); matched {
			return true
		}
	}
	return false
}

func lowerStringSet(value any) map[string]bool {
	result := map[string]bool{}
	values := stringList(value)
	if text, ok := value.(string); ok {
		values = strings.Split(text, "|")
	}
	for _, item := range values {
		if item = strings.TrimSpace(item); item != "" {
			result[strings.ToLower(item)] = true
		}
	}
	return result
}

func stringList(value any) []string {
	raw, _ := value.([]any)
	out := make([]string, 0, len(raw))
	for _, item := range raw {
		if text, ok := item.(string); ok {
			out = append(out, text)
		}
	}
	return out
}

func uniqueStrings(values []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(values))
	for _, value := range values {
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		out = append(out, value)
	}
	return out
}

func offlineGroupType(value string) string {
	switch strings.ToLower(value) {
	case "select":
		return "Selector"
	case "url-test":
		return "URLTest"
	case "load-balance":
		return "LoadBalance"
	case "fallback":
		return "Fallback"
	case "relay":
		return "Relay"
	default:
		return value
	}
}

func marshalJSON(value any) string {
	out, err := json.Marshal(value)
	if err != nil {
		return `{}`
	}
	return string(out)
}

// SelectProxy 在指定策略组里选定某节点（等价 REST PUT /proxies/{name}）。
// 仅 Selector 类策略组可选；URLTest/Fallback 等自动组不支持。
// 对应 Swift 侧 `MihomoSelectProxy(_:_:error:)`。
func SelectProxy(group, name string) error {
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
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
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
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
	// Some automatic groups ignore the URL supplied to ProxyGroup.URLTest and
	// use their configured health-check URL. Test their resolved members here so
	// the app's configured URL applies uniformly to every group type.
	dm := make(map[string]uint16)
	var delayMu sync.Mutex
	var wait sync.WaitGroup
	for _, proxy := range g.Proxies() {
		proxy := proxy
		wait.Add(1)
		go func() {
			defer wait.Done()
			delay, testErr := proxy.URLTest(ctx, url, expectedStatus)
			if testErr == nil && delay > 0 {
				delayMu.Lock()
				dm[proxy.Name()] = delay
				delayMu.Unlock()
			}
		}()
	}
	wait.Wait()
	if len(dm) == 0 {
		return `{"error":"测速地址不可达或全部节点超时"}`
	}
	out, err := json.Marshal(dm)
	if err != nil {
		return `{"error":"marshal: ` + err.Error() + `"}`
	}
	return string(out)
}

// ProxyDelay 对单个代理做延迟测试，供策略页节点卡片的长按菜单使用。
// 返回 {"delay": 毫秒}；失败返回 {"error": ...}。
func ProxyDelay(name, group, url string, timeoutMs int) string {
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
	p, exist := tunnel.Proxies()[name]
	if !exist && strings.TrimSpace(group) != "" {
		if parent, ok := tunnel.Proxies()[group]; ok {
			if proxyGroup, ok := parent.Adapter().(outboundgroup.ProxyGroup); ok {
				for _, member := range proxyGroup.Proxies() {
					if member.Name() == name {
						p = member
						exist = true
						break
					}
				}
			}
		}
	}
	if !exist {
		return `{"error":"节点不存在"}`
	}
	if url == "" {
		url = "https://www.gstatic.com/generate_204"
	}
	if timeoutMs <= 0 {
		timeoutMs = 5000
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Millisecond*time.Duration(timeoutMs))
	defer cancel()

	var expectedStatus utils.IntRanges[uint16]
	delay, err := p.URLTest(ctx, url, expectedStatus)
	if err != nil {
		return `{"error":"` + err.Error() + `"}`
	}
	if delay == 0 {
		return `{"error":"延迟测试失败"}`
	}
	out, err := json.Marshal(map[string]uint16{"delay": delay})
	if err != nil {
		return `{"error":"marshal: ` + err.Error() + `"}`
	}
	return string(out)
}

// Mode 返回当前模式字符串（rule/global/direct）。对应 Swift 侧 `MihomoMode()`。
func Mode() string {
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
	return tunnel.Mode().String()
}

// SetMode 设置模式（rule/global/direct，大小写不敏感，未知按 rule）。
// 对应 Swift 侧 `MihomoSetMode(_:)`。
func SetMode(mode string) {
	configApplyMu.Lock()
	defer configApplyMu.Unlock()
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "global":
		tunnel.SetMode(tunnel.Global)
	case "direct":
		tunnel.SetMode(tunnel.Direct)
	default:
		tunnel.SetMode(tunnel.Rule)
	}
}

// TrafficNow 返回当前每秒上下行速率与本次内核运行秒数。
// 取自 mihomo 统计管理器（与 REST /traffic 同源），对应 Swift 侧 `MihomoTrafficNow()`。
func TrafficNow() string {
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
	up, down := statistic.DefaultManager.Now()
	uptime := int64(0)
	if !coreStartedAt.IsZero() {
		uptime = int64(time.Since(coreStartedAt) / time.Second)
	}
	out, err := json.Marshal(map[string]int64{"up": up, "down": down, "uptime": uptime})
	if err != nil {
		return `{"up":0,"down":0,"uptime":0}`
	}
	return string(out)
}

// ConnectionsSnapshot returns a bounded, newest-first connection list for the
// app-owned IPC channel. A limit of zero is a totals-only request, used by the
// overview polling path to avoid encoding connection details in the NE process.
// Bounding the list avoids large REST-style snapshots creating avoidable
// encode/decode peaks in the Network Extension process.
func ConnectionsSnapshot(limit int) string {
	uploadTotal, downloadTotal := statistic.DefaultManager.Total()
	if limit == 0 {
		out, err := json.Marshal(struct {
			DownloadTotal int64                    `json:"downloadTotal"`
			UploadTotal   int64                    `json:"uploadTotal"`
			Connections   []*statistic.TrackerInfo `json:"connections"`
			Total         int                      `json:"total"`
			Truncated     bool                     `json:"truncated"`
		}{
			DownloadTotal: downloadTotal,
			UploadTotal:   uploadTotal,
			Connections:   make([]*statistic.TrackerInfo, 0),
		})
		if err != nil {
			return `{"downloadTotal":0,"uploadTotal":0,"connections":[],"total":0,"truncated":false}`
		}
		return string(out)
	}
	if limit < 0 {
		limit = defaultConnectionSnapshotLimit
	} else if limit > maxConnectionSnapshotLimit {
		limit = maxConnectionSnapshotLimit
	}

	connections := make([]*statistic.TrackerInfo, 0, limit)
	statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
		if info := tracker.Info(); info != nil {
			connections = append(connections, info)
		}
		return true
	})
	sort.Slice(connections, func(left, right int) bool {
		return connections[left].Start.After(connections[right].Start)
	})
	total := len(connections)
	if len(connections) > limit {
		connections = connections[:limit]
	}
	out, err := json.Marshal(struct {
		DownloadTotal int64                    `json:"downloadTotal"`
		UploadTotal   int64                    `json:"uploadTotal"`
		Connections   []*statistic.TrackerInfo `json:"connections"`
		Total         int                      `json:"total"`
		Truncated     bool                     `json:"truncated"`
	}{
		DownloadTotal: downloadTotal,
		UploadTotal:   uploadTotal,
		Connections:   connections,
		Total:         total,
		Truncated:     total > len(connections),
	})
	if err != nil {
		return `{"downloadTotal":0,"uploadTotal":0,"connections":[],"total":0,"truncated":false}`
	}
	return string(out)
}

// CloseConnection closes one tracked connection through the app-owned IPC.
func CloseConnection(id string) error {
	id = strings.TrimSpace(id)
	if id == "" {
		return fmt.Errorf("连接 ID 为空")
	}
	tracker := statistic.DefaultManager.Get(id)
	if tracker == nil {
		return fmt.Errorf("连接不存在或已结束")
	}
	return tracker.Close()
}

// CloseAllConnections closes every tracked connection and returns the number
// of close attempts.
func CloseAllConnections() int {
	closed := 0
	statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
		_ = tracker.Close()
		closed++
		return true
	})
	return closed
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
	name = strings.TrimSpace(name)
	if name == "" {
		return
	}
	configApplyMu.Lock()
	defer configApplyMu.Unlock()
	storePhysicalInterface(name)
	dialer.DefaultInterface.Store(name)
	appendRunLog("默认出站接口 = " + name)
}

// NotifyNetworkChange refreshes the physical interface and scoped system DNS.
// resetConnections is true only when the old transport path is no longer safe;
// a DNS-only refresh rebuilds the resolver without interrupting app connections.
func NotifyNetworkChange(name string, systemDNSJSON string, reason string,
	resetConnections bool) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil
	}
	reason = strings.TrimSpace(reason)
	if reason == "" {
		reason = "网络状态变化"
	}
	newSystemDNS, dnsErr := parseSystemDNSJSON(systemDNSJSON)
	configApplyMu.Lock()
	defer configApplyMu.Unlock()
	storePhysicalInterface(name)
	previous := dialer.DefaultInterface.Load()
	dialer.DefaultInterface.Store(name)
	resetConnections = networkChangeRequiresReset(previous, name, resetConnections)
	if resetConnections {
		iface.FlushCache()
	}

	resolverUpdated := false
	if dnsErr == nil && len(newSystemDNS) > 0 &&
		!equalStringSlices(newSystemDNS, activeSystemDNS) {
		updated, replacements := replaceActiveSystemDNSLocked(newSystemDNS)
		if updated {
			rebuildDNSResolverLocked(activeDNSConfig, activeGeneralIPv6)
			resolverUpdated = true
			appendRunLog(fmt.Sprintf("system DNS 已按接口 %s 更新为 %s（替换 %d 处）",
				name, strings.Join(newSystemDNS, ","), replacements))
		} else if activeUsesSystemDNS {
			appendRunLog(fmt.Sprintf("接口 %s 已读取到新的 system DNS %s，但未匹配到运行中的旧 DNS；保留旧 DNS 等待下次刷新",
				name, strings.Join(newSystemDNS, ",")))
		} else {
			appendRunLog(fmt.Sprintf("接口 %s 的 system DNS 已更新为 %s，当前配置未引用 system",
				name, strings.Join(newSystemDNS, ",")))
		}
	}
	if resolverUpdated || resetConnections {
		resolver.ResetConnection()
	}

	if resetConnections {
		closed := 0
		statistic.DefaultManager.Range(func(connection statistic.Tracker) bool {
			_ = connection.Close()
			closed++
			return true
		})
		path := name
		if previous != "" && previous != name {
			path = previous + " -> " + name
		}
		appendRunLog(fmt.Sprintf("网络路径刷新（%s）：%s，已关闭 %d 条旧连接",
			reason, path, closed))
	} else {
		appendRunLog(fmt.Sprintf("网络状态刷新（%s）：接口 %s，未关闭活动连接",
			reason, name))
	}
	if dnsErr != nil {
		appendRunLog("忽略无效的 scoped system DNS: " + dnsErr.Error())
	}
	return dnsErr
}

func networkChangeRequiresReset(previous, current string, requested bool) bool {
	return requested || previous != current
}

func parseSystemDNSJSON(raw string) ([]string, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	var values []string
	if err := json.Unmarshal([]byte(raw), &values); err != nil {
		return nil, fmt.Errorf("system DNS JSON 无效: %w", err)
	}
	result := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		address, err := netip.ParseAddr(value)
		if err != nil || address.IsUnspecified() || address.IsMulticast() {
			return nil, fmt.Errorf("system DNS 地址无效: %q", value)
		}
		if address.Is4In6() {
			address = address.Unmap()
		}
		normalized := address.String()
		if _, exists := seen[normalized]; exists {
			continue
		}
		seen[normalized] = struct{}{}
		result = append(result, normalized)
	}
	return result, nil
}

func replaceActiveSystemDNSLocked(newSystemDNS []string) (bool, int) {
	if activeDNSConfig == nil || !activeUsesSystemDNS {
		activeSystemDNS = append(activeSystemDNS[:0], newSystemDNS...)
		return false, 0
	}

	updated := *activeDNSConfig
	replacements := 0
	updated.NameServer, replacements = replaceSystemNameServers(
		activeDNSConfig.NameServer, activeSystemDNS, newSystemDNS)
	updated.Fallback, replacements = replaceSystemNameServersAdding(
		activeDNSConfig.Fallback, activeSystemDNS, newSystemDNS, replacements)
	updated.DefaultNameserver, replacements = replaceSystemNameServersAdding(
		activeDNSConfig.DefaultNameserver, activeSystemDNS, newSystemDNS, replacements)
	updated.ProxyServerNameserver, replacements = replaceSystemNameServersAdding(
		activeDNSConfig.ProxyServerNameserver, activeSystemDNS, newSystemDNS, replacements)
	updated.DirectNameServer, replacements = replaceSystemNameServersAdding(
		activeDNSConfig.DirectNameServer, activeSystemDNS, newSystemDNS, replacements)
	updated.NameServerPolicy, replacements = replaceSystemPolicies(
		activeDNSConfig.NameServerPolicy, activeSystemDNS, newSystemDNS, replacements)
	updated.ProxyServerPolicy, replacements = replaceSystemPolicies(
		activeDNSConfig.ProxyServerPolicy, activeSystemDNS, newSystemDNS, replacements)

	if replacements == 0 {
		return false, 0
	}
	activeSystemDNS = append(activeSystemDNS[:0], newSystemDNS...)
	activeDNSConfig = &updated
	return true, replacements
}

func replaceSystemNameServersAdding(servers []mdns.NameServer, oldSystemDNS,
	newSystemDNS []string, count int) ([]mdns.NameServer, int) {
	updated, added := replaceSystemNameServers(servers, oldSystemDNS, newSystemDNS)
	return updated, count + added
}

func replaceSystemPolicies(policies []mdns.Policy, oldSystemDNS, newSystemDNS []string,
	count int) ([]mdns.Policy, int) {
	updated := append([]mdns.Policy(nil), policies...)
	for index := range updated {
		updated[index].NameServers, count = replaceSystemNameServersAdding(
			policies[index].NameServers, oldSystemDNS, newSystemDNS, count)
	}
	return updated, count
}

func replaceSystemNameServers(servers []mdns.NameServer, oldSystemDNS,
	newSystemDNS []string) ([]mdns.NameServer, int) {
	updated := make([]mdns.NameServer, 0, len(servers)+len(newSystemDNS))
	replacements := 0
	inserted := false
	for _, server := range servers {
		if !isInjectedSystemNameServer(server, oldSystemDNS) {
			updated = appendUniqueNameServer(updated, server)
			continue
		}
		replacements++
		if inserted {
			continue
		}
		inserted = true
		for _, address := range newSystemDNS {
			replacement := server
			// mihomo uses an empty Net value for its canonical UDP nameserver.
			replacement.Net = ""
			replacement.Addr = systemNameServerAddress(address)
			updated = appendUniqueNameServer(updated, replacement)
		}
	}
	return updated, replacements
}

func isInjectedSystemNameServer(server mdns.NameServer, oldSystemDNS []string) bool {
	if server.Net == "system" {
		return true
	}
	// Parsed udp:// nameservers use an empty Net value. Accept "udp" too for
	// callers that construct NameServer values directly.
	if server.Net != "" && server.Net != "udp" {
		return false
	}
	for _, address := range oldSystemDNS {
		if server.Addr == systemNameServerAddress(address) {
			return true
		}
	}
	return false
}

func systemNameServerAddress(address string) string {
	return net.JoinHostPort(address, "53")
}

func appendUniqueNameServer(servers []mdns.NameServer,
	server mdns.NameServer) []mdns.NameServer {
	for _, existing := range servers {
		if existing.Equal(server) {
			return servers
		}
	}
	return append(servers, server)
}

func equalStringSlices(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func rebuildDNSResolverLocked(c *config.DNS, generalIPv6 bool) {
	if c == nil || !c.Enable {
		return
	}
	ipv6 := c.IPv6 && generalIPv6
	dnsResolver := mdns.NewResolver(mdns.Config{
		Main:                 c.NameServer,
		Fallback:             c.Fallback,
		IPv6:                 ipv6,
		IPv6Timeout:          c.IPv6Timeout,
		FallbackIPFilter:     c.FallbackIPFilter,
		FallbackDomainFilter: c.FallbackDomainFilter,
		FallbackLazyQuery:    c.FallbackLazyQuery,
		Default:              c.DefaultNameserver,
		Policy:               c.NameServerPolicy,
		ProxyServer:          c.ProxyServerNameserver,
		ProxyServerPolicy:    c.ProxyServerPolicy,
		DirectServer:         c.DirectNameServer,
		DirectFollowPolicy:   c.DirectFollowPolicy,
		CacheAlgorithm:       c.CacheAlgorithm,
		CacheMaxSize:         c.CacheMaxSize,
	})
	enhancer := mdns.NewEnhancer(mdns.EnhancerConfig{
		IPv6:          ipv6,
		EnhancedMode:  c.EnhancedMode,
		FakeIPPool:    c.FakeIPPool,
		FakeIPPool6:   c.FakeIPPool6,
		FakeIPSkipper: c.FakeIPSkipper,
		FakeIPTTL:     c.FakeIPTTL,
		UseHosts:      c.UseHosts,
	})
	if old, ok := resolver.DefaultHostMapper.(*mdns.ResolverEnhancer); ok {
		enhancer.PatchFrom(old)
	}
	service := mdns.NewService(dnsResolver, enhancer)
	resolver.DefaultResolver = dnsResolver
	resolver.DefaultHostMapper = enhancer
	resolver.DefaultService = service
	resolver.UseSystemHosts = c.UseSystemHosts
	if dnsResolver.ProxyResolver.Invalid() {
		resolver.ProxyServerHostResolver = dnsResolver.ProxyResolver
	} else {
		resolver.ProxyServerHostResolver = dnsResolver.Resolver
	}
	if dnsResolver.DirectResolver.Invalid() {
		resolver.DirectHostResolver = dnsResolver.DirectResolver
	} else {
		resolver.DirectHostResolver = dnsResolver.Resolver
	}
	listenConfig := inbound.NewListenConfig()
	listenConfig.SetRouteMark(c.ListenRoutingMark)
	mdns.ReCreateServer(c.Listen, listenConfig, service)
}

// Stop 关闭内核与所有监听器。对应 Swift 侧 `MihomoStop()`。
func Stop() {
	configApplyMu.Lock()
	defer configApplyMu.Unlock()
	appendRunLog("Stop: 关闭内核")
	storePhysicalInterface("")
	activeDNSConfig = nil
	activeSystemDNS = nil
	activeGeneralIPv6 = false
	activeUsesSystemDNS = false
	coreStartedAt = time.Time{}
	CloseAllConnections()
	executor.Shutdown()
}

func storePhysicalInterface(name string) {
	interfaceMu.Lock()
	physicalIface = name
	interfaceMu.Unlock()
}

func currentPhysicalInterface() string {
	interfaceMu.RLock()
	name := physicalIface
	interfaceMu.RUnlock()
	return name
}

// appendRunLog 追加一行到 <home>/run.log（封装层自己的标记，便于和内核日志混排）。
func appendRunLog(msg string) {
	if homeDir == "" {
		return
	}
	logFileMu.Lock()
	defer logFileMu.Unlock()
	line := fmt.Sprintf("%s [WRAP] %s\n", logTimestamp(), msg)
	if runLogFile != nil {
		writeRunLogLine(runLogFile, line)
		return
	}
	f, err := os.OpenFile(filepath.Join(homeDir, "run.log"),
		os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.Seek(0, io.SeekEnd)
	writeRunLogLine(f, line)
}

func logTimestamp() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05.000Z07:00")
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
	if runLogBytes < 0 {
		if info, err := file.Stat(); err == nil {
			runLogBytes = info.Size()
		}
	}
	if runLogBytes >= 0 && runLogBytes+int64(len(line)) > maxRunLogBytes {
		if err := file.Truncate(0); err == nil {
			_, _ = file.Seek(0, io.SeekStart)
			runLogBytes = 0
			runLogGeneration++
		}
	}
	written, _ := file.WriteString(line)
	if runLogBytes >= 0 {
		runLogBytes += int64(written)
	}
}

// RunLogChunk returns complete log data after offset together with a generation
// token. A negative offset requests only the latest bounded tail. The token lets
// the app detect startup truncation even if the new file has already regrown
// beyond the previous byte offset.
func RunLogChunk(offset int, generation int) string {
	type response struct {
		Offset     int64  `json:"offset"`
		Generation int64  `json:"generation"`
		Reset      bool   `json:"reset"`
		Text       string `json:"text"`
		Error      string `json:"error,omitempty"`
	}

	logFileMu.Lock()
	defer logFileMu.Unlock()
	result := response{Generation: runLogGeneration}
	if homeDir == "" {
		result.Error = "日志目录尚未初始化"
		out, _ := json.Marshal(result)
		return string(out)
	}
	f, err := os.Open(filepath.Join(homeDir, "run.log"))
	if err != nil {
		result.Error = err.Error()
		out, _ := json.Marshal(result)
		return string(out)
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		result.Error = err.Error()
		out, _ := json.Marshal(result)
		return string(out)
	}

	start := int64(offset)
	result.Reset = int64(generation) != runLogGeneration
	if start < 0 {
		start = info.Size() - defaultRunLogChunkBytes
		if start < 0 {
			start = 0
		}
		result.Reset = true
	} else if result.Reset || start > info.Size() {
		start = 0
		result.Reset = true
	}

	buffer := make([]byte, defaultRunLogChunkBytes)
	read, readErr := f.ReadAt(buffer, start)
	if readErr != nil && readErr != io.EOF {
		result.Error = readErr.Error()
		result.Offset = start
		out, _ := json.Marshal(result)
		return string(out)
	}
	data := buffer[:read]
	if offset < 0 && start > 0 {
		if newline := bytes.IndexByte(data, '\n'); newline >= 0 {
			start += int64(newline + 1)
			data = data[newline+1:]
		}
	}
	if lastNewline := bytes.LastIndexByte(data, '\n'); lastNewline >= 0 {
		data = data[:lastNewline+1]
	} else if len(data) < len(buffer) {
		data = nil
	}
	result.Offset = start + int64(len(data))
	result.Text = string(data)
	out, _ := json.Marshal(result)
	return string(out)
}

// 每次真实启动都开启新的 run.log 会话。日志页在内存中保留上一会话，因此这里截断
// 不会让用户断开后看不到日志，同时避免同一 NE 进程重连时重复读取历史内容。
func resetRunLog() error {
	if homeDir == "" {
		return nil
	}
	logFileMu.Lock()
	defer logFileMu.Unlock()
	if runLogFile != nil {
		if err := runLogFile.Truncate(0); err != nil {
			return err
		}
		runLogBytes = 0
		runLogGeneration++
		_, err := runLogFile.Seek(0, io.SeekStart)
		return err
	}
	f, err := os.OpenFile(filepath.Join(homeDir, "run.log"),
		os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	runLogBytes = 0
	runLogGeneration++
	return f.Close()
}
