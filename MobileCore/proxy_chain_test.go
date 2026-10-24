package mihomo

import (
	"context"
	"encoding/json"
	"errors"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"go.yaml.in/yaml/v3"
)

const chainFixture = `
proxies:
  - {name: A, type: socks5, server: 127.0.0.1, port: 1, udp: true}
  - {name: B, type: socks5, server: 127.0.0.1, port: 2, udp: true}
  - {name: D, type: socks5, server: 127.0.0.1, port: 3, udp: true}
proxy-providers:
  P:
    type: inline
    payload:
      - {name: B, type: socks5, server: 127.0.0.1, port: 4, udp: true}
      - {name: C, type: socks5, server: 127.0.0.1, port: 5, udp: true}
  Q:
    type: inline
    payload:
      - {name: C, type: socks5, server: 127.0.0.1, port: 6, udp: true}
proxy-groups:
  - {name: All, type: select, include-all: true}
  - {name: Manual, type: select, proxies: [B, D]}
rules: ["MATCH,All"]
`

func chainTestSettings() proxyChainSettings {
	return proxyChainSettings{Enabled: true, Mode: "existing", Upstream: &chainReference{"", "A"}, Targets: []chainReference{{"", "B"}, {"P", "C"}}}
}

func chainTestMap(t *testing.T, source string) map[string]any {
	t.Helper()
	var raw map[string]any
	if err := yaml.Unmarshal([]byte(source), &raw); err != nil {
		t.Fatal(err)
	}
	return raw
}

func chainTestConfig(t *testing.T, raw map[string]any) *config.Config {
	t.Helper()
	buf, err := yaml.Marshal(raw)
	if err != nil {
		t.Fatal(err)
	}
	r, err := config.UnmarshalRawConfig(buf)
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.ParseRawConfig(r)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeProviders(providerObjects(cfg.Providers, cfg.RuleProviders)) })
	return cfg
}

func TestProxyChainSelectiveAndOriginalGroups(t *testing.T) {
	for _, custom := range []bool{false, true} {
		t.Run(map[bool]string{false: "existing", true: "custom"}[custom], func(t *testing.T) {
			original := chainTestConfig(t, chainTestMap(t, chainFixture))
			settings := chainTestSettings()
			if custom {
				settings.Mode = "custom"
				settings.YAML = "name: Custom\ntype: socks5\nserver: 127.0.0.1\nport: 7\n"
			}
			raw := chainTestMap(t, chainFixture)
			if _, err := applyProxyChain(raw, settings); err != nil {
				t.Fatal(err)
			}
			cfg := chainTestConfig(t, raw)
			for _, name := range []string{"A", "D"} {
				if got := cfg.Proxies[name].ProxyInfo().DialerProxy; got != "" {
					t.Fatalf("unselected %s changed: %s", name, got)
				}
			}
			if cfg.Proxies["B"].ProxyInfo().DialerProxy != chainUpstreamName {
				t.Fatal("selected inline target not chained")
			}
			for source, pd := range cfg.Providers {
				if source != "P" && source != "Q" {
					continue
				}
				if err := pd.Initial(); err != nil {
					t.Fatal(err)
				}
				for _, proxy := range pd.Proxies() {
					want := ""
					if source == "P" && proxy.Name() == "C" {
						want = chainUpstreamName
					}
					if got := proxy.ProxyInfo().DialerProxy; got != want {
						t.Fatalf("%s/%s dialer=%q want %q", source, proxy.Name(), got, want)
					}
				}
			}
			for _, pd := range original.Providers {
				if err := pd.Initial(); err != nil {
					t.Fatal(err)
				}
			}
			for _, name := range []string{"All", "Manual", "GLOBAL"} {
				members := func(c *config.Config) []string {
					group := c.Proxies[name].Adapter().(interface{ GetProxies(bool) []C.Proxy })
					var names []string
					for _, proxy := range group.GetProxies(false) {
						names = append(names, proxy.Name())
					}
					return names
				}
				if got, want := members(cfg), members(original); !reflect.DeepEqual(got, want) {
					t.Fatalf("%s membership changed: %v != %v", name, got, want)
				}
			}
		})
	}
}

func TestProxyChainDisabledAndEmptyDoNotChangeConfig(t *testing.T) {
	for _, settings := range []proxyChainSettings{{}, {Enabled: true, Mode: "existing", Upstream: &chainReference{"", "A"}}} {
		raw := chainTestMap(t, chainFixture)
		before, _ := yaml.Marshal(raw)
		if _, err := applyProxyChain(raw, settings); err != nil {
			t.Fatal(err)
		}
		after, _ := yaml.Marshal(raw)
		if string(before) != string(after) {
			t.Fatal("disabled/empty selection changed original config")
		}
	}
}

func TestProxyChainProviderRefreshIsolationAndConflictRollback(t *testing.T) {
	Setup(t.TempDir())
	defer Stop()
	raw := chainTestMap(t, chainFixture)
	settings := chainTestSettings()
	if _, err := applyProxyChain(raw, settings); err != nil {
		t.Fatal(err)
	}
	defs := raw["proxy-providers"].(map[string]any)
	def := defs["P"].(map[string]any)
	def["type"] = "http"
	def["url"] = "https://example.invalid/provider"
	def["path"] = "chain-provider.yaml"
	delete(def, "payload")
	pd, err := provider.ParseProxyProvider("P", def, tunnel.Tunnel)
	if err != nil {
		t.Fatal(err)
	}
	set := pd.(*provider.ProxySetProvider)
	defer set.Close()
	good := []byte("proxies:\n  - {name: C, type: socks5, server: 127.0.0.1, port: 8}\n  - {name: New, type: socks5, server: 127.0.0.1, port: 9}\n")
	if _, _, err := set.SideUpdate(good); err != nil {
		t.Fatal(err)
	}
	if pd.Proxies()[0].ProxyInfo().DialerProxy != chainUpstreamName || pd.Proxies()[1].ProxyInfo().DialerProxy != "" {
		t.Fatal("refresh did not preserve exact selection")
	}
	cache := filepath.Join(C.Path.HomeDir(), "chain-provider.yaml")
	if buf, err := os.ReadFile(cache); err != nil || string(buf) != string(good) {
		t.Fatalf("raw cache was rewritten: %v", err)
	}
	oldVersion := pd.Version()
	for _, conflict := range []string{
		"proxies:\n - {name: C, type: socks5, server: 127.0.0.1, port: 10, dialer-proxy: A}\n",
		"proxies:\n - {name: Other, type: socks5, server: 127.0.0.1, port: 10, dialer-proxy: All}\n",
		"proxies:\n - {name: C, type: direct}\n",
		"proxies:\n - {name: __CORA_CHAIN_UPSTREAM__, type: socks5, server: 127.0.0.1, port: 10}\n",
		"proxies:\n - {name: Other, type: socks5, server: 127.0.0.1, port: 10, dialer-proxy: __CORA_CHAIN_UPSTREAM__}\n",
	} {
		if _, _, err := set.SideUpdate([]byte(conflict)); err == nil {
			t.Fatal("conflicting refresh accepted")
		}
		if pd.Version() != oldVersion {
			t.Fatal("conflicting refresh replaced live adapters")
		}
		if buf, _ := os.ReadFile(cache); string(buf) != string(good) {
			t.Fatal("conflicting refresh replaced raw cache")
		}
	}
	// Renaming a target does not transfer the selection to a new node.
	renamed := []byte("proxies:\n - {name: Renamed, type: socks5, server: 127.0.0.1, port: 11}\n")
	if _, _, err := set.SideUpdate(renamed); err != nil {
		t.Fatal(err)
	}
	if pd.Proxies()[0].ProxyInfo().DialerProxy != "" {
		t.Fatal("renamed node inherited selection")
	}
}

func TestValidateProxyChainRejectsConflictingProviderUpdate(t *testing.T) {
	settingsJSON, err := json.Marshal(chainTestSettings())
	if err != nil {
		t.Fatal(err)
	}
	validate := func(payload string) string {
		payloadsJSON, err := json.Marshal(map[string]string{"P": payload})
		if err != nil {
			t.Fatal(err)
		}
		return ValidateProxyChain(chainFixture, string(payloadsJSON), string(settingsJSON))
	}
	var result struct {
		Error string `json:"error"`
	}
	valid := "proxies:\n  - {name: C, type: socks5, server: 127.0.0.1, port: 8}\n"
	if err := json.Unmarshal([]byte(validate(valid)), &result); err != nil || result.Error != "" {
		t.Fatalf("valid provider update rejected: %v %s", err, result.Error)
	}
	for _, conflict := range []string{
		"proxies:\n  - {name: C, type: socks5, server: 127.0.0.1, port: 8, dialer-proxy: A}\n",
		"proxies:\n  - {name: C, type: direct}\n",
		"proxies:\n  - {name: C, type: dns}\n",
		"proxies:\n  - {name: __CORA_CHAIN_NODE__, type: socks5, server: 127.0.0.1, port: 8}\n",
		"proxies:\n  - {name: Other, type: socks5, server: 127.0.0.1, port: 8, dialer-proxy: __CORA_CHAIN_UPSTREAM__}\n",
	} {
		result.Error = ""
		if err := json.Unmarshal([]byte(validate(conflict)), &result); err != nil || result.Error == "" {
			t.Fatalf("provider update conflict accepted: %v", err)
		}
	}
}

func TestProxyChainPreservesWhitespaceAndDynamicGroupMembership(t *testing.T) {
	fixture := strings.ReplaceAll(chainFixture, "name: A,", "name: ' A ',")
	fixture = strings.ReplaceAll(fixture, "include-all: true}", "include-all: true, proxies: [' A ']}")
	settings := chainTestSettings()
	settings.Mode = "custom"
	settings.YAML = "name: Front\ntype: socks5\nserver: 127.0.0.1\nport: 8\n"
	baseline := chainTestConfig(t, chainTestMap(t, fixture))
	raw := chainTestMap(t, fixture)
	if _, err := applyProxyChain(raw, settings); err != nil {
		t.Fatal(err)
	}
	for _, group := range chainMaps(raw["proxy-groups"]) {
		if group["name"] == "All" && group["include-all"] != true {
			t.Fatal("overlay disabled dynamic include-all behavior")
		}
	}
	overlay := chainTestConfig(t, raw)
	for _, name := range []string{"All", "Manual", "GLOBAL"} {
		members := func(cfg *config.Config) []string {
			var names []string
			for _, p := range cfg.Proxies[name].Adapter().(interface{ GetProxies(bool) []C.Proxy }).GetProxies(false) {
				names = append(names, p.Name())
			}
			return names
		}
		if got, want := members(overlay), members(baseline); !reflect.DeepEqual(got, want) {
			t.Fatalf("%s membership changed: %v != %v", name, got, want)
		}
	}
}

func TestProxyChainRejectsSelfAndIndirectDependencies(t *testing.T) {
	for _, source := range []string{
		strings.Replace(chainFixture, "port: 2, udp: true", "port: 2, udp: true, dialer-proxy: A", 1),
		strings.Replace(chainFixture, "port: 3, udp: true", "port: 3, udp: true, dialer-proxy: B", 1),
		strings.Replace(chainFixture, "port: 1, udp: true", "port: 1, udp: true, dialer-proxy: Manual", 1),
	} {
		if _, err := applyProxyChain(chainTestMap(t, source), chainTestSettings()); err == nil {
			t.Fatal("existing chain conflict accepted")
		}
	}
	settings := chainTestSettings()
	settings.Upstream = &chainReference{"", "B"}
	if _, err := applyProxyChain(chainTestMap(t, chainFixture), settings); err == nil {
		t.Fatal("self chain accepted")
	}
}

func TestProxyChainCatalogUsesProviderEffectiveNamesAndSource(t *testing.T) {
	source := strings.Replace(chainFixture, "type: inline\n    payload:", "type: inline\n    override:\n      additional-prefix: '[P] '\n      override-expr: ['.name |= sub(\"C$\", \"Exit\")']\n    payload:", 1)
	var response struct {
		Nodes []chainCatalogNode `json:"nodes"`
		Error string             `json:"error"`
	}
	if err := json.Unmarshal([]byte(ProxyChainCatalog(source, "{}")), &response); err != nil || response.Error != "" {
		t.Fatalf("catalog failed: %v %s", err, response.Error)
	}
	wanted := map[chainReference]bool{{"", "B"}: false, {"P", "[P] Exit"}: false, {"Q", "C"}: false}
	for _, node := range response.Nodes {
		if _, exists := wanted[node.chainReference]; exists {
			wanted[node.chainReference] = true
		}
	}
	for ref, found := range wanted {
		if !found {
			t.Fatalf("missing reference: %+v", ref)
		}
	}
	settings := chainTestSettings()
	settings.Targets = []chainReference{{"P", "[P] Exit"}}
	raw := chainTestMap(t, source)
	if _, err := applyProxyChain(raw, settings); err != nil {
		t.Fatal(err)
	}
	cfg := chainTestConfig(t, raw)
	if err := cfg.Providers["P"].Initial(); err != nil {
		t.Fatal(err)
	}
	for _, proxy := range cfg.Providers["P"].Proxies() {
		if proxy.Name() == "[P] Exit" && proxy.ProxyInfo().DialerProxy != chainUpstreamName {
			t.Fatal("post-override target not chained")
		}
	}
}

func TestProxyChainProviderUpstreamMissingRejectsRatherThanDirect(t *testing.T) {
	settings := chainTestSettings()
	settings.Upstream = &chainReference{"Q", "Missing"}
	raw := chainTestMap(t, chainFixture)
	if _, err := applyProxyChain(raw, settings); err != nil {
		t.Fatal(err)
	}
	cfg := chainTestConfig(t, raw)
	if err := cfg.Providers["Q"].Initial(); err != nil {
		t.Fatal(err)
	}
	group := cfg.Proxies[chainUpstreamName].Adapter().(outboundgroup.ProxyGroup)
	if group.Now() != "REJECT" {
		t.Fatalf("missing upstream fell back to %q", group.Now())
	}
}

type chainDialRecorder struct {
	C.ProxyAdapter
	tcp int
	udp int
}

func (r *chainDialRecorder) DialContext(context.Context, *C.Metadata) (C.Conn, error) {
	r.tcp++
	return nil, errors.New("recorded upstream failure")
}
func (r *chainDialRecorder) ListenPacketContext(context.Context, *C.Metadata) (C.PacketConn, error) {
	r.udp++
	return nil, errors.New("recorded upstream failure")
}

func TestProxyChainDialsOnlySelectedThroughUpstream(t *testing.T) {
	raw := chainTestMap(t, chainFixture)
	if _, err := applyProxyChain(raw, chainTestSettings()); err != nil {
		t.Fatal(err)
	}
	cfg := chainTestConfig(t, raw)
	recorder := &chainDialRecorder{ProxyAdapter: outbound.NewReject()}
	cfg.Proxies[chainUpstreamName] = adapter.NewProxy(recorder)
	previousProxies, previousProviders := tunnel.Proxies(), tunnel.Providers()
	tunnel.UpdateProxies(cfg.Proxies, cfg.Providers)
	defer tunnel.UpdateProxies(previousProxies, previousProviders)
	metadata := &C.Metadata{Host: "example.invalid", DstPort: 443, NetWork: C.TCP}
	if _, err := cfg.Proxies["B"].DialContext(context.Background(), metadata); err == nil || recorder.tcp != 1 {
		t.Fatalf("selected TCP bypassed upstream: %v, count=%d", err, recorder.tcp)
	}
	if _, err := cfg.Proxies["D"].DialContext(context.Background(), metadata); err == nil || recorder.tcp != 1 {
		t.Fatalf("unselected TCP used upstream: %v, count=%d", err, recorder.tcp)
	}
	metadata.Host = ""
	metadata.DstIP = netip.MustParseAddr("1.1.1.1")
	metadata.NetWork = C.UDP
	if _, err := cfg.Proxies["B"].ListenPacketContext(context.Background(), metadata); err == nil || recorder.tcp < 2 {
		t.Fatalf("selected SOCKS UDP bypassed upstream: %v", err)
	}
}

func TestProxyChainQuotedNamesAndValidationRedaction(t *testing.T) {
	name := "C\" or true ` [节点]"
	raw := chainTestMap(t, strings.Replace(chainFixture, "name: C,", "name: '"+name+"',", 1))
	settings := chainTestSettings()
	settings.Targets = []chainReference{{"P", name}}
	if _, err := applyProxyChain(raw, settings); err != nil {
		t.Fatal(err)
	}
	cfg := chainTestConfig(t, raw)
	if err := cfg.Providers["P"].Initial(); err != nil {
		t.Fatal(err)
	}
	for _, proxy := range cfg.Providers["P"].Proxies() {
		if proxy.Name() != name && proxy.ProxyInfo().DialerProxy != "" {
			t.Fatal("node name escaped its selection")
		}
	}
	settings.Mode = "custom"
	settings.YAML = "name: Private\ntype: unknown-secret-protocol\npassword: TOP-SECRET\n"
	b, _ := json.Marshal(settings)
	response := ValidateProxyChain(chainFixture, "{}", string(b))
	if strings.Contains(response, "TOP-SECRET") || strings.Contains(response, "unknown-secret-protocol") {
		t.Fatal("validation leaked credentials or source")
	}
	if !strings.Contains(response, "error") {
		t.Fatal("invalid custom YAML accepted")
	}
}

func TestProxyChainNameLiteralRoundTrip(t *testing.T) {
	for _, name := range []string{"C<&>节点", "quote\" / \\path", `\(.name)`, "line\n\r\ttab\u2028separator", "x\" or true #"} {
		expr, err := provider.NewOverrideExpr(".name = " + chainLiteral(name))
		if err != nil {
			t.Fatalf("literal %q rejected: %v", name, err)
		}
		m := map[string]any{}
		if err := expr.Apply(m); err != nil || m["name"] != name {
			t.Fatalf("literal %q changed to %q: %v", name, m["name"], err)
		}
	}
}

func TestProxyChainNativeUDPDownstreamUsesUpstream(t *testing.T) {
	raw := chainTestMap(t, strings.Replace(chainFixture,
		"{name: B, type: socks5, server: 127.0.0.1, port: 2, udp: true}",
		"{name: B, type: hysteria2, server: 127.0.0.1, port: 2, password: example, skip-cert-verify: true}", 1))
	if _, err := applyProxyChain(raw, chainTestSettings()); err != nil {
		t.Fatal(err)
	}
	cfg := chainTestConfig(t, raw)
	recorder := &chainDialRecorder{ProxyAdapter: outbound.NewReject()}
	cfg.Proxies[chainUpstreamName] = adapter.NewProxy(recorder)
	previousProxies, previousProviders := tunnel.Proxies(), tunnel.Providers()
	tunnel.UpdateProxies(cfg.Proxies, cfg.Providers)
	defer tunnel.UpdateProxies(previousProxies, previousProviders)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, err := cfg.Proxies["B"].DialContext(ctx, &C.Metadata{DstIP: netip.MustParseAddr("1.1.1.1"), DstPort: 443, NetWork: C.TCP})
	if err == nil || recorder.udp == 0 {
		t.Fatalf("native UDP transport bypassed upstream: %v, calls=%d", err, recorder.udp)
	}
}

func TestProxyChainFilteredAndExplicitGlobalGroupsUnchanged(t *testing.T) {
	fixture := strings.Replace(chainFixture, "include-all: true}", "include-all: true, filter: 'A|B`B|D', exclude-filter: '^D$'}", 1)
	fixture += "\n" // An explicit GLOBAL must not gain the hidden helper either.
	fixture = strings.Replace(fixture, "rules:", "  - {name: GLOBAL, type: select, proxies: [Manual, All]}\nrules:", 1)
	original := chainTestConfig(t, chainTestMap(t, fixture))
	settings := chainTestSettings()
	settings.Mode = "custom"
	settings.YAML = "name: New\ntype: http\nserver: 127.0.0.1\nport: 8\n"
	raw := chainTestMap(t, fixture)
	if _, err := applyProxyChain(raw, settings); err != nil {
		t.Fatal(err)
	}
	cfg := chainTestConfig(t, raw)
	for _, c := range []*config.Config{original, cfg} {
		for _, pd := range c.Providers {
			if err := pd.Initial(); err != nil {
				t.Fatal(err)
			}
		}
	}
	for _, name := range []string{"All", "GLOBAL"} {
		first, _ := original.Proxies[name].MarshalJSON()
		second, _ := cfg.Proxies[name].MarshalJSON()
		if string(first) != string(second) {
			t.Fatalf("%s original group changed:\n%s\n%s", name, first, second)
		}
	}
}

func TestProxyChainMergeIsRuntimeOnlyAndRemovalRestoresBaseline(t *testing.T) {
	settings := parseSettings("")
	settings.GeoEnabled = false
	settings.ProxyChain = chainTestSettings()
	b, err := mergeConfig(chainFixture, settings, 1420)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "dialer-proxy: "+chainUpstreamName) {
		t.Fatal("merge did not apply runtime chain")
	}
	settings.ProxyChain.Enabled = false
	b, err = mergeConfig(chainFixture, settings, 1420)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), chainUpstreamName) || strings.Contains(string(b), "dialer-proxy:") {
		t.Fatal("disabled chain retained runtime overlay")
	}
	settings.ProxyChain.Enabled = true
	settings.ProxyChain.Targets = nil
	b, err = mergeConfig(chainFixture, settings, 1420)
	if err != nil || strings.Contains(string(b), chainUpstreamName) {
		t.Fatalf("empty selection retained runtime overlay: %v", err)
	}
}
