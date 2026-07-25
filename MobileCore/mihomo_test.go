package mihomo

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestValidateGeoDatabaseRejectsInvalidContent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "invalid.dat")
	if err := os.WriteFile(path, []byte("not a GEO database"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, kind := range []string{"mmdb", "asn", "geoip", "geosite", "unknown"} {
		if err := ValidateGeoDatabase(path, kind); err == nil {
			t.Errorf("ValidateGeoDatabase(%q) accepted invalid content", kind)
		}
	}
}

func TestRuntimeStatsReturnsDiagnosticSnapshot(t *testing.T) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(RuntimeStats()), &fields); err != nil {
		t.Fatalf("RuntimeStats returned invalid JSON: %v", err)
	}
	for _, key := range []string{"heapAlloc", "sys", "goroutines", "connections"} {
		if _, exists := fields[key]; !exists {
			t.Fatalf("RuntimeStats omitted %q", key)
		}
	}

	var snapshot struct {
		HeapAlloc   uint64 `json:"heapAlloc"`
		Sys         uint64 `json:"sys"`
		Goroutines  int    `json:"goroutines"`
		Connections int    `json:"connections"`
	}
	if err := json.Unmarshal([]byte(RuntimeStats()), &snapshot); err != nil {
		t.Fatalf("RuntimeStats returned invalid JSON: %v", err)
	}
	if snapshot.HeapAlloc == 0 || snapshot.Sys == 0 {
		t.Fatalf("RuntimeStats omitted memory counters: %+v", snapshot)
	}
	if snapshot.Goroutines < 1 {
		t.Fatalf("RuntimeStats goroutines = %d, want at least 1", snapshot.Goroutines)
	}
}

func TestTrimMemoryForcesGarbageCollection(t *testing.T) {
	var before runtime.MemStats
	runtime.ReadMemStats(&before)
	TrimMemory()
	var after runtime.MemStats
	runtime.ReadMemStats(&after)
	if after.NumForcedGC <= before.NumForcedGC {
		t.Fatalf("NumForcedGC = %d, want greater than %d", after.NumForcedGC, before.NumForcedGC)
	}
}

func TestConfigureRuntimeMemoryPolicy(t *testing.T) {
	unlimited := int64(^uint64(0) >> 1)
	previousGC := debug.SetGCPercent(100)
	previousLimit := debug.SetMemoryLimit(unlimited)
	defer func() {
		debug.SetGCPercent(previousGC)
		debug.SetMemoryLimit(previousLimit)
	}()

	configureRuntimeMemoryPolicy()
	if got := debug.SetGCPercent(100); got != mobileGCPercent {
		t.Fatalf("GOGC = %d, want %d", got, mobileGCPercent)
	}
	if got := debug.SetMemoryLimit(unlimited); got != mobileGoMemoryLimit {
		t.Fatalf("Go memory limit = %d, want %d", got, mobileGoMemoryLimit)
	}
}

func mergedMap(t *testing.T, input string) map[string]any {
	t.Helper()
	return mergedMapWithSettings(t, input, appSettings{Stack: "gvisor", LogLevel: "info"})
}

func mergedMapWithSettings(t *testing.T, input string, settings appSettings) map[string]any {
	t.Helper()
	out, err := mergeConfig(input, settings, 1420)
	if err != nil {
		t.Fatalf("mergeConfig: %v", err)
	}
	var m map[string]any
	if err := yaml.Unmarshal(out, &m); err != nil {
		t.Fatalf("unmarshal merged config: %v", err)
	}
	return m
}

func TestConfiguredTunMTU(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  int
	}{
		{name: "configured", input: "tun:\n  mtu: 1380\n", want: 1380},
		{name: "missing", input: "tun:\n  enable: true\n", want: 0},
		{name: "invalid string", input: "tun:\n  mtu: auto\n", want: 0},
		{name: "too small", input: "tun:\n  mtu: 1\n", want: 0},
		{name: "zero", input: "tun:\n  mtu: 0\n", want: 0},
		{name: "too large", input: "tun:\n  mtu: 65536\n", want: 0},
		{name: "invalid yaml", input: "tun: [", want: 0},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := ConfiguredTunMTU(test.input); got != test.want {
				t.Fatalf("ConfiguredTunMTU() = %d, want %d", got, test.want)
			}
		})
	}
}

func TestMergeConfigUsesConfiguredOrSystemMTU(t *testing.T) {
	settings := appSettings{Stack: "gvisor", LogLevel: "info"}

	configured, err := mergeConfig("tun:\n  mtu: 1380\n", settings, 1420)
	if err != nil {
		t.Fatal(err)
	}
	var configuredMap map[string]any
	if err := yaml.Unmarshal(configured, &configuredMap); err != nil {
		t.Fatal(err)
	}
	if got := nestedMap(t, configuredMap, "tun")["mtu"]; got != 1380 {
		t.Errorf("configured tun.mtu = %v, want 1380", got)
	}

	system, err := mergeConfig("tun:\n  enable: true\n", settings, 1420)
	if err != nil {
		t.Fatal(err)
	}
	var systemMap map[string]any
	if err := yaml.Unmarshal(system, &systemMap); err != nil {
		t.Fatal(err)
	}
	if got := nestedMap(t, systemMap, "tun")["mtu"]; got != 1420 {
		t.Errorf("system tun.mtu = %v, want 1420", got)
	}

	fallback, err := mergeConfig("", settings, 0)
	if err != nil {
		t.Fatal(err)
	}
	var fallbackMap map[string]any
	if err := yaml.Unmarshal(fallback, &fallbackMap); err != nil {
		t.Fatal(err)
	}
	if got := nestedMap(t, fallbackMap, "tun")["mtu"]; got != defaultTunnelMTU {
		t.Errorf("fallback tun.mtu = %v, want %d", got, defaultTunnelMTU)
	}

	for _, input := range []string{"tun:\n  mtu: 0\n", "tun:\n  mtu: null\n"} {
		merged, err := mergeConfig(input, settings, 1420)
		if err != nil {
			t.Fatal(err)
		}
		var result map[string]any
		if err := yaml.Unmarshal(merged, &result); err != nil {
			t.Fatal(err)
		}
		if got := nestedMap(t, result, "tun")["mtu"]; got != 1420 {
			t.Errorf("unset tun.mtu = %v, want system MTU 1420", got)
		}
	}

	if _, err := mergeConfig("tun:\n  mtu: auto\n", settings, 1420); err == nil {
		t.Error("invalid tun.mtu should fail configuration merge")
	}
	if _, err := mergeConfig("tun:\n  mtu: 1\n", settings, 1420); err == nil {
		t.Error("too-small tun.mtu should fail configuration merge")
	}

	tooSmallSystem, err := mergeConfig("", settings, 200)
	if err != nil {
		t.Fatal(err)
	}
	var tooSmallSystemMap map[string]any
	if err := yaml.Unmarshal(tooSmallSystem, &tooSmallSystemMap); err != nil {
		t.Fatal(err)
	}
	if got := nestedMap(t, tooSmallSystemMap, "tun")["mtu"]; got != defaultTunnelMTU {
		t.Errorf("invalid system tun.mtu = %v, want fallback %d", got, defaultTunnelMTU)
	}
}

func TestParseSettingsGeoDefaultsAndOverride(t *testing.T) {
	defaults := parseSettings("")
	if !defaults.GeoEnabled {
		t.Error("GeoEnabled default = false, want true")
	}
	if !defaults.GeodataMode {
		t.Error("GeodataMode default = false, want true (GeoIP.dat)")
	}
	if defaults.IgnoreGeoNegation {
		t.Error("IgnoreGeoNegation default = true, want false")
	}
	if defaults.GeoMMDBURL == "" || defaults.GeoIPDatURL == "" || defaults.GeoSiteURL == "" {
		t.Error("default GEO download URLs must not be empty")
	}
	custom := parseSettings(`{
		"geoEnabled": false,
		"ignoreGeoNegation": true,
		"geodataMode": false,
		"geoIPDatURL": "https://example.com/GeoIP.dat",
		"geoMMDBURL": "https://example.com/geoip.metadb",
		"geoSiteURL": "https://example.com/GeoSite.dat"
	}`)
	if custom.GeoEnabled {
		t.Error("GeoEnabled override = true, want false")
	}
	if !custom.IgnoreGeoNegation {
		t.Error("IgnoreGeoNegation override = false, want true")
	}
	if custom.GeodataMode {
		t.Error("GeodataMode override = true, want false")
	}
	if custom.GeoIPDatURL != "https://example.com/GeoIP.dat" ||
		custom.GeoMMDBURL != "https://example.com/geoip.metadb" ||
		custom.GeoSiteURL != "https://example.com/GeoSite.dat" {
		t.Error("GEO download URL overrides were not parsed")
	}
}

func TestMergeConfigGeoModeAndMainAppUpdateSettings(t *testing.T) {
	settings := appSettings{
		Stack:             "gvisor",
		LogLevel:          "info",
		GeoEnabled:        true,
		GeodataMode:       true,
		GeoLoader:         "memconservative",
		GeoAutoUpdate:     true,
		GeoUpdateInterval: 12,
		GeoIPDatURL:       "https://example.com/GeoIP.dat",
		GeoMMDBURL:        "https://example.com/geoip.metadb",
		GeoSiteURL:        "https://example.com/GeoSite.dat",
	}
	m := mergedMapWithSettings(t, "rules: []\n", settings)
	if got := m["geodata-mode"]; got != true {
		t.Errorf("geodata-mode = %v, want true", got)
	}
	if got := m["geo-auto-update"]; got != false {
		t.Errorf("geo-auto-update = %v, want false because the main App owns updates", got)
	}
	if got := m["geo-update-interval"]; got != 12 {
		t.Errorf("geo-update-interval = %v, want 12", got)
	}
	urls := nestedMap(t, m, "geox-url")
	wantURLs := map[string]any{
		"geoip":   settings.GeoIPDatURL,
		"mmdb":    settings.GeoMMDBURL,
		"geosite": settings.GeoSiteURL,
		"asn":     defaultASNURL,
	}
	for key, want := range wantURLs {
		if got := urls[key]; got != want {
			t.Errorf("geox-url.%s = %v, want %v", key, got, want)
		}
	}
}

func TestMergeConfigGeoDisabledRemovesSettingsAndNestedRules(t *testing.T) {
	const input = `
geodata-mode: true
geodata-loader: standard
geo-auto-update: true
geo-update-interval: 6
geox-url:
  geoip: https://example.com/geoip.dat
  geosite: https://example.com/geosite.dat
  asn: https://example.com/asn.mmdb
rules:
  - GEOIP,CN,DIRECT
  - IP-ASN,13335,Proxy,no-resolve
  - MATCH,DIRECT
sub-rules:
  nested:
    - GEOSITE,cn,DIRECT
    - SRC-IP-ASN,4134,DIRECT
    - DOMAIN,example.com,DIRECT
dns:
  nameserver-policy:
    "geosite:cn":
      - https://dns.alidns.com/dns-query
    "rule-set:Ai":
      - https://dns.google/dns-query#Ai
    "+.qpic.cn":
      - system
  proxy-server-nameserver-policy:
    "GEOSITE:geolocation-!cn":
      - https://dns.google/dns-query
    "+.example.com":
      - system
  fallback-filter:
    geoip: true
    geoip-code: CN
    geosite:
      - cn
    domain:
      - +.example.org
  fake-ip-filter:
    - geosite:cn
    - rule-set:Ai
    - +.lan
`
	m := mergedMapWithSettings(t, input, appSettings{
		Stack: "gvisor", LogLevel: "info", GeoEnabled: false,
	})

	if got := m["geo-auto-update"]; got != false {
		t.Errorf("geo-auto-update = %v, want false", got)
	}
	for _, key := range []string{"geodata-mode", "geodata-loader", "geo-update-interval"} {
		if _, exists := m[key]; exists {
			t.Errorf("%s should be absent while GEO is disabled", key)
		}
	}
	geoXURL := nestedMap(t, m, "geox-url")
	if len(geoXURL) != 1 || geoXURL["asn"] != "https://example.com/asn.mmdb" {
		t.Errorf("geox-url = %v, want only the unrelated ASN URL preserved", geoXURL)
	}
	rules, ok := m["rules"].([]any)
	if !ok || len(rules) != 2 || rules[0] != "IP-ASN,13335,Proxy,no-resolve" || rules[1] != "MATCH,DIRECT" {
		t.Errorf("rules = %v, want ASN and MATCH rules retained", m["rules"])
	}
	subRules := nestedMap(t, m, "sub-rules")
	nested, ok := subRules["nested"].([]any)
	if !ok || len(nested) != 2 || nested[0] != "SRC-IP-ASN,4134,DIRECT" || nested[1] != "DOMAIN,example.com,DIRECT" {
		t.Errorf("sub-rules.nested = %v, want ASN and DOMAIN rules retained", subRules["nested"])
	}
	dns := nestedMap(t, m, "dns")
	policy := nestedMap(t, dns, "nameserver-policy")
	if _, exists := policy["geosite:cn"]; exists {
		t.Errorf("dns.nameserver-policy should not retain geosite entry: %v", policy)
	}
	for _, key := range []string{"rule-set:Ai", "+.qpic.cn"} {
		if _, exists := policy[key]; !exists {
			t.Errorf("dns.nameserver-policy should preserve %s: %v", key, policy)
		}
	}
	proxyPolicy := nestedMap(t, dns, "proxy-server-nameserver-policy")
	if _, exists := proxyPolicy["GEOSITE:geolocation-!cn"]; exists {
		t.Errorf("dns.proxy-server-nameserver-policy should not retain geosite entry: %v", proxyPolicy)
	}
	if _, exists := proxyPolicy["+.example.com"]; !exists {
		t.Errorf("dns.proxy-server-nameserver-policy lost normal domain: %v", proxyPolicy)
	}
	fallback := nestedMap(t, dns, "fallback-filter")
	for _, key := range []string{"geoip", "geoip-code", "geosite"} {
		if _, exists := fallback[key]; exists {
			t.Errorf("dns.fallback-filter.%s should be absent while GEO is disabled: %v", key, fallback)
		}
	}
	if _, exists := fallback["domain"]; !exists {
		t.Errorf("dns.fallback-filter.domain should be preserved: %v", fallback)
	}
	fakeIPFilter, ok := dns["fake-ip-filter"].([]any)
	if !ok || len(fakeIPFilter) != 2 || fakeIPFilter[0] != "rule-set:Ai" || fakeIPFilter[1] != "+.lan" {
		t.Errorf("dns.fake-ip-filter = %v, want non-GEO filters preserved", dns["fake-ip-filter"])
	}

	m = mergedMapWithSettings(t, `geox-url: {geoip: https://example.com/geoip.dat}`, appSettings{
		Stack: "gvisor", LogLevel: "info", GeoEnabled: false,
	})
	if _, exists := m["geox-url"]; exists {
		t.Errorf("geox-url should be absent when it contains no unrelated URLs: %v", m["geox-url"])
	}
}

func TestResolveGeoDownloadURLsPrefersActiveConfig(t *testing.T) {
	const input = `
geox-url:
  geoip: https://config.example/geoip.dat
  mmdb: https://config.example/geoip.metadb
  geosite: https://config.example/geosite.dat
  asn: https://config.example/ASN.mmdb
rules:
  - IP-ASN,13335,Proxy,no-resolve
`
	settings := appSettings{
		GeoIPDatURL: "https://fallback.example/geoip.dat",
		GeoMMDBURL:  "https://fallback.example/geoip.metadb",
		GeoSiteURL:  "https://fallback.example/geosite.dat",
	}
	got := resolveGeoDownloadURLs(input, settings)
	if got.GeoIP != "https://config.example/geoip.dat" ||
		got.MMDB != "https://config.example/geoip.metadb" ||
		got.GeoSite != "https://config.example/geosite.dat" ||
		got.ASN != "https://config.example/ASN.mmdb" {
		t.Fatalf("resolved URLs = %+v, want active config values", got)
	}
	if !got.ASNRequired {
		t.Fatal("ASNRequired = false, want true")
	}
}

func TestResolveGeoDownloadURLsUsesFallbackAndDetectsNestedASN(t *testing.T) {
	settings := parseSettings("")
	got := resolveGeoDownloadURLs(`
sub-rules:
  nested:
    - SRC-IP-ASN,4134,DIRECT
`, settings)
	if got.GeoIP != settings.GeoIPDatURL || got.MMDB != settings.GeoMMDBURL ||
		got.GeoSite != settings.GeoSiteURL || got.ASN != defaultASNURL {
		t.Fatalf("resolved fallback URLs = %+v", got)
	}
	if !got.ASNRequired {
		t.Fatal("nested SRC-IP-ASN should require ASN database")
	}
}

func TestResolveGeoDownloadURLsExportsJSON(t *testing.T) {
	encoded := ResolveGeoDownloadURLs(`
geox-url:
  asn: https://config.example/ASN.mmdb
`, `{}`)
	var got geoDownloadURLs
	if err := json.Unmarshal([]byte(encoded), &got); err != nil {
		t.Fatalf("ResolveGeoDownloadURLs returned invalid JSON %q: %v", encoded, err)
	}
	if got.ASN != "https://config.example/ASN.mmdb" || !got.ASNRequired {
		t.Fatalf("ResolveGeoDownloadURLs = %+v", got)
	}
}

func TestMergeConfigGeoNegationSwitch(t *testing.T) {
	const input = `
rules:
  - GEOIP,CN,DIRECT
  - GEOSITE,geolocation-!cn,Proxy
  - NOT,((GEOIP,CN)),Proxy
  - MATCH,DIRECT
`
	settings := appSettings{
		Stack: "gvisor", LogLevel: "info", GeoEnabled: true, IgnoreGeoNegation: true,
	}
	m := mergedMapWithSettings(t, input, settings)
	rules, ok := m["rules"].([]any)
	if !ok {
		t.Fatalf("rules is %T, want []any", m["rules"])
	}
	if len(rules) != 2 {
		t.Fatalf("rules with ignore enabled = %v, want 2 retained rules", rules)
	}

	settings.IgnoreGeoNegation = false
	m = mergedMapWithSettings(t, input, settings)
	rules, ok = m["rules"].([]any)
	if !ok {
		t.Fatalf("rules is %T, want []any", m["rules"])
	}
	if len(rules) != 4 {
		t.Fatalf("rules with ignore disabled = %v, want all 4 rules", rules)
	}
}

func nestedMap(t *testing.T, m map[string]any, key string) map[string]any {
	t.Helper()
	v, ok := m[key].(map[string]any)
	if !ok {
		t.Fatalf("%s is %T, want map[string]any", key, m[key])
	}
	return v
}

func TestMergeConfigLowMemoryOverridesAndWebUI(t *testing.T) {
	m := mergedMap(t, `
external-ui: ui
external-ui-url: https://example.com/ui.zip
external-ui-name: panel
profile:
  store-selected: false
  store-fake-ip: false
dns:
  enhanced-mode: redir-host
  cache-max-size: 4096
  nameserver:
    - https://dns.google/dns-query#Proxy
  default-nameserver:
    - 223.5.5.5
  nameserver-policy:
    "+.qpic.cn":
      - system
    "rule-set:Ai":
      - https://dns.google/dns-query#Ai
`)

	wantUI := map[string]any{
		"external-ui":      "ui",
		"external-ui-url":  "https://example.com/ui.zip",
		"external-ui-name": "panel",
	}
	for key, want := range wantUI {
		if got := m[key]; got != want {
			t.Errorf("%s = %v, want preserved %v", key, got, want)
		}
	}
	profile := nestedMap(t, m, "profile")
	if got := profile["store-selected"]; got != false {
		t.Errorf("profile.store-selected = %v, want false", got)
	}
	if got := profile["store-fake-ip"]; got != false {
		t.Errorf("profile.store-fake-ip = %v, want preserved false", got)
	}
	dns := nestedMap(t, m, "dns")
	if got := dns["cache-max-size"]; got != 512 {
		t.Errorf("dns.cache-max-size = %v, want 512", got)
	}
	if got := dns["enhanced-mode"]; got != "redir-host" {
		t.Errorf("dns.enhanced-mode = %v, want subscription redir-host preserved", got)
	}
	nameserver, ok := dns["nameserver"].([]any)
	if !ok || len(nameserver) != 1 || nameserver[0] != "https://dns.google/dns-query#Proxy" {
		t.Errorf("dns.nameserver = %v, want subscription value preserved", dns["nameserver"])
	}
	defaultNameserver, ok := dns["default-nameserver"].([]any)
	if !ok || len(defaultNameserver) != 1 || defaultNameserver[0] != "223.5.5.5" {
		t.Errorf("dns.default-nameserver = %v, want subscription value preserved", dns["default-nameserver"])
	}
	policy := nestedMap(t, dns, "nameserver-policy")
	qpic, ok := policy["+.qpic.cn"].([]any)
	if !ok || len(qpic) != 1 || qpic[0] != "system" {
		t.Errorf("dns.nameserver-policy[+.qpic.cn] = %v, want subscription value preserved", policy["+.qpic.cn"])
	}
	ai, ok := policy["rule-set:Ai"].([]any)
	if !ok || len(ai) != 1 || ai[0] != "https://dns.google/dns-query#Ai" {
		t.Errorf("dns.nameserver-policy[rule-set:Ai] = %v, want subscription value preserved", policy["rule-set:Ai"])
	}
}

func TestMergeConfigSubscriptionDefaults(t *testing.T) {
	m := mergedMap(t, "proxies: []\n")
	if got := m["mode"]; got != "rule" {
		t.Errorf("mode = %v, want rule", got)
	}
	profile := nestedMap(t, m, "profile")
	if got := profile["store-selected"]; got != true {
		t.Errorf("profile.store-selected = %v, want true", got)
	}
	dns := nestedMap(t, m, "dns")
	if got, exists := dns["enhanced-mode"]; exists {
		t.Errorf("dns.enhanced-mode = %v, want omitted so Mihomo uses its default", got)
	}
	nameserver, ok := dns["nameserver"].([]any)
	if !ok || len(nameserver) != 2 || nameserver[0] != "https://223.5.5.5/dns-query" ||
		nameserver[1] != "https://1.1.1.1/dns-query" {
		t.Errorf("dns.nameserver = %v, want built-in fallback", dns["nameserver"])
	}

	m = mergedMap(t, "mode: global\n")
	if got := m["mode"]; got != "global" {
		t.Errorf("mode = %v, want global", got)
	}
}

func TestMergeConfigPreservesDNSEnhancedMode(t *testing.T) {
	for _, mode := range []string{"fake-ip", "redir-host"} {
		t.Run(mode, func(t *testing.T) {
			m := mergedMap(t, "dns:\n  enhanced-mode: "+mode+"\n")
			dns := nestedMap(t, m, "dns")
			if got := dns["enhanced-mode"]; got != mode {
				t.Errorf("dns.enhanced-mode = %v, want %s preserved", got, mode)
			}
		})
	}
}

func TestMergeConfigPreservesDisabledTunRouteOptions(t *testing.T) {
	m := mergedMap(t, `
tun:
  auto-route: false
  auto-redirect: false
  strict-route: false
`)
	tun := nestedMap(t, m, "tun")
	for _, key := range []string{"auto-route", "auto-redirect", "strict-route"} {
		if got := tun[key]; got != false {
			t.Errorf("tun.%s = %v, want subscription false preserved", key, got)
		}
	}
}

func TestMergeConfigKeepsIOSConstraints(t *testing.T) {
	m := mergedMap(t, `
geo-auto-update: true
mixed-port: 7890
tun:
  auto-route: true
  auto-redirect: true
  strict-route: true
  device: desktop-tun
`)
	if got := m["geo-auto-update"]; got != false {
		t.Errorf("geo-auto-update = %v, want false", got)
	}
	tun := nestedMap(t, m, "tun")
	if got := tun["stack"]; got != "gvisor" {
		t.Errorf("tun.stack = %v, want gvisor", got)
	}
	if got := tun["enable"]; got != true {
		t.Errorf("tun.enable = %v, want true", got)
	}
	for _, key := range []string{"auto-route", "auto-redirect", "strict-route"} {
		if got := tun[key]; got != true {
			t.Errorf("tun.%s = %v, want subscription value preserved", key, got)
		}
	}
	if _, exists := tun["device"]; exists {
		t.Errorf("tun.device should be replaced in iOS FD mode: %v", tun["device"])
	}
	if _, exists := m["mixed-port"]; exists {
		t.Error("mixed-port should be absent when the App setting is zero")
	}
}
