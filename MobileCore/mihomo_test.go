package mihomo

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/fakeip"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	mdns "github.com/metacubex/mihomo/dns"
	"gopkg.in/yaml.v3"
)

func BenchmarkMergeConfigLarge(b *testing.B) {
	input := largeBenchmarkConfig(1_000, 4_000)
	settings := parseSettings("")
	b.ReportAllocs()
	b.SetBytes(int64(len(input)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := mergeConfig(input, settings, 1_420); err != nil {
			b.Fatal(err)
		}
	}
}

func largeBenchmarkConfig(proxyCount int, ruleCount int) string {
	var out strings.Builder
	out.Grow(proxyCount*120 + ruleCount*40)
	out.WriteString("external-ui: ui\nmode: rule\ndns:\n  nameserver: [system]\nproxies:\n")
	for i := 0; i < proxyCount; i++ {
		fmt.Fprintf(&out, "  - {name: node-%04d, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: test}\n", i)
	}
	out.WriteString("proxy-groups:\n  - name: Proxy\n    type: select\n    proxies:\n")
	for i := 0; i < proxyCount; i++ {
		fmt.Fprintf(&out, "      - node-%04d\n", i)
	}
	out.WriteString("rules:\n")
	for i := 0; i < ruleCount; i++ {
		fmt.Fprintf(&out, "  - DOMAIN,host-%04d.example.com,Proxy\n", i)
	}
	out.WriteString("  - MATCH,DIRECT\n")
	return out.String()
}

func TestProxyProviderManifestOnlyIncludesHTTP(t *testing.T) {
	var got struct {
		Providers []remoteProxyProvider `json:"providers"`
	}
	result := ProxyProviderManifest(`
proxy-providers:
  remote:
    type: http
    url: https://example.com/provider.yaml
  local:
    type: file
    path: ./provider.yaml
`)
	if err := json.Unmarshal([]byte(result), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Providers) != 1 || got.Providers[0].Name != "remote" ||
		got.Providers[0].URL != "https://example.com/provider.yaml" {
		t.Fatalf("manifest = %+v", got.Providers)
	}
}

func TestRemoteResourceManifestIncludesHTTPProxyAndRuleProviders(t *testing.T) {
	var got struct {
		ProxyProviders []remoteProxyProvider `json:"proxyProviders"`
		RuleProviders  []remoteRuleProvider  `json:"ruleProviders"`
	}
	result := RemoteResourceManifest(`
proxy-providers:
  airport:
    type: http
    url: https://example.com/proxies.yaml
    header:
      User-Agent: [mihomo]
  local-proxy:
    type: file
    path: ./proxy.yaml
rule-providers:
  ai:
    type: http
    behavior: domain
    format: mrs
    url: https://example.com/ai.mrs
  local-rule:
    type: file
    behavior: classical
    path: ./rules.yaml
`)
	if err := json.Unmarshal([]byte(result), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.ProxyProviders) != 1 || got.ProxyProviders[0].Name != "airport" ||
		got.ProxyProviders[0].Header["User-Agent"][0] != "mihomo" {
		t.Fatalf("proxy providers = %+v", got.ProxyProviders)
	}
	if len(got.RuleProviders) != 1 || got.RuleProviders[0].Name != "ai" ||
		got.RuleProviders[0].Behavior != "domain" || got.RuleProviders[0].Format != "mrs" {
		t.Fatalf("rule providers = %+v", got.RuleProviders)
	}
}

func TestMergeConfigNormalizesDNSProxyNamesAndWarnsForMissingNames(t *testing.T) {
	m := mergedMap(t, `
proxy-groups:
  - name: Ai
    type: select
    proxies: [DIRECT]
dns:
  nameserver:
    - https://dns.google/dns-query#AI
  nameserver-policy:
    "+.example.com":
      - https://dns.google/dns-query#Missing
rules:
  - MATCH,Ai
`)
	dns := nestedMap(t, m, "dns")
	nameservers, ok := dns["nameserver"].([]any)
	if !ok || len(nameservers) != 1 || nameservers[0] != "https://dns.google/dns-query#Ai" {
		t.Fatalf("dns.nameserver = %v", dns["nameserver"])
	}
	policy := nestedMap(t, dns, "nameserver-policy")
	missing, ok := policy["+.example.com"].([]any)
	if !ok || len(missing) != 1 || missing[0] != "https://dns.google/dns-query#Missing" {
		t.Fatalf("missing policy should remain inspectable: %v", policy["+.example.com"])
	}
	joined := strings.Join(configNotices, "\n")
	if !strings.Contains(joined, "AI → Ai") || !strings.Contains(joined, "Missing") {
		t.Fatalf("config notices = %v", configNotices)
	}
}

func TestOfflineProxySnapshotCombinesInlineAndCachedProviders(t *testing.T) {
	configYAML := `
mode: rule
proxies:
  - {name: inline, type: SS, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: test}
proxy-providers:
  airport:
    type: http
    url: https://example.com/provider.yaml
    filter: "HK|SG"
proxy-groups:
  - name: Select
    type: select
    hidden: true
    proxies: [DIRECT, inline]
    use: [airport]
rules:
  - MATCH,DIRECT
`
	payloads, _ := json.Marshal(map[string]string{
		"airport": `proxies:
  - {name: HK One, type: vless, server: hk.example, port: 443, tls: true, reality-opts: {public-key: test}}
  - {name: US One, type: trojan, server: us.example, port: 443}
  - {name: SG One, type: vmess, server: sg.example, port: 443, network: ws}
`,
	})
	var got struct {
		Mode      string                    `json:"mode"`
		Proxies   map[string]map[string]any `json:"proxies"`
		Details   map[string]string         `json:"details"`
		NodeTypes map[string]string         `json:"nodeTypes"`
		NodeCount int                       `json:"nodeCount"`
	}
	if err := json.Unmarshal([]byte(OfflineProxySnapshot(configYAML, string(payloads), `{"Select":"SG One"}`)), &got); err != nil {
		t.Fatal(err)
	}
	group := got.Proxies["Select"]
	members, _ := group["all"].([]any)
	want := []any{"DIRECT", "inline", "HK One", "SG One"}
	if fmt.Sprint(members) != fmt.Sprint(want) {
		t.Fatalf("members = %v, want %v", members, want)
	}
	if group["now"] != "SG One" {
		t.Fatalf("offline now = %v, want SG One", group["now"])
	}
	if hidden, ok := group["hidden"].(bool); !ok || !hidden {
		t.Fatalf("offline hidden = %v, want true", group["hidden"])
	}
	if got.NodeCount != 3 {
		t.Fatalf("nodeCount = %v, want 3", got.NodeCount)
	}
	if !strings.Contains(got.Details["HK One"], "VLESS") || got.Mode != "rule" {
		t.Fatalf("snapshot details/mode = %+v / %q", got.Details, got.Mode)
	}
	for name, wantType := range map[string]string{
		"inline": "ss", "HK One": "vless", "SG One": "vmess",
	} {
		if got.NodeTypes[name] != wantType {
			t.Errorf("nodeTypes[%q] = %q, want %q", name, got.NodeTypes[name], wantType)
		}
	}
	if _, exists := got.NodeTypes["US One"]; exists {
		t.Error("filtered provider node US One should not appear in nodeTypes")
	}
}

func TestOfflineProxySnapshotMalformedYAMLIncludesEmptyNodeTypes(t *testing.T) {
	var got struct {
		NodeTypes map[string]string `json:"nodeTypes"`
		Error     string            `json:"error"`
	}
	encoded := OfflineProxySnapshot("proxies: [", "{}", "{}")
	if err := json.Unmarshal([]byte(encoded), &got); err != nil {
		t.Fatalf("OfflineProxySnapshot returned invalid JSON %q: %v", encoded, err)
	}
	if got.NodeTypes == nil || len(got.NodeTypes) != 0 {
		t.Fatalf("nodeTypes = %#v, want a non-nil empty map", got.NodeTypes)
	}
	if got.Error == "" {
		t.Fatal("malformed YAML should return an error")
	}
}

func TestOfflineProxySnapshotExpandsProviderNamedInProxies(t *testing.T) {
	configYAML := `
proxy-providers:
  airport:
    type: http
    url: https://example.com/provider.yaml
proxy-groups:
  - name: HK
    type: select
    proxies: [airport]
    filter: HK
  - name: US
    type: select
    proxies: [airport]
    filter: US
`
	payloads, _ := json.Marshal(map[string]string{
		"airport": `proxies:
  - {name: HK One, type: ss, server: hk.example, port: 443, cipher: aes-128-gcm, password: test}
  - {name: US One, type: ss, server: us.example, port: 443, cipher: aes-128-gcm, password: test}
`,
	})
	var got struct {
		Proxies map[string]map[string]any `json:"proxies"`
	}
	if err := json.Unmarshal([]byte(OfflineProxySnapshot(configYAML, string(payloads), "{}")), &got); err != nil {
		t.Fatal(err)
	}
	for group, want := range map[string]string{"HK": "HK One", "US": "US One"} {
		all, _ := got.Proxies[group]["all"].([]any)
		if fmt.Sprint(all) != fmt.Sprintf("[%s]", want) {
			t.Fatalf("%s members = %v, want [%s]", group, all, want)
		}
	}
}

func TestOfflineProxySnapshotUsesMihomoRegexSyntax(t *testing.T) {
	configYAML := `
proxy-providers:
  airport: {type: http, url: https://example.com/provider.yaml}
proxy-groups:
  - name: HK
    type: select
    use: [airport]
    filter: "(?<=HK )One"
`
	payloads, _ := json.Marshal(map[string]string{
		"airport": `proxies:
  - {name: HK One, type: ss, server: hk.example, port: 443, cipher: aes-128-gcm, password: test}
  - {name: HK Two, type: ss, server: hk2.example, port: 443, cipher: aes-128-gcm, password: test}
`,
	})
	var got struct {
		Proxies map[string]map[string]any `json:"proxies"`
	}
	if err := json.Unmarshal([]byte(OfflineProxySnapshot(configYAML, string(payloads), "{}")), &got); err != nil {
		t.Fatal(err)
	}
	all, _ := got.Proxies["HK"]["all"].([]any)
	if fmt.Sprint(all) != "[HK One]" {
		t.Fatalf("members = %v, want [HK One]", all)
	}
}

func TestMergeConfigBlocksKnownSTUNWithoutBlockingDirectUDP(t *testing.T) {
	settings := appSettings{Stack: "gvisor", LogLevel: "info", BlockDirectSTUN: true}
	m := mergedMapWithSettings(t, `
rules:
  - DOMAIN,stun.l.google.com,DIRECT
  - DST-PORT,3478,DIRECT
  - MATCH,DIRECT
`, settings)
	rules := m["rules"].([]any)
	if rules[0] != "DOMAIN,stun.l.google.com,REJECT" {
		t.Fatalf("first rule = %v, want STUN rejection before subscription rules", rules[0])
	}
	foundDirectPort := false
	for _, raw := range rules {
		if raw == "DST-PORT,3478,DIRECT" {
			foundDirectPort = true
		}
		if strings.Contains(fmt.Sprint(raw), "3478,REJECT") || strings.Contains(fmt.Sprint(raw), "5349,REJECT") {
			t.Fatalf("broad STUN/TURN port rejection found: %v", raw)
		}
	}
	if !foundDirectPort {
		t.Fatal("unrelated DIRECT UDP rule was removed")
	}
}

func TestMergeConfigLeavesSTUNRulesUnchangedWhenDisabled(t *testing.T) {
	m := mergedMapWithSettings(t, "rules:\n  - MATCH,DIRECT\n",
		appSettings{Stack: "gvisor", LogLevel: "info"})
	rules := m["rules"].([]any)
	if len(rules) != 1 || rules[0] != "MATCH,DIRECT" {
		t.Fatalf("rules = %v, want subscription rules only", rules)
	}
}

func TestMergeConfigSTUNProtectionKeepsDirectModeSemantics(t *testing.T) {
	m := mergedMapWithSettings(t, "mode: direct\n",
		appSettings{Stack: "gvisor", LogLevel: "info", BlockDirectSTUN: true})
	if m["mode"] != "rule" {
		t.Fatalf("mode = %v, want rule so rejection rules are evaluated", m["mode"])
	}
	rules := m["rules"].([]any)
	if rules[len(rules)-1] != "MATCH,DIRECT" {
		t.Fatalf("last rule = %v, want MATCH,DIRECT", rules[len(rules)-1])
	}
}

func TestNetworkInterfaceUpdates(t *testing.T) {
	previous := dialer.DefaultInterface.Load()
	defer dialer.DefaultInterface.Store(previous)
	previousPhysical := currentPhysicalInterface()
	defer storePhysicalInterface(previousPhysical)

	SetDefaultInterface("  en0  ")
	if got := dialer.DefaultInterface.Load(); got != "en0" {
		t.Fatalf("SetDefaultInterface stored %q, want en0", got)
	}
	if got := currentPhysicalInterface(); got != "en0" {
		t.Fatalf("physical interface stored %q, want en0", got)
	}

	if err := NotifyNetworkChange("pdp_ip0", "", "test", true); err != nil {
		t.Fatal(err)
	}
	if got := dialer.DefaultInterface.Load(); got != "pdp_ip0" {
		t.Fatalf("NotifyNetworkChange stored %q, want pdp_ip0", got)
	}

	if err := NotifyNetworkChange("   ", "", "test", false); err != nil {
		t.Fatal(err)
	}
	if got := dialer.DefaultInterface.Load(); got != "pdp_ip0" {
		t.Fatalf("empty network update changed interface to %q", got)
	}
}

func TestSnellCellularTCPNodeNormalizationAndStatus(t *testing.T) {
	if !isCellularInterface("pdp_ip0") || !isCellularInterface("PDP_IP1") {
		t.Fatal("pdp_ip interfaces should be recognized as cellular")
	}
	if isCellularInterface("en0") || isCellularInterface("") {
		t.Fatal("Wi-Fi and empty interfaces should not be recognized as cellular")
	}

	got := normalizeSnellCellularTCPNodes([]string{
		"  Tokyo CM  ", "Shanghai BGP", "Tokyo CM", "", "   ", "Shanghai BGP",
	})
	want := []string{"  Tokyo CM  ", "Shanghai BGP", "Tokyo CM"}
	if !equalStringSlices(got, want) {
		t.Fatalf("normalizeSnellCellularTCPNodes() = %v, want %v", got, want)
	}

	setSnellCellularTCPNodes(got)
	t.Cleanup(func() { setSnellCellularTCPNodes(nil) })
	if !snellCellularTCPSelected("Tokyo CM") || snellCellularTCPSelected("tokyo cm") {
		t.Fatal("Snell cellular TCP selection must use the exact normalized node name")
	}
	if !snellCellularTCPSelected("  Tokyo CM  ") || snellCellularTCPSelected("Tokyo CM ") {
		t.Fatal("Snell cellular TCP selection must preserve surrounding characters")
	}
	if status := snellCellularTCPStatus("Tokyo CM", "pdp_ip0"); !strings.Contains(status, "普通 TCP") {
		t.Fatalf("cellular selected status = %q", status)
	}
	if status := snellCellularTCPStatus("Tokyo CM", "en0"); !strings.Contains(status, "按节点配置使用 TFO") {
		t.Fatalf("Wi-Fi selected status = %q", status)
	}
	if status := snellCellularTCPStatus("Other", "pdp_ip0"); !strings.Contains(status, "未指定") {
		t.Fatalf("unselected status = %q", status)
	}
}

func TestSnellCellularTCPNodeNormalizationIsBounded(t *testing.T) {
	names := make([]string, maxSnellCellularTCPNodes+2)
	for index := range names {
		names[index] = fmt.Sprintf("node-%05d", index)
	}
	if got := len(normalizeSnellCellularTCPNodes(names)); got != maxSnellCellularTCPNodes {
		t.Fatalf("normalized node count = %d, want %d", got, maxSnellCellularTCPNodes)
	}
}

func TestProxyDelayErrorResponseIsAlwaysValidJSON(t *testing.T) {
	encoded := proxyDelayErrorResponse(fmt.Errorf("Snell handshake: EOF\nserver said %q", `try "TCP"`))
	var got struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal([]byte(encoded), &got); err != nil {
		t.Fatalf("proxyDelayErrorResponse returned invalid JSON %q: %v", encoded, err)
	}
	if want := "Snell handshake: EOF\nserver said \"try \\\"TCP\\\"\""; got.Error != want {
		t.Fatalf("error = %q, want %q", got.Error, want)
	}
}

func TestNetworkChangeRequiresReset(t *testing.T) {
	tests := []struct {
		name      string
		previous  string
		current   string
		requested bool
		want      bool
	}{
		{name: "duplicate path callback", previous: "en0", current: "en0", want: false},
		{name: "explicit address change", previous: "en0", current: "en0", requested: true, want: true},
		{name: "interface change", previous: "en0", current: "pdp_ip0", want: true},
		{name: "initial binding", current: "en0", want: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := networkChangeRequiresReset(
				test.previous, test.current, test.requested); got != test.want {
				t.Fatalf("networkChangeRequiresReset() = %v, want %v", got, test.want)
			}
		})
	}
}

func TestParseSystemDNSJSON(t *testing.T) {
	got, err := parseSystemDNSJSON(`["192.168.1.1","fe80::1%en0","192.168.1.1"]`)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"192.168.1.1", "fe80::1%en0"}
	if !equalStringSlices(got, want) {
		t.Fatalf("parseSystemDNSJSON = %v, want %v", got, want)
	}
	for _, raw := range []string{`{"dns":"1.1.1.1"}`, `["not-an-ip"]`, `["224.0.0.1"]`} {
		if _, err := parseSystemDNSJSON(raw); err == nil {
			t.Errorf("parseSystemDNSJSON accepted %s", raw)
		}
	}
}

func TestMaterializeSystemNameServersUsesParsedSourceIdentity(t *testing.T) {
	servers, err := mdns.ParseNameServer([]string{
		"system",
		"https://dns.example/dns-query",
		"10.0.0.1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if servers[0].Net != "system" || servers[2].Net != "" {
		t.Fatalf("mihomo parsed source identities as %q and %q",
			servers[0].Net, servers[2].Net)
	}
	updated, replacements := materializeSystemNameServers(
		servers,
		[]string{"192.168.1.1", "fe80::2%en0"})
	if replacements != 1 {
		t.Fatalf("replacements = %d, want 1", replacements)
	}
	want := []mdns.NameServer{
		{Addr: "192.168.1.1:53"},
		{Addr: "[fe80::2%en0]:53"},
		servers[1],
		servers[2],
	}
	if len(updated) != len(want) {
		t.Fatalf("updated = %+v, want %+v", updated, want)
	}
	for index := range want {
		if !updated[index].Equal(want[index]) {
			t.Errorf("updated[%d] = %+v, want %+v", index, updated[index], want[index])
		}
	}
}

func TestMaterializeSystemNameServersPreservesExplicitAddressCollision(t *testing.T) {
	servers, err := mdns.ParseNameServer([]string{"10.0.0.1", "system"})
	if err != nil {
		t.Fatal(err)
	}
	initial, replacements := materializeSystemNameServers(servers, []string{"10.0.0.1"})
	if replacements != 1 || len(initial) != 1 || initial[0].Addr != "10.0.0.1:53" {
		t.Fatalf("initial = %+v, replacements = %d", initial, replacements)
	}

	updated, replacements := materializeSystemNameServers(servers, []string{"192.168.1.1"})
	if replacements != 1 || len(updated) != 2 ||
		updated[0].Addr != "10.0.0.1:53" || updated[1].Addr != "192.168.1.1:53" {
		t.Fatalf("updated = %+v, replacements = %d", updated, replacements)
	}
}

func TestMaterializeUnresolvedSystemNameServer(t *testing.T) {
	updated, replacements := materializeSystemNameServers(
		[]mdns.NameServer{{Net: "system"}}, []string{"223.5.5.5"})
	if replacements != 1 || len(updated) != 1 ||
		updated[0].Net != "" || updated[0].Addr != "223.5.5.5:53" {
		t.Fatalf("updated = %+v, replacements = %d", updated, replacements)
	}
}

func TestReplaceActiveSystemDNSKeepsOldDNSOnMismatch(t *testing.T) {
	previousConfig := activeDNSConfig
	previousSource := activeDNSSystemSource
	previousSystemDNS := append([]string(nil), activeSystemDNS...)
	previousUsesSystemDNS := activeUsesSystemDNS
	defer func() {
		activeDNSConfig = previousConfig
		activeDNSSystemSource = previousSource
		activeSystemDNS = previousSystemDNS
		activeUsesSystemDNS = previousUsesSystemDNS
	}()

	activeDNSConfig = &config.DNS{
		NameServer: []mdns.NameServer{{Net: "https", Addr: "https://dns.example/dns-query"}},
	}
	activeDNSSystemSource = cloneDNSConfig(activeDNSConfig)
	activeSystemDNS = []string{"10.0.0.1"}
	activeUsesSystemDNS = true

	updated, replacements := prepareActiveSystemDNSLocked([]string{"192.168.1.1"})
	if updated != nil || replacements != 0 {
		t.Fatalf("updated = %v, replacements = %d", updated, replacements)
	}
	if !equalStringSlices(activeSystemDNS, []string{"10.0.0.1"}) {
		t.Fatalf("activeSystemDNS advanced after mismatch: %v", activeSystemDNS)
	}
}

func TestPrepareActiveSystemDNSDoesNotPublishCandidate(t *testing.T) {
	previousConfig := activeDNSConfig
	previousSource := activeDNSSystemSource
	previousSystemDNS := append([]string(nil), activeSystemDNS...)
	previousUsesSystemDNS := activeUsesSystemDNS
	defer func() {
		activeDNSConfig = previousConfig
		activeDNSSystemSource = previousSource
		activeSystemDNS = previousSystemDNS
		activeUsesSystemDNS = previousUsesSystemDNS
	}()

	original := &config.DNS{NameServer: []mdns.NameServer{{Addr: "10.0.0.1:53"}}}
	activeDNSConfig = original
	activeDNSSystemSource = &config.DNS{
		NameServer: []mdns.NameServer{{Net: "system"}},
	}
	activeSystemDNS = []string{"10.0.0.1"}
	activeUsesSystemDNS = true

	candidate, replacements := prepareActiveSystemDNSLocked([]string{"192.168.1.1"})
	if candidate == nil || replacements != 1 {
		t.Fatalf("candidate = %v, replacements = %d", candidate, replacements)
	}
	if activeDNSConfig != original || !equalStringSlices(activeSystemDNS, []string{"10.0.0.1"}) {
		t.Fatalf("candidate was published before resolver install: config=%p DNS=%v",
			activeDNSConfig, activeSystemDNS)
	}
	if got := candidate.NameServer[0].Addr; got != "192.168.1.1:53" {
		t.Fatalf("candidate nameserver = %q, want 192.168.1.1:53", got)
	}
}

type dnsResolverGlobalsSnapshot struct {
	runtime    resolver.DNSRuntimeSnapshot
	mapper     resolver.Enhancer
	generation uint64
}

func preserveDNSResolverGlobals(t *testing.T) {
	t.Helper()
	snapshot := dnsResolverGlobalsSnapshot{
		runtime:    resolver.CurrentDNSRuntime(),
		mapper:     resolver.DefaultHostMapper,
		generation: activeDNSGeneration,
	}
	t.Cleanup(func() {
		resetDNSResolverTransport(resolver.CurrentDNSRuntime().DefaultResolver)
		resolver.PublishDNSRuntime(snapshot.runtime)
		resolver.DefaultHostMapper = snapshot.mapper
		activeDNSGeneration = snapshot.generation
		mdns.ReCreateServer("", nil, snapshot.runtime.DefaultService)
	})
}

func TestRebuildDNSResolverReusesMapperAcrossGenerations(t *testing.T) {
	preserveDNSResolverGlobals(t)
	pool, err := fakeip.New(fakeip.Options{
		IPNet: netip.MustParsePrefix("198.18.0.0/16"),
		Size:  128,
	})
	if err != nil {
		t.Fatal(err)
	}
	mapper := mdns.NewEnhancer(mdns.EnhancerConfig{
		EnhancedMode: C.DNSFakeIP,
		FakeIPPool:   pool,
		FakeIPTTL:    1,
	})
	resolver.DefaultHostMapper = mapper
	runtime := resolver.CurrentDNSRuntime()
	runtime.DefaultResolver = mdns.NewResolver(mdns.Config{})
	resolver.PublishDNSRuntime(runtime)
	activeDNSGeneration = 20
	config := &config.DNS{
		Enable:       true,
		EnhancedMode: C.DNSFakeIP,
		FakeIPPool:   pool,
	}

	for refresh := 1; refresh <= 2; refresh++ {
		done := make(chan error, 1)
		go func() { done <- rebuildDNSResolverLocked(config, false) }()
		select {
		case err := <-done:
			if err != nil {
				t.Fatalf("refresh %d failed: %v", refresh, err)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("refresh %d deadlocked with a shared Fake-IP pool", refresh)
		}
		if resolver.DefaultHostMapper != mapper {
			t.Fatalf("refresh %d replaced mapper %p with %p", refresh, mapper,
				resolver.DefaultHostMapper)
		}
		if got, want := activeDNSGeneration, uint64(20+refresh); got != want {
			t.Fatalf("refresh %d generation = %d, want %d", refresh, got, want)
		}

		lateIP := pool.Lookup(fmt.Sprintf("late-%d.example", refresh))
		if host, ok := resolver.FindHostByIP(lateIP); !ok ||
			host != fmt.Sprintf("late-%d.example", refresh) {
			t.Fatalf("late mapping after refresh %d = %q, %v", refresh, host, ok)
		}
	}
}

func TestRebuildDNSResolverFailureKeepsGeneration(t *testing.T) {
	preserveDNSResolverGlobals(t)
	oldResolver := mdns.NewResolver(mdns.Config{})
	runtime := resolver.CurrentDNSRuntime()
	runtime.DefaultResolver = oldResolver
	resolver.PublishDNSRuntime(runtime)
	resolver.DefaultHostMapper = nil
	activeDNSGeneration = 73

	err := rebuildDNSResolverLocked(&config.DNS{
		Enable:       true,
		EnhancedMode: C.DNSMapping,
	}, false)
	if err == nil {
		t.Fatal("rebuild succeeded without a running mapper")
	}
	if activeDNSGeneration != 73 {
		t.Fatalf("failed rebuild advanced generation to %d", activeDNSGeneration)
	}
	got, ok := resolver.CurrentDNSRuntime().DefaultResolver.(mdns.Resolvers)
	if !ok || got.Resolver != oldResolver.Resolver {
		t.Fatal("failed rebuild replaced the active resolver")
	}
}

func TestDNSStartupDiagnosticReportsModesWithoutConfigContent(t *testing.T) {
	previousUsesSystemDNS := pendingUsesSystemDNS
	previousSourceMode := pendingSourceDNSMode
	defer func() {
		pendingUsesSystemDNS = previousUsesSystemDNS
		pendingSourceDNSMode = previousSourceMode
	}()
	pendingUsesSystemDNS = true
	pendingSourceDNSMode = sourceDNSEnhancedMode(map[string]any{
		"dns": map[string]any{
			"enhanced-mode": "redir-host",
			"nameserver":    []any{"https://private.example/dns-query"},
		},
	})
	settings := appSettings{
		ApplyOverrides: true,
		SystemDNS:      []string{"192.168.1.1"},
		Overrides: configOverrideSettings{DNS: dnsOverrideSettings{
			Overwrite:    true,
			EnhancedMode: "fake-ip",
		}},
	}
	diagnostic := dnsStartupDiagnostic(settings,
		&config.DNS{Enable: true, EnhancedMode: C.DNSFakeIP}, true, 4)
	for _, field := range []string{
		"源 enhanced-mode=redir-host", "DNS 覆写启用=true", "DNS 覆写应用=true",
		"覆写 enhanced-mode=fake-ip", "最终 enhanced-mode=fake-ip",
		"引用 system=true", "system DNS=192.168.1.1", "generation=4", "mapper 就绪=true",
	} {
		if !strings.Contains(diagnostic, field) {
			t.Errorf("diagnostic %q is missing %q", diagnostic, field)
		}
	}
	if strings.Contains(diagnostic, "private.example") {
		t.Fatalf("diagnostic exposed configuration content: %q", diagnostic)
	}
}

func TestDNSConfigUsesSystem(t *testing.T) {
	for _, notation := range []string{"system", "system://", "dhcp://system"} {
		if !dnsConfigUsesSystem(map[string]any{
			"nameserver-policy": map[string]any{
				"+.qpic.cn": []any{notation},
			},
		}) {
			t.Errorf("nameserver policy using %q was not detected", notation)
		}
	}
	if dnsConfigUsesSystem(map[string]any{
		"nameserver":     []any{"https://223.5.5.5/dns-query"},
		"fake-ip-filter": []any{"system"},
	}) {
		t.Fatal("unrelated DNS field was treated as a system nameserver")
	}
}

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

func TestControlInfoAdvertisesVersionedIPC(t *testing.T) {
	var info struct {
		ProtocolVersion int      `json:"protocolVersion"`
		CoreVersion     string   `json:"coreVersion"`
		Capabilities    []string `json:"capabilities"`
	}
	if err := json.Unmarshal([]byte(ControlInfo()), &info); err != nil {
		t.Fatalf("ControlInfo returned invalid JSON: %v", err)
	}
	if info.ProtocolVersion != controlProtocolVersion || info.CoreVersion == "" {
		t.Fatalf("ControlInfo = %+v", info)
	}
	want := map[string]bool{"connections": false, "logs": false, "proxies": false}
	for _, capability := range info.Capabilities {
		if _, exists := want[capability]; exists {
			want[capability] = true
		}
	}
	for capability, present := range want {
		if !present {
			t.Errorf("ControlInfo omitted %q", capability)
		}
	}
}

func TestConnectionsIPCEmptySnapshotAndMissingClose(t *testing.T) {
	var snapshot struct {
		Connections []json.RawMessage `json:"connections"`
		Total       int               `json:"total"`
		Truncated   bool              `json:"truncated"`
	}
	if err := json.Unmarshal([]byte(ConnectionsSnapshot(1)), &snapshot); err != nil {
		t.Fatalf("ConnectionsSnapshot returned invalid JSON: %v", err)
	}
	if snapshot.Total < len(snapshot.Connections) {
		t.Fatalf("snapshot total %d < returned %d", snapshot.Total, len(snapshot.Connections))
	}

	var totalsOnly struct {
		Connections []json.RawMessage `json:"connections"`
	}
	if err := json.Unmarshal([]byte(ConnectionsSnapshot(0)), &totalsOnly); err != nil {
		t.Fatalf("ConnectionsSnapshot totals-only returned invalid JSON: %v", err)
	}
	if len(totalsOnly.Connections) != 0 {
		t.Fatalf("ConnectionsSnapshot totals-only returned %d connection details", len(totalsOnly.Connections))
	}
	var closedSnapshot struct {
		Cursor      int               `json:"cursor"`
		Connections []json.RawMessage `json:"connections"`
	}
	if err := json.Unmarshal([]byte(ClosedConnectionsSnapshot(0, 32)), &closedSnapshot); err != nil {
		t.Fatalf("ClosedConnectionsSnapshot returned invalid JSON: %v", err)
	}
	if closedSnapshot.Cursor < 0 {
		t.Fatalf("ClosedConnectionsSnapshot cursor = %d", closedSnapshot.Cursor)
	}
	if err := CloseConnection(""); err == nil {
		t.Fatal("CloseConnection accepted an empty ID")
	}
	if err := CloseConnection("00000000-0000-0000-0000-000000000000"); err == nil {
		t.Fatal("CloseConnection accepted an unknown ID")
	}
}

func TestTrafficNowIncludesCoreUptime(t *testing.T) {
	previousStartedAt := coreStartedAt
	coreStartedAt = time.Now().Add(-3 * time.Second)
	defer func() { coreStartedAt = previousStartedAt }()

	var snapshot struct {
		Uptime int64 `json:"uptime"`
	}
	if err := json.Unmarshal([]byte(TrafficNow()), &snapshot); err != nil {
		t.Fatalf("TrafficNow returned invalid JSON: %v", err)
	}
	if snapshot.Uptime < 2 {
		t.Fatalf("TrafficNow uptime = %d, want at least 2", snapshot.Uptime)
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
	if !defaults.ApplyOverrides {
		t.Error("ApplyOverrides default = false, want true for legacy settings")
	}
	if !defaults.GeoEnabled {
		t.Error("GeoEnabled default = false, want true")
	}
	if !defaults.GeodataMode {
		t.Error("GeodataMode default = false, want true (GeoIP.dat)")
	}
	if defaults.IgnoreGeoNegation {
		t.Error("IgnoreGeoNegation default = true, want false")
	}
	if defaults.RemoteResourceUpdatePolicy != "inherit" || defaults.RemoteResourceUpdateInterval != 24 {
		t.Errorf("remote resource update defaults = %q/%d, want inherit/24",
			defaults.RemoteResourceUpdatePolicy, defaults.RemoteResourceUpdateInterval)
	}
	if len(defaults.SnellCellularTCPNodes) != 0 {
		t.Errorf("SnellCellularTCPNodes default = %v, want empty", defaults.SnellCellularTCPNodes)
	}
	legacy := parseSettings(`{
		"cellularSnellCompatibility": true,
		"snellAdaptiveTFOHoldUntilNetworkChange": true
	}`)
	if len(legacy.SnellCellularTCPNodes) != 0 {
		t.Errorf("legacy adaptive TFO settings selected nodes: %v", legacy.SnellCellularTCPNodes)
	}
	if defaults.GeoMMDBURL == "" || defaults.GeoIPDatURL == "" || defaults.GeoSiteURL == "" {
		t.Error("default GEO download URLs must not be empty")
	}
	custom := parseSettings(`{
		"geoEnabled": false,
		"ignoreGeoNegation": true,
		"snellCellularTCPNodes": ["Tokyo CM", "Shanghai BGP", "Tokyo CM", ""],
		"geodataMode": false,
		"geoIPDatURL": "https://example.com/GeoIP.dat",
		"geoMMDBURL": "https://example.com/geoip.metadb",
		"geoSiteURL": "https://example.com/GeoSite.dat",
		"remoteResourceUpdatePolicy": "fixed",
		"remoteResourceUpdateInterval": 12
	}`)
	if custom.GeoEnabled {
		t.Error("GeoEnabled override = true, want false")
	}
	if !custom.IgnoreGeoNegation {
		t.Error("IgnoreGeoNegation override = false, want true")
	}
	if want := []string{"Shanghai BGP", "Tokyo CM"}; !equalStringSlices(custom.SnellCellularTCPNodes, want) {
		t.Errorf("SnellCellularTCPNodes = %v, want %v", custom.SnellCellularTCPNodes, want)
	}
	if custom.GeodataMode {
		t.Error("GeodataMode override = true, want false")
	}
	if custom.GeoIPDatURL != "https://example.com/GeoIP.dat" ||
		custom.GeoMMDBURL != "https://example.com/geoip.metadb" ||
		custom.GeoSiteURL != "https://example.com/GeoSite.dat" {
		t.Error("GEO download URL overrides were not parsed")
	}
	if custom.RemoteResourceUpdatePolicy != "fixed" || custom.RemoteResourceUpdateInterval != 12 {
		t.Errorf("remote resource update override = %q/%d, want fixed/12",
			custom.RemoteResourceUpdatePolicy, custom.RemoteResourceUpdateInterval)
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

func TestMergeConfigAppliesRemoteResourceUpdatePolicy(t *testing.T) {
	const input = `
proxy-providers:
  remote-proxy:
    type: http
    url: https://example.com/proxy.yaml
    interval: 600
  local-proxy:
    type: file
    path: ./proxy.yaml
rule-providers:
  remote-rule:
    type: http
    behavior: domain
    format: yaml
    url: https://example.com/rules.yaml
    interval: 1200
  local-rule:
    type: file
    behavior: domain
    path: ./rules.yaml
`

	inherit := mergedMapWithSettings(t, input, appSettings{
		Stack: "gvisor", LogLevel: "info", RemoteResourceUpdatePolicy: "inherit",
	})
	if got := nestedMap(t, nestedMap(t, inherit, "proxy-providers"), "remote-proxy")["interval"]; got != 600 {
		t.Errorf("inherit proxy interval = %v, want 600", got)
	}
	if got := nestedMap(t, nestedMap(t, inherit, "rule-providers"), "remote-rule")["interval"]; got != 1200 {
		t.Errorf("inherit rule interval = %v, want 1200", got)
	}

	disabled := mergedMapWithSettings(t, input, appSettings{
		Stack: "gvisor", LogLevel: "info", RemoteResourceUpdatePolicy: "disabled",
	})
	for _, provider := range []map[string]any{
		nestedMap(t, nestedMap(t, disabled, "proxy-providers"), "remote-proxy"),
		nestedMap(t, nestedMap(t, disabled, "rule-providers"), "remote-rule"),
	} {
		if got := provider["interval"]; got != 0 {
			t.Errorf("disabled interval = %v, want 0", got)
		}
	}
	if _, exists := nestedMap(t, nestedMap(t, disabled, "proxy-providers"), "local-proxy")["interval"]; exists {
		t.Error("non-HTTP proxy provider should not gain an interval")
	}
	if _, exists := nestedMap(t, nestedMap(t, disabled, "rule-providers"), "local-rule")["interval"]; exists {
		t.Error("non-HTTP rule provider should not gain an interval")
	}

	fixed := mergedMapWithSettings(t, input, appSettings{
		Stack: "gvisor", LogLevel: "info", RemoteResourceUpdatePolicy: "fixed",
		RemoteResourceUpdateInterval: 12,
	})
	for _, provider := range []map[string]any{
		nestedMap(t, nestedMap(t, fixed, "proxy-providers"), "remote-proxy"),
		nestedMap(t, nestedMap(t, fixed, "rule-providers"), "remote-rule"),
	} {
		if got := provider["interval"]; got != 43_200 {
			t.Errorf("fixed interval = %v, want 43200", got)
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
	if !ok || len(rules) != 1 || rules[0] != "MATCH,DIRECT" {
		t.Errorf("rules = %v, want only MATCH retained", m["rules"])
	}
	subRules := nestedMap(t, m, "sub-rules")
	nested, ok := subRules["nested"].([]any)
	if !ok || len(nested) != 1 || nested[0] != "DOMAIN,example.com,DIRECT" {
		t.Errorf("sub-rules.nested = %v, want only DOMAIN retained", subRules["nested"])
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

func TestResolveGeoDownloadURLsOnlyRequiresUsedAssets(t *testing.T) {
	direct := resolveGeoDownloadURLs("mode: direct\nrules:\n  - MATCH,DIRECT\n", parseSettings(""))
	if direct.GeoRequired || direct.ASNRequired {
		t.Fatalf("DIRECT config unexpectedly requires GEO assets: %+v", direct)
	}

	geo := resolveGeoDownloadURLs(`
dns:
  nameserver-policy:
    "geosite:cn": 223.5.5.5
`, parseSettings(""))
	if !geo.GeoRequired {
		t.Fatal("geosite DNS policy should require GEO assets")
	}

	fallback := resolveGeoDownloadURLs(`
dns:
  fallback-filter:
    geoip: true
    geoip-code: CN
`, parseSettings(""))
	if !fallback.GeoRequired {
		t.Fatal("geoip fallback filter should require GEO assets")
	}
}

func TestResolveGeoDownloadURLsIncludesVisualDNSOverride(t *testing.T) {
	settings := appSettings{
		ApplyOverrides: true,
		Overrides: configOverrideSettings{DNS: dnsOverrideSettings{
			Overwrite:           true,
			FallbackNameservers: []string{"tls://8.8.8.8"},
			FallbackGeoIP:       true,
		}},
	}
	if got := resolveGeoDownloadURLs("rules: [MATCH,DIRECT]\n", settings); !got.GeoRequired {
		t.Fatal("visual DNS fallback GeoIP should require GEO assets")
	}
	settings.Overrides.DNS.FallbackNameservers = nil
	if got := resolveGeoDownloadURLs("rules: [MATCH,DIRECT]\n", settings); got.GeoRequired {
		t.Fatal("empty visual DNS fallback should not require GEO assets")
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
	if got.ASN != "https://config.example/ASN.mmdb" || got.ASNRequired {
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

func TestMergeConfigFiltersNestedUnsupportedAndASNRules(t *testing.T) {
	const input = `
rules:
  - IP-ASN,13335,Proxy
  - MATCH,DIRECT
sub-rules:
  nested:
    - PROCESS-NAME,Example,DIRECT
    - SRC-IP-ASN,4134,Proxy
    - GEOSITE,geolocation-!cn,Proxy
    - MATCH,DIRECT
`
	settings := appSettings{Stack: "gvisor", LogLevel: "info", GeoEnabled: false}
	m := mergedMapWithSettings(t, input, settings)
	rules := m["rules"].([]any)
	if len(rules) != 1 || rules[0] != "MATCH,DIRECT" {
		t.Fatalf("top-level rules = %v, want only MATCH", rules)
	}
	subRules := nestedMap(t, m, "sub-rules")
	nested := subRules["nested"].([]any)
	if len(nested) != 1 || nested[0] != "MATCH,DIRECT" {
		t.Fatalf("nested rules = %v, want only MATCH", nested)
	}

	settings.GeoEnabled = true
	settings.IgnoreGeoNegation = true
	m = mergedMapWithSettings(t, input, settings)
	nested = nestedMap(t, m, "sub-rules")["nested"].([]any)
	for _, rule := range nested {
		if rule == "PROCESS-NAME,Example,DIRECT" || rule == "GEOSITE,geolocation-!cn,Proxy" {
			t.Fatalf("unsupported nested rule was retained: %v", nested)
		}
	}
}

func TestParseSettingsNormalizesMixedPort(t *testing.T) {
	settings := parseSettings(`{
  "mixedPort": -1
}`)
	if settings.MixedPort != 0 {
		t.Fatalf("mixed port = %d, want 0", settings.MixedPort)
	}

	settings = parseSettings(`{"mixedPort": 9090}`)
	if settings.MixedPort != 9090 {
		t.Fatalf("mixed port = %d, want 9090", settings.MixedPort)
	}
}

func TestParseSettingsIncludesOfflineProxySelections(t *testing.T) {
	settings := parseSettings(`{"proxySelections":{"Proxy":"HK One"}}`)
	if got := settings.ProxySelections["Proxy"]; got != "HK One" {
		t.Fatalf("proxy selection = %q, want HK One", got)
	}
}

func TestRunLogChunkTracksOffsetAndGeneration(t *testing.T) {
	previousHome := homeDir
	previousGeneration := runLogGeneration
	previousBytes := runLogBytes
	previousFile := runLogFile
	defer func() {
		homeDir = previousHome
		runLogGeneration = previousGeneration
		runLogBytes = previousBytes
		runLogFile = previousFile
	}()

	homeDir = t.TempDir()
	runLogGeneration = 7
	runLogFile = nil
	path := filepath.Join(homeDir, "run.log")
	if err := os.WriteFile(path, []byte("first\nsecond\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	var first struct {
		Offset     int64  `json:"offset"`
		Generation int64  `json:"generation"`
		Reset      bool   `json:"reset"`
		Text       string `json:"text"`
	}
	if err := json.Unmarshal([]byte(RunLogChunk(-1, 0)), &first); err != nil {
		t.Fatal(err)
	}
	if !first.Reset || first.Generation != 7 || first.Text != "first\nsecond\n" {
		t.Fatalf("initial chunk = %+v", first)
	}

	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString("third\n"); err != nil {
		_ = f.Close()
		t.Fatal(err)
	}
	_ = f.Close()
	var next struct {
		Offset int64  `json:"offset"`
		Reset  bool   `json:"reset"`
		Text   string `json:"text"`
	}
	if err := json.Unmarshal([]byte(RunLogChunk(int(first.Offset), 7)), &next); err != nil {
		t.Fatal(err)
	}
	if next.Reset || next.Text != "third\n" || next.Offset <= first.Offset {
		t.Fatalf("incremental chunk = %+v, first offset = %d", next, first.Offset)
	}
}

func TestParseSettingsVisualOverrides(t *testing.T) {
	settings := parseSettings(`{
  "applyOverrides": false,
  "overrides": {
    "dns": {"overwrite": true, "enhancedMode": "redir-host", "nameservers": ["9.9.9.9"]},
    "sniffer": {"overwrite": true, "enable": true, "quic": true},
    "tun": {"overwrite": true, "dnsHijack": ["any:53"], "icmpForwarding": true}
  }
}`)
	if settings.ApplyOverrides {
		t.Error("applyOverrides JSON false was not parsed")
	}
	if !settings.Overrides.DNS.Overwrite || settings.Overrides.DNS.EnhancedMode != "redir-host" {
		t.Errorf("DNS override JSON was not parsed: %+v", settings.Overrides.DNS)
	}
	if !settings.Overrides.Sniffer.QUIC || !settings.Overrides.Tun.ICMPForwarding {
		t.Errorf("sniffer/TUN override JSON was not parsed: %+v", settings.Overrides)
	}
}

func TestRunLogIsBounded(t *testing.T) {
	previousBytes := runLogBytes
	previousGeneration := runLogGeneration
	runLogBytes = -1
	defer func() {
		runLogBytes = previousBytes
		runLogGeneration = previousGeneration
	}()
	path := filepath.Join(t.TempDir(), "run.log")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err := file.Write(bytes.Repeat([]byte{'x'}, int(maxRunLogBytes))); err != nil {
		t.Fatal(err)
	}
	writeRunLogLine(file, "next line\n")
	info, err := file.Stat()
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() >= maxRunLogBytes {
		t.Fatalf("run.log size = %d, want less than %d after rotation", info.Size(), maxRunLogBytes)
	}
}

func TestLogTimestampIsUTC(t *testing.T) {
	value := logTimestamp()
	if !strings.HasSuffix(value, "Z") {
		t.Fatalf("logTimestamp = %q, want UTC suffix", value)
	}
	if _, err := time.Parse("2006-01-02T15:04:05.000Z07:00", value); err != nil {
		t.Fatalf("logTimestamp = %q: %v", value, err)
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

func TestMergeConfigLowMemoryOverridesAndControllerIsolation(t *testing.T) {
	m := mergedMap(t, `
external-controller: 0.0.0.0:9999
external-controller-tls: 0.0.0.0:9443
secret: subscription-secret
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

	for _, key := range []string{
		"external-controller", "external-controller-tls", "secret",
		"external-ui", "external-ui-url", "external-ui-name",
	} {
		if _, exists := m[key]; exists {
			t.Errorf("subscription-owned %s should be removed", key)
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

func TestMergeConfigAppliesFixedVisualOverrides(t *testing.T) {
	settings := appSettings{
		Stack:          "gvisor",
		LogLevel:       "info",
		GeoEnabled:     true,
		ApplyOverrides: true,
		Overrides: configOverrideSettings{
			DNS: dnsOverrideSettings{
				Overwrite:           true,
				Listen:              "127.0.0.1:1053",
				PreferH3:            true,
				UseSystemHosts:      false,
				UseHosts:            true,
				Hosts:               map[string]string{"router.lan": "192.168.1.1"},
				EnhancedMode:        "redir-host",
				FakeIPFilterMode:    "whitelist",
				FakeIPFilter:        []string{"+.example.com"},
				RespectRules:        true,
				DefaultNameservers:  []string{"223.5.5.5"},
				Nameservers:         []string{"https://dns.example/dns-query"},
				ProxyNameservers:    []string{"1.1.1.1"},
				DirectNameservers:   []string{"system"},
				FallbackNameservers: []string{"tls://8.8.8.8"},
				FallbackGeoIP:       false,
			},
			Sniffer: snifferOverrideSettings{
				Overwrite:           true,
				Enable:              true,
				ForceDNSMapping:     true,
				ParsePureIP:         true,
				OverrideDestination: false,
				HTTP:                true,
				TLS:                 true,
				ForceDomains:        []string{"+.force.example"},
				SkipDomains:         []string{"+.skip.example"},
			},
			Tun: tunOverrideSettings{
				Overwrite:      true,
				DNSHijack:      []string{"tcp://any:53"},
				StrictRoute:    true,
				ICMPForwarding: false,
			},
		},
	}
	m := mergedMapWithSettings(t, `
dns:
  enhanced-mode: fake-ip
  nameserver: [9.9.9.9]
sniffer:
  enable: false
tun:
  dns-hijack: [any:53]
  strict-route: false
`, settings)

	dns := nestedMap(t, m, "dns")
	if dns["listen"] != "127.0.0.1:1053" || dns["prefer-h3"] != true ||
		dns["enhanced-mode"] != "redir-host" || dns["fake-ip-filter-mode"] != "whitelist" ||
		dns["respect-rules"] != true {
		t.Errorf("visual DNS override not applied: %v", dns)
	}
	if got := dns["nameserver"].([]any); len(got) != 1 || got[0] != "https://dns.example/dns-query" {
		t.Errorf("dns.nameserver = %v", got)
	}
	if got := nestedMap(t, m, "hosts")["router.lan"]; got != "192.168.1.1" {
		t.Errorf("hosts.router.lan = %v", got)
	}
	fallback := nestedMap(t, dns, "fallback-filter")
	if fallback["geoip"] != false || fallback["geoip-code"] != "CN" {
		t.Errorf("dns.fallback-filter = %v", fallback)
	}

	sniffer := nestedMap(t, m, "sniffer")
	if sniffer["enable"] != true || sniffer["override-destination"] != false {
		t.Errorf("sniffer override not applied: %v", sniffer)
	}
	protocols := nestedMap(t, sniffer, "sniff")
	if _, ok := protocols["HTTP"]; !ok {
		t.Error("HTTP sniffer missing")
	}
	if _, ok := protocols["TLS"]; !ok {
		t.Error("TLS sniffer missing")
	}
	if _, ok := protocols["QUIC"]; ok {
		t.Error("disabled QUIC sniffer should be omitted")
	}

	tun := nestedMap(t, m, "tun")
	if tun["strict-route"] != true || tun["disable-icmp-forwarding"] != true {
		t.Errorf("TUN override not applied: %v", tun)
	}
	if got := tun["dns-hijack"].([]any); len(got) != 1 || got[0] != "tcp://any:53" {
		t.Errorf("tun.dns-hijack = %v", got)
	}
	merged, err := mergeConfig("proxies: []\n", settings, 1420)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := config.UnmarshalRawConfig(merged); err != nil {
		t.Fatalf("mihomo rejected visual override output: %v", err)
	}
}

func TestMergeConfigCanDisableFixedVisualOverrides(t *testing.T) {
	settings := appSettings{
		Stack:          "gvisor",
		LogLevel:       "info",
		ApplyOverrides: false,
		Overrides: configOverrideSettings{
			DNS:     dnsOverrideSettings{Overwrite: true, EnhancedMode: "redir-host"},
			Sniffer: snifferOverrideSettings{Overwrite: true, Enable: true},
			Tun:     tunOverrideSettings{Overwrite: true, StrictRoute: true},
		},
	}
	m := mergedMapWithSettings(t, `
dns:
  enhanced-mode: fake-ip
  nameserver: [9.9.9.9]
sniffer:
  enable: false
tun:
  dns-hijack: [udp://any:53]
  strict-route: false
  disable-icmp-forwarding: false
`, settings)
	if got := nestedMap(t, m, "dns")["enhanced-mode"]; got != "fake-ip" {
		t.Errorf("dns.enhanced-mode = %v, want subscription value", got)
	}
	if got := nestedMap(t, m, "sniffer")["enable"]; got != false {
		t.Errorf("sniffer.enable = %v, want subscription value", got)
	}
	tun := nestedMap(t, m, "tun")
	if tun["strict-route"] != false || tun["disable-icmp-forwarding"] != false {
		t.Errorf("TUN subscription values were not preserved: %v", tun)
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
	if got := m["allow-lan"]; got != false {
		t.Errorf("allow-lan = %v, want false", got)
	}
	if got := m["bind-address"]; got != "127.0.0.1" {
		t.Errorf("bind-address = %v, want loopback", got)
	}
}
