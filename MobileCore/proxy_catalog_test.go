package mihomo

import (
	"encoding/json"
	"fmt"
	"reflect"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

// A real proxy wrapper with an adapter that must never be fully serialized.
// No network connection, health-check loop or loaded VPN config is needed.
type catalogTestAdapter struct {
	*outbound.Base
}

func (*catalogTestAdapter) MarshalJSON() ([]byte, error) {
	panic("the lightweight catalog must not serialize a node or its history")
}

func catalogTestProxy(name string, protocol C.AdapterType) C.Proxy {
	return adapter.NewProxy(&catalogTestAdapter{
		Base: outbound.NewBase(outbound.BaseOption{Name: name, Type: protocol}),
	})
}

func catalogTestGroup(t testing.TB, name string, members []C.Proxy) C.Proxy {
	t.Helper()
	hc := provider.NewHealthCheck(members, C.DefaultTestURL, 5_000, 0, true, nil)
	pd, err := provider.NewCompatibleProvider(name+"-provider", members, hc)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = pd.Close() })
	group, err := outboundgroup.NewSelector(
		outboundgroup.GroupCommonOption{Name: name, Hidden: true, Icon: "https://example.org/icon.png"},
		outboundgroup.SelectorOption{}, members[0], []P.ProxyProvider{pd})
	if err != nil {
		t.Fatal(err)
	}
	return adapter.NewProxy(group)
}

func TestProxyCatalogIncludesUniqueProviderNodeTypes(t *testing.T) {
	ss := catalogTestProxy("香港 SS", C.Shadowsocks)
	snell := catalogTestProxy("SNELL \"节点\"", C.Snell)
	vless := catalogTestProxy("Provider VLESS", C.Vless)
	direct := catalogTestProxy("DIRECT", C.Direct)
	reject := catalogTestProxy("REJECT", C.Reject)
	drop := catalogTestProxy("REJECT-DROP", C.RejectDrop)
	region := catalogTestGroup(t, "Region", []C.Proxy{ss, snell, vless, direct, reject, drop})
	selectGroup := catalogTestGroup(t, "Select", []C.Proxy{region, ss, vless})
	global := catalogTestGroup(t, "GLOBAL", []C.Proxy{selectGroup, region, ss})
	// Provider members deliberately do not appear in the top-level proxy map.
	proxies := map[string]C.Proxy{
		"GLOBAL": global, "Select": selectGroup, "Region": region,
		ss.Name(): ss, "unused": catalogTestProxy("unused", C.Trojan),
	}
	var got struct {
		Mode      string                    `json:"mode"`
		Proxies   map[string]map[string]any `json:"proxies"`
		NodeTypes map[string]string         `json:"nodeTypes"`
	}
	if err := json.Unmarshal([]byte(queryProxyCatalog(proxies, "rule")), &got); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		ss.Name(): "Shadowsocks", snell.Name(): "Snell", vless.Name(): "Vless",
		"DIRECT": "Direct", "REJECT": "Reject", "REJECT-DROP": "RejectDrop",
	}
	if !reflect.DeepEqual(got.NodeTypes, want) {
		t.Fatalf("nodeTypes = %#v, want %#v", got.NodeTypes, want)
	}
	if got.Mode != "rule" || len(got.Proxies) != 3 {
		t.Fatalf("existing catalog fields changed: %#v", got)
	}
	for name, group := range got.Proxies {
		if len(group) != 5 || group["type"] != "Selector" || group["hidden"] != true ||
			group["icon"] != "https://example.org/icon.png" {
			t.Errorf("group %s lost its lightweight fields: %#v", name, group)
		}
	}
	members := got.Proxies["Region"]["all"].([]any)
	if len(members) != 6 || members[1] != snell.Name() || got.Proxies["Region"]["now"] != ss.Name() {
		t.Fatalf("member order or selection changed: %#v", got.Proxies["Region"])
	}
}

func TestProxyCatalogEmptyNodeTypesAreAnObject(t *testing.T) {
	var got struct {
		NodeTypes map[string]string `json:"nodeTypes"`
	}
	if err := json.Unmarshal([]byte(queryProxyCatalog(nil, "direct")), &got); err != nil {
		t.Fatal(err)
	}
	if got.NodeTypes == nil || len(got.NodeTypes) != 0 {
		t.Fatalf("empty nodeTypes = %#v", got.NodeTypes)
	}
}

func TestOfflineProxyCatalogIncludesProtocolsAndBuiltins(t *testing.T) {
	config := `proxies:
  - {name: SS Node, type: ss}
  - {name: Snell Node, type: snell}
proxy-providers:
  airport: {type: http, url: https://example.org/provider.yaml}
proxy-groups:
  - {name: Region, type: select, proxies: [SS Node, Snell Node, DIRECT, REJECT, REJECT-DROP, PASS, PASS-RULE, COMPATIBLE], use: [airport]}
  - {name: Select, type: select, proxies: [Region]}
`
	payloads, err := json.Marshal(map[string]string{
		"airport": "proxies:\n  - {name: Provider VLESS, type: vless}\n",
	})
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		NodeTypes map[string]string `json:"nodeTypes"`
	}
	if err := json.Unmarshal([]byte(OfflineProxySnapshot(config, string(payloads), "{}")), &got); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"SS Node": "ss", "Snell Node": "snell", "Provider VLESS": "vless",
		"DIRECT": "direct", "REJECT": "reject", "REJECT-DROP": "reject-drop",
		"PASS": "pass", "PASS-RULE": "pass-rule", "COMPATIBLE": "compatible",
	}
	if !reflect.DeepEqual(got.NodeTypes, want) {
		t.Fatalf("offline nodeTypes = %#v, want %#v", got.NodeTypes, want)
	}
}

var catalogBenchmarkResult string

func BenchmarkProxyCatalog(b *testing.B) {
	for _, count := range []int{100, 1_000, 5_000} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			members := make([]C.Proxy, count)
			for index := range members {
				members[index] = catalogTestProxy(fmt.Sprintf("香港节点-%04d", index), C.Shadowsocks)
			}
			proxies := make(map[string]C.Proxy)
			for index := 0; index < 8; index++ {
				name := fmt.Sprintf("group-%d", index)
				proxies[name] = catalogTestGroup(b, name, members)
			}
			for _, variant := range []struct {
				name string
				run  func(map[string]C.Proxy, string) string
			}{
				{"before", queryProxyCatalogBeforeLabels},
				{"after", queryProxyCatalog},
			} {
				b.Run(variant.name, func(b *testing.B) {
					response := variant.run(proxies, "rule")
					b.ReportAllocs()
					b.ResetTimer()
					for index := 0; index < b.N; index++ {
						catalogBenchmarkResult = variant.run(proxies, "rule")
					}
					b.ReportMetric(float64(len(response)), "response_B")
				})
			}
		})
	}
}

// The previous production query, retained only for allocation comparisons.
func queryProxyCatalogBeforeLabels(proxies map[string]C.Proxy, mode string) string {
	groups := map[string]any{}
	for name, proxy := range proxies {
		group, ok := proxy.Adapter().(outboundgroup.ProxyGroup)
		if !ok {
			continue
		}
		members := group.Proxies()
		all := make([]string, 0, len(members))
		for _, member := range members {
			all = append(all, member.Name())
		}
		groups[name] = map[string]any{
			"type": proxy.Type().String(), "now": group.Now(), "all": all,
			"icon": group.Icon(), "hidden": group.Hidden(),
		}
	}
	out, _ := json.Marshal(map[string]any{"proxies": groups, "mode": mode})
	return string(out)
}
