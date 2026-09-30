package mihomo

import (
	"bytes"
	"fmt"
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

func TestControlByteResponsesPreserveJSON(t *testing.T) {
	for _, limit := range []int{-1, 0, 1, 500, 1000} {
		if !bytes.Equal(ConnectionsSnapshotData(limit), []byte(ConnectionsSnapshot(limit))) {
			t.Fatalf("connection JSON changed for limit %d", limit)
		}
	}
	old := proxyDetailsMap
	proxyDetailsMap = map[string]string{"香港 \"节点\"": "VLESS · TCP · Reality", "空": ""}
	t.Cleanup(func() { proxyDetailsMap = old })
	if !bytes.Equal(ProxyDetailsData(), []byte(ProxyDetails())) {
		t.Fatal("node summary JSON changed")
	}
	for _, request := range []string{
		"invalid json", `{}`, `{"url":"http://example.org"}`,
		`{"url":"https://example.org","method":"DELETE"}`,
		`{"url":"https://example.org","name":"missing-node"}`,
	} {
		if !bytes.Equal(ScriptFetchData(request), []byte(ScriptFetch(request))) {
			t.Fatalf("script error JSON changed for %s", request)
		}
	}
	ss := catalogTestProxy("香港 SS", C.Shadowsocks)
	snell := catalogTestProxy("Snell", C.Snell)
	group := catalogTestGroup(t, "选择", []C.Proxy{ss, snell})
	proxies := map[string]C.Proxy{"选择": group}
	if !bytes.Equal(queryProxyCatalogData(proxies, "rule"), []byte(queryProxyCatalog(proxies, "rule"))) {
		t.Fatal("catalog JSON changed")
	}
	if !bytes.Equal(QueryProxiesData(), []byte(QueryProxies())) {
		t.Fatal("live catalog JSON changed")
	}
}

var byteResponseBenchmarkSink []byte
var stringResponseBenchmarkSink string

func BenchmarkProxyCatalogBridgeResponse(b *testing.B) {
	for _, count := range []int{1000, 5000} {
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
			responseSize := len(queryProxyCatalogData(proxies, "rule"))
			b.Run("string", func(b *testing.B) {
				b.ReportAllocs()
				b.ReportMetric(float64(responseSize), "response-B")
				for index := 0; index < b.N; index++ {
					stringResponseBenchmarkSink = queryProxyCatalog(proxies, "rule")
				}
			})
			b.Run("bytes", func(b *testing.B) {
				b.ReportAllocs()
				b.ReportMetric(float64(responseSize), "response-B")
				for index := 0; index < b.N; index++ {
					byteResponseBenchmarkSink = queryProxyCatalogData(proxies, "rule")
				}
			})
		})
	}
}
