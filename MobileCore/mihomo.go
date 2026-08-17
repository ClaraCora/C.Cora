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
	"container/heap"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	stdHTTP "github.com/metacubex/http"
	"net/url"
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
	"github.com/metacubex/mihomo/component/ca"
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

const (
	maxScriptRequestBodyBytes    = 32 << 10
	maxScriptResponseBodyBytes   = 256 << 10
	maxScriptRequestTimeoutMs    = 10_000
	maxScriptRequestCountPerRun  = 12
)

const controlProtocolVersion = 1

const defaultConnectionSnapshotLimit = 200

const maxConnectionSnapshotLimit = 500

const defaultRunLogChunkBytes = 48 << 10

// connectionSnapshotHeap keeps only the oldest item at its root, allowing the
// IPC snapshot to select the newest live connections without allocating a
// slice proportional to the total number of active trackers.
type connectionSnapshotHeap []*statistic.TrackerInfo

func (items connectionSnapshotHeap) Len() int { return len(items) }

func (items connectionSnapshotHeap) Less(left, right int) bool {
	return items[left].Start.Before(items[right].Start)
}

func (items connectionSnapshotHeap) Swap(left, right int) {
	items[left], items[right] = items[right], items[left]
}

func (items *connectionSnapshotHeap) Push(value any) {
	*items = append(*items, value.(*statistic.TrackerInfo))
}

func (items *connectionSnapshotHeap) Pop() any {
	old := *items
	last := len(old) - 1
	value := old[last]
	*items = old[:last]
	return value
}

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
	UnifiedDelay      bool                   `json:"unifiedDelay"`
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
	s := appSettings{Stack: "gvisor", LogLevel: "info", UnifiedDelay: true,
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
	m["unified-delay"] = st.UnifiedDelay

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
	// DNS URL 的 #名称区分大小写。名称写错时 mihomo 会把它当作物理接口，
	// 查询在建立普通连接之前即失败，因此浏览器只显示“找不到服务器”。
	normalizeDNSProxyReferences(m)

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

func normalizeDNSProxyReferences(root map[string]any) {
	dnsConfig, ok := root["dns"].(map[string]any)
	if !ok {
		return
	}

	exactNames := map[string]struct{}{
		"DIRECT": {}, "REJECT": {}, "GLOBAL": {}, "PASS": {}, "RULES": {},
	}
	for _, section := range []string{"proxies", "proxy-groups"} {
		items, _ := root[section].([]any)
		for _, item := range items {
			definition, _ := item.(map[string]any)
			name, _ := definition["name"].(string)
			if name = strings.TrimSpace(name); name != "" {
				exactNames[name] = struct{}{}
			}
		}
	}

	foldedNames := map[string]string{}
	ambiguousNames := map[string]bool{}
	for name := range exactNames {
		folded := strings.ToLower(name)
		if existing, exists := foldedNames[folded]; exists && existing != name {
			ambiguousNames[folded] = true
			continue
		}
		foldedNames[folded] = name
	}

	corrected := map[string]string{}
	unresolved := map[string]bool{}
	normalize := func(value any) any {
		return normalizeDNSReferenceValue(value, exactNames, foldedNames,
			ambiguousNames, corrected, unresolved)
	}
	for _, key := range []string{
		"nameserver", "fallback", "default-nameserver",
		"proxy-server-nameserver", "direct-nameserver",
	} {
		if value, exists := dnsConfig[key]; exists {
			dnsConfig[key] = normalize(value)
		}
	}
	for _, key := range []string{"nameserver-policy", "proxy-server-nameserver-policy"} {
		if policy, ok := dnsConfig[key].(map[string]any); ok {
			for rule, value := range policy {
				policy[rule] = normalize(value)
			}
		}
	}

	if len(corrected) > 0 {
		pairs := make([]string, 0, len(corrected))
		for original, replacement := range corrected {
			pairs = append(pairs, original+" → "+replacement)
		}
		sort.Strings(pairs)
		configNotices = append(configNotices,
			"已纠正 DNS 出站策略名称大小写："+strings.Join(pairs, "、"))
	}
	if len(unresolved) > 0 {
		names := make([]string, 0, len(unresolved))
		for name := range unresolved {
			names = append(names, name)
		}
		sort.Strings(names)
		configNotices = append(configNotices,
			"DNS 出站名称未匹配配置内策略，将被当作网络接口使用，请检查："+
				strings.Join(names, "、"))
	}
}

func normalizeDNSReferenceValue(value any, exactNames map[string]struct{},
	foldedNames map[string]string, ambiguousNames map[string]bool,
	corrected map[string]string, unresolved map[string]bool) any {
	switch typed := value.(type) {
	case string:
		return normalizeDNSReferenceString(typed, exactNames, foldedNames,
			ambiguousNames, corrected, unresolved)
	case []any:
		out := make([]any, len(typed))
		for index, item := range typed {
			out[index] = normalizeDNSReferenceValue(item, exactNames, foldedNames,
				ambiguousNames, corrected, unresolved)
		}
		return out
	default:
		return value
	}
}

func normalizeDNSReferenceString(value string, exactNames map[string]struct{},
	foldedNames map[string]string, ambiguousNames map[string]bool,
	corrected map[string]string, unresolved map[string]bool) string {
	prefix, fragment, found := strings.Cut(value, "#")
	if !found || fragment == "" {
		return value
	}
	parts := strings.Split(fragment, "&")
	changed := false
	for index, part := range parts {
		if part == "" || strings.Contains(part, "=") {
			continue
		}
		if _, exists := exactNames[part]; exists {
			continue
		}
		folded := strings.ToLower(part)
		if replacement, exists := foldedNames[folded]; exists && !ambiguousNames[folded] {
			parts[index] = replacement
			corrected[part] = replacement
			changed = true
			continue
		}
		if !looksLikeNetworkInterface(part) {
			unresolved[part] = true
		}
	}
	if !changed {
		return value
	}
	return prefix + "#" + strings.Join(parts, "&")
}

func looksLikeNetworkInterface(name string) bool {
	lower := strings.ToLower(strings.TrimSpace(name))
	for _, prefix := range []string{"en", "utun", "pdp_ip", "lo", "eth", "wlan", "rmnet"} {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	return false
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

type remoteRuleProvider struct {
	Name     string `json:"name"`
	URL      string `json:"url"`
	Behavior string `json:"behavior,omitempty"`
	Format   string `json:"format,omitempty"`
}

// ProxyProviderManifest extracts the HTTP proxy providers that the main App
// may download and cache while the tunnel is disconnected. It only parses
// YAML and never initializes mihomo runtime providers.
func ProxyProviderManifest(configYAML string) string {
	var raw map[string]any
	if err := yaml.Unmarshal([]byte(configYAML), &raw); err != nil {
		return marshalJSON(map[string]any{"providers": []remoteProxyProvider{}, "error": err.Error()})
	}
	return marshalJSON(map[string]any{"providers": remoteProxyProviders(raw)})
}

// RemoteResourceManifest extracts every HTTP Proxy Provider and Rule Provider
// without initializing the runtime. The main App uses it to present resources
// from disconnected configurations as well as the active one.
func RemoteResourceManifest(configYAML string) string {
	var raw map[string]any
	if err := yaml.Unmarshal([]byte(configYAML), &raw); err != nil {
		return marshalJSON(map[string]any{
			"proxyProviders": []remoteProxyProvider{},
			"ruleProviders":  []remoteRuleProvider{},
			"error":          err.Error(),
		})
	}
	return marshalJSON(map[string]any{
		"proxyProviders": remoteProxyProviders(raw),
		"ruleProviders":  remoteRuleProviders(raw),
	})
}

func remoteProxyProviders(raw map[string]any) []remoteProxyProvider {
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
	return out
}

func remoteRuleProviders(raw map[string]any) []remoteRuleProvider {
	providers, _ := raw["rule-providers"].(map[string]any)
	names := make([]string, 0, len(providers))
	for name := range providers {
		names = append(names, name)
	}
	sort.Strings(names)
	out := make([]remoteRuleProvider, 0, len(names))
	for _, name := range names {
		definition, _ := providers[name].(map[string]any)
		providerType, _ := definition["type"].(string)
		providerURL, _ := definition["url"].(string)
		if !strings.EqualFold(strings.TrimSpace(providerType), "http") || strings.TrimSpace(providerURL) == "" {
			continue
		}
		behavior, _ := definition["behavior"].(string)
		format, _ := definition["format"].(string)
		out = append(out, remoteRuleProvider{
			Name:     name,
			URL:      strings.TrimSpace(providerURL),
			Behavior: strings.TrimSpace(behavior),
			Format:   strings.TrimSpace(format),
		})
	}
	return out
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
	return updateRuntimeProviders(names, func(name string) error { return providers[name].Update() })
}

// UpdateProxyProvider refreshes one named HTTP Proxy Provider in the active runtime.
func UpdateProxyProvider(name string) string {
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
	providers := tunnel.Providers()
	provider, ok := providers[name]
	if !ok {
		return providerNotFoundResponse(name)
	}
	if provider.VehicleType() != P.HTTP {
		return providerWrongVehicleResponse(name)
	}
	return updateRuntimeProviders([]string{name}, func(string) error { return provider.Update() })
}

// UpdateRuleProviders refreshes all HTTP Rule Providers in the active runtime.
func UpdateRuleProviders() string {
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
	providers := tunnel.RuleProviders()
	names := make([]string, 0, len(providers))
	for name, provider := range providers {
		if provider.VehicleType() == P.HTTP {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return updateRuntimeProviders(names, func(name string) error { return providers[name].Update() })
}

// UpdateRuleProvider refreshes one named HTTP Rule Provider in the active runtime.
func UpdateRuleProvider(name string) string {
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
	providers := tunnel.RuleProviders()
	provider, ok := providers[name]
	if !ok {
		return providerNotFoundResponse(name)
	}
	if provider.VehicleType() != P.HTTP {
		return providerWrongVehicleResponse(name)
	}
	return updateRuntimeProviders([]string{name}, func(string) error { return provider.Update() })
}

func updateRuntimeProviders(names []string, update func(string) error) string {
	updated := make([]string, 0, len(names))
	failures := map[string]string{}
	for _, name := range names {
		if err := update(name); err != nil {
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

func providerNotFoundResponse(name string) string {
	return marshalJSON(map[string]any{
		"ok":       false,
		"updated":  []string{},
		"failures": map[string]string{name: "provider not found"},
	})
}

func providerWrongVehicleResponse(name string) string {
	return marshalJSON(map[string]any{
		"ok":       false,
		"updated":  []string{},
		"failures": map[string]string{name: "provider is not an HTTP resource"},
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
// DIRECT 链路使用 directURL，其余节点使用 url。返回 {<节点名>: 毫秒} 的 JSON；
// 每个成员都会出现在结果中，失败或超时使用 0。
// 对应 Swift 侧 `MihomoGroupDelay(_:_:_:_:)`。
func GroupDelay(group, url, directURL string, timeoutMs int) string {
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
	proxies := tunnel.Proxies()
	p, exist := proxies[group]
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
	if directURL == "" {
		directURL = url
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
	members := g.Proxies()
	dm := make(map[string]uint16, len(members))
	for _, proxy := range members {
		dm[proxy.Name()] = 0
	}
	var delayMu sync.Mutex
	var wait sync.WaitGroup
	for _, proxy := range members {
		proxy := proxy
		wait.Add(1)
		go func() {
			defer wait.Done()
			testURL := delayURLForProxy(proxy, url, directURL, proxies)
			delay, testErr := proxy.URLTest(ctx, testURL, expectedStatus)
			if testErr == nil && delay > 0 {
				delayMu.Lock()
				dm[proxy.Name()] = delay
				delayMu.Unlock()
			}
		}()
	}
	wait.Wait()
	out, err := json.Marshal(dm)
	if err != nil {
		return `{"error":"marshal: ` + err.Error() + `"}`
	}
	return string(out)
}

// ProxyDelay 对单个代理做延迟测试，供策略页节点卡片的长按菜单使用。
// DIRECT 链路使用 directURL，其余节点使用 url。返回 {"delay": 毫秒}，超时为 0；
// 其他失败返回 {"error": ...}。
func ProxyDelay(name, group, url, directURL string, timeoutMs int) string {
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
	proxies := tunnel.Proxies()
	p, exist := proxies[name]
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
	if directURL == "" {
		directURL = url
	}
	if timeoutMs <= 0 {
		timeoutMs = 5000
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Millisecond*time.Duration(timeoutMs))
	defer cancel()

	var expectedStatus utils.IntRanges[uint16]
	delay, err := p.URLTest(ctx,
		delayURLForProxy(p, url, directURL, proxies), expectedStatus)
	if err != nil {
		if proxyDelayTimedOut(ctx, err) {
			return `{"delay":0}`
		}
		return `{"error":"` + err.Error() + `"}`
	}
	if delay == 0 {
		return `{"delay":0}`
	}
	out, err := json.Marshal(map[string]uint16{"delay": delay})
	if err != nil {
		return `{"error":"marshal: ` + err.Error() + `"}`
	}
	return string(out)
}

// RuleProviderContent returns the exact bytes currently loaded by one HTTP
// rule provider. The provider vehicle owns the cache path, so this never
// performs a second network request and cannot replace the running rules.
func RuleProviderContent(name string, maxBytes int) string {
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
	provider, ok := tunnel.RuleProviders()[strings.TrimSpace(name)]
	if !ok {
		return marshalJSON(map[string]any{"ok": false, "error": "规则来源不存在"})
	}
	vehicleProvider, ok := provider.(interface{ Vehicle() P.Vehicle })
	if !ok {
		return marshalJSON(map[string]any{"ok": false, "error": "当前内核不支持读取规则来源原文"})
	}
	path := vehicleProvider.Vehicle().Path()
	if path == "" {
		return marshalJSON(map[string]any{"ok": false, "error": "规则来源尚未落盘"})
	}
	if maxBytes <= 0 || maxBytes > 1<<20 {
		maxBytes = 1 << 20
	}
	info, statErr := os.Stat(path)
	if statErr != nil {
		return marshalJSON(map[string]any{"ok": false, "error": "规则来源尚未更新"})
	}
	file, err := os.Open(path)
	if err != nil {
		return marshalJSON(map[string]any{"ok": false, "error": "读取规则来源失败"})
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, int64(maxBytes)+1))
	if err != nil {
		return marshalJSON(map[string]any{"ok": false, "error": "读取规则来源失败"})
	}
	truncated := len(data) > maxBytes
	if truncated {
		data = data[:maxBytes]
	}
	return marshalJSON(map[string]any{
		"ok":        true,
		"content":  string(data),
		"size":     info.Size(),
		"updatedAt": info.ModTime().UTC().Format(time.RFC3339),
		"truncated": truncated,
	})
}

type scriptFetchRequest struct {
	Name         string            `json:"name"`
	Group        string            `json:"group"`
	Method       string            `json:"method"`
	URL          string            `json:"url"`
	Headers      map[string]string `json:"headers"`
	Body         string            `json:"body"`
	TimeoutMs    int               `json:"timeout"`
	AllowRedirect bool             `json:"allowRedirect"`
}

// ScriptFetch is the only network primitive exposed to Cora's JavaScript
// runner. It is intentionally HTTPS-only and always dials the named mihomo
// proxy; it never uses the system URLSession or the currently selected group.
func ScriptFetch(requestJSON string) string {
	var request scriptFetchRequest
	if err := json.Unmarshal([]byte(requestJSON), &request); err != nil {
		return marshalJSON(map[string]any{"ok": false, "error": "请求参数无效"})
	}
	if len(request.Body) > maxScriptRequestBodyBytes {
		return marshalJSON(map[string]any{"ok": false, "error": "脚本请求体超过大小限制"})
	}
	rawURL := strings.TrimSpace(request.URL)
	u, err := url.Parse(rawURL)
	if err != nil || !strings.EqualFold(u.Scheme, "https") || u.Hostname() == "" || u.User != nil {
		return marshalJSON(map[string]any{"ok": false, "error": "脚本只允许 HTTPS 请求"})
	}
	method := strings.ToUpper(strings.TrimSpace(request.Method))
	if method == "" {
		method = stdHTTP.MethodGet
	}
	switch method {
	case stdHTTP.MethodGet, stdHTTP.MethodPost, stdHTTP.MethodHead:
	default:
		return marshalJSON(map[string]any{"ok": false, "error": "脚本只允许 GET、POST、HEAD"})
	}
	proxies := tunnel.Proxies()
	proxy, err := resolveScriptProxy(request.Name, request.Group, proxies)
	if err != nil {
		return marshalJSON(map[string]any{"ok": false, "error": err.Error()})
	}
	if proxy.Type() == C.Direct || proxy.Type() == C.Reject || proxy.Type() == C.RejectDrop {
		return marshalJSON(map[string]any{"ok": false, "error": "目标不是可用于解锁测试的代理节点"})
	}
	if request.TimeoutMs <= 0 || request.TimeoutMs > maxScriptRequestTimeoutMs {
		request.TimeoutMs = maxScriptRequestTimeoutMs
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(request.TimeoutMs)*time.Millisecond)
	defer cancel()
	port := u.Port()
	if port == "" {
		port = "443"
	}
	tlsConfig, err := ca.GetTLSConfig(ca.Option{})
	if err != nil {
		return marshalJSON(map[string]any{"ok": false, "error": "TLS 配置失败"})
	}
	transport := &stdHTTP.Transport{
		DialContext: func(dialCtx context.Context, _, address string) (net.Conn, error) {
			if _, _, splitErr := net.SplitHostPort(address); splitErr != nil {
				address = net.JoinHostPort(address, port)
			}
			var metadata C.Metadata
			if metadataErr := metadata.SetRemoteAddress(address); metadataErr != nil {
				return nil, metadataErr
			}
			return proxy.DialContext(dialCtx, &metadata)
		},
		DisableKeepAlives: true,
		TLSClientConfig: tlsConfig,
		TLSHandshakeTimeout: time.Duration(request.TimeoutMs) * time.Millisecond,
	}
	client := &stdHTTP.Client{Transport: transport}
	if !request.AllowRedirect {
		client.CheckRedirect = func(*stdHTTP.Request, []*stdHTTP.Request) error { return stdHTTP.ErrUseLastResponse }
	} else {
		client.CheckRedirect = func(next *stdHTTP.Request, via []*stdHTTP.Request) error {
			if len(via) >= 4 || next.URL == nil || !strings.EqualFold(next.URL.Scheme, "https") {
				return stdHTTP.ErrUseLastResponse
			}
			return nil
		}
	}
	defer client.CloseIdleConnections()
	var body io.Reader
	if request.Body != "" && method != stdHTTP.MethodHead {
		body = strings.NewReader(request.Body)
	}
	req, err := stdHTTP.NewRequest(method, rawURL, body)
	if err != nil {
		return marshalJSON(map[string]any{"ok": false, "error": "请求构造失败"})
	}
	req = req.WithContext(ctx)
	for key, value := range request.Headers {
		if strings.TrimSpace(key) != "" && len(value) <= 4096 {
			req.Header.Set(key, value)
		}
	}
	resp, err := client.Do(req)
	if err != nil {
		return marshalJSON(map[string]any{"ok": false, "error": "节点请求超时或失败"})
	}
	defer resp.Body.Close()
	data, readErr := io.ReadAll(io.LimitReader(resp.Body, maxScriptResponseBodyBytes+1))
	if readErr != nil {
		return marshalJSON(map[string]any{"ok": false, "error": "读取响应失败"})
	}
	truncated := len(data) > maxScriptResponseBodyBytes
	if truncated {
		data = data[:maxScriptResponseBodyBytes]
	}
	return marshalJSON(map[string]any{
		"ok":        true,
		"status":    resp.StatusCode,
		"body":      string(data),
		"truncated": truncated,
	})
}

func resolveScriptProxy(name, group string, proxies map[string]C.Proxy) (C.Proxy, error) {
	return resolveScriptProxyDepth(name, group, proxies, map[string]bool{}, 0)
}

func resolveScriptProxyDepth(name, group string, proxies map[string]C.Proxy, visited map[string]bool, depth int) (C.Proxy, error) {
	if depth > 12 {
		return nil, fmt.Errorf("策略组引用层级过深")
	}
	name = strings.TrimSpace(name)
	group = strings.TrimSpace(group)
	if name != "" {
		if proxy, ok := proxies[name]; ok {
			if visited[name] {
				return nil, fmt.Errorf("策略组引用存在循环")
			}
			if proxyGroup, ok := proxy.Adapter().(outboundgroup.ProxyGroup); ok {
				selected := strings.TrimSpace(proxyGroup.Now())
				if selected == "" {
					return nil, fmt.Errorf("策略组没有当前节点")
				}
				visited[name] = true
				return resolveScriptProxyDepth(selected, name, proxies, visited, depth+1)
			}
			return proxy, nil
		}
		if parent, ok := proxies[group]; ok {
			if proxyGroup, ok := parent.Adapter().(outboundgroup.ProxyGroup); ok {
				for _, member := range proxyGroup.Proxies() {
					if member.Name() == name {
						return member, nil
					}
				}
			}
		}
		return nil, fmt.Errorf("节点不存在")
	}
	if parent, ok := proxies[group]; ok {
		proxyGroup, ok := parent.Adapter().(outboundgroup.ProxyGroup)
		if !ok {
			return nil, fmt.Errorf("目标不是策略组")
		}
		selected := strings.TrimSpace(proxyGroup.Now())
		if selected == "" {
			return nil, fmt.Errorf("策略组没有当前节点")
		}
		return resolveScriptProxyDepth(selected, group, proxies, visited, depth+1)
	}
	return nil, fmt.Errorf("没有指定测试节点")
}

// delayURLForProxy follows the currently selected member of a strategy group.
// This makes a group such as "国内直连" use the domestic endpoint when its
// effective route is DIRECT, without relying on user-visible names.
func delayURLForProxy(proxy C.Proxy,
	proxyURL string,
	directURL string,
	all map[string]C.Proxy) string {
	if proxyUsesDirect(proxy, all, map[string]bool{}) {
		return directURL
	}
	return proxyURL
}

func proxyUsesDirect(proxy C.Proxy,
	all map[string]C.Proxy,
	visited map[string]bool) bool {
	if proxy == nil {
		return false
	}
	name := proxy.Name()
	if visited[name] {
		return false
	}
	visited[name] = true
	if proxy.Type() == C.Direct {
		return true
	}
	group, ok := proxy.Adapter().(outboundgroup.ProxyGroup)
	if !ok {
		return false
	}
	selected := group.Now()
	for _, member := range group.Proxies() {
		if member.Name() == selected {
			return proxyUsesDirect(member, all, visited)
		}
	}
	if member, ok := all[selected]; ok {
		return proxyUsesDirect(member, all, visited)
	}
	return false
}

func proxyDelayTimedOut(ctx context.Context, err error) bool {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) ||
		errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var networkError net.Error
	return errors.As(err, &networkError) && networkError.Timeout()
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

	connections := make(connectionSnapshotHeap, 0, limit)
	heap.Init(&connections)
	total := 0
	statistic.DefaultManager.Range(func(tracker statistic.Tracker) bool {
		if info := tracker.Info(); info != nil {
			total++
			if len(connections) < limit {
				heap.Push(&connections, info)
				return true
			}
			if info.Start.After(connections[0].Start) {
				connections[0] = info
				heap.Fix(&connections, 0)
			}
		}
		return true
	})
	sort.Slice(connections, func(left, right int) bool {
		return connections[left].Start.After(connections[right].Start)
	})
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

// ClosedConnectionsSnapshot returns a small batch of connection snapshots that
// have just left Mihomo's tracker manager. The manager's internal queue is
// capped at 512 entries and is drained by the Network Extension into its
// bounded SQLite history, never retained as a long-lived Go slice.
func ClosedConnectionsSnapshot(cursor int64, limit int) string {
	if cursor < 0 {
		cursor = 0
	}
	if limit < 1 {
		limit = 1
	} else if limit > 512 {
		limit = 512
	}
	next, dropped, connections := statistic.DefaultManager.ClosedSince(uint64(cursor), limit)
	out, err := json.Marshal(struct {
		Cursor      uint64                   `json:"cursor"`
		Dropped     bool                     `json:"dropped"`
		Connections []*statistic.TrackerInfo `json:"connections"`
	}{
		Cursor:      next,
		Dropped:     dropped,
		Connections: connections,
	})
	if err != nil {
		return `{"cursor":0,"dropped":false,"connections":[]}`
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
	// 旧运行时必须在下一次 StartWithConfig 前尽量归还 Go 堆页，
	// 避免完整 stop/start 重载在 NE 中形成短暂的内存峰值。
	runtime.GC()
	debug.FreeOSMemory()
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
