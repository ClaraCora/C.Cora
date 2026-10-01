package mihomo

import (
	"os"
	"sync/atomic"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	mdns "github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/tunnel"
	tun "github.com/metacubex/sing-tun"
)

// These categories overlap with Go heap accounting. File sizes and item
// counts must never be added to heapAlloc or called precise resident bytes.
type memoryAttribution struct {
	ProxyCount         int `json:"proxyCount"`
	PolicyGroupCount   int `json:"policyGroupCount"`
	ProxyProviderNodes int `json:"proxyProviderNodes"`
	RuleProviderRules  int `json:"ruleProviderRules"`
	DNSCacheEntries    int `json:"dnsCacheEntries"`
	DNSCacheCount      int `json:"dnsCacheCount"`
	*mdns.EnhancerCacheStats
	*tun.QueueStats
	GeoMode           string  `json:"geoMode"`
	GeoLoader         string  `json:"geoLoader"`
	GeoSiteMatcher    string  `json:"geoSiteMatcher"`
	GeoIPFileBytes    *uint64 `json:"geoIPFileBytes,omitempty"`
	GeoSiteFileBytes  *uint64 `json:"geoSiteFileBytes,omitempty"`
	MMDBFileBytes     *uint64 `json:"mmdbFileBytes,omitempty"`
	ASNFileBytes      *uint64 `json:"asnFileBytes,omitempty"`
	ForceGCSuppressed uint64  `json:"forceGCSuppressed"`
}

// Caller holds configApplyMu.RLock. This is used only by RuntimeStats queries
// (developer mode or an explicit user diagnostic), with no new sampling task.
func collectMemoryAttribution() memoryAttribution {
	stats := memoryAttribution{GeoMode: "mmdb", GeoLoader: geodata.LoaderName(),
		GeoSiteMatcher: geodata.SiteMatcherName(), ForceGCSuppressed: atomic.LoadUint64(&forceGCSuppressed)}
	if geodata.GeodataMode() {
		stats.GeoMode = "dat"
	}
	proxies := tunnel.Proxies()
	stats.ProxyCount = len(proxies)
	for _, proxy := range proxies {
		if _, ok := proxy.Adapter().(outboundgroup.ProxyGroup); ok {
			stats.PolicyGroupCount++
		}
	}
	for _, provider := range tunnel.Providers() {
		stats.ProxyProviderNodes += provider.Count()
	}
	for _, provider := range tunnel.RuleProviders() {
		if count, ok := provider.(interface{ DiagnosticRuleCount() int }); ok {
			stats.RuleProviderRules += count.DiagnosticRuleCount()
		}
	}
	runtime := resolver.CurrentDNSRuntime()
	var sources []*mdns.Resolver
	for _, role := range []resolver.Resolver{runtime.DefaultResolver, runtime.ProxyServerHostResolver, runtime.DirectHostResolver} {
		switch source := role.(type) {
		case mdns.Resolvers:
			sources = append(sources, source.Resolver, source.ProxyResolver, source.DirectResolver)
		case *mdns.Resolver:
			sources = append(sources, source)
		}
	}
	stats.DNSCacheEntries, stats.DNSCacheCount = mdns.CacheEntries(sources...)
	if mapper, ok := resolver.DefaultHostMapper.(*mdns.ResolverEnhancer); ok {
		snapshot := mapper.CacheStats()
		stats.EnhancerCacheStats = &snapshot
	}
	stats.QueueStats = listener.TunQueueSnapshot()
	stats.GeoIPFileBytes = diagnosticFileSize(C.Path.GeoIP())
	stats.GeoSiteFileBytes = diagnosticFileSize(C.Path.GeoSite())
	stats.MMDBFileBytes = diagnosticFileSize(C.Path.MMDB())
	stats.ASNFileBytes = diagnosticFileSize(C.Path.ASN())
	return stats
}

func diagnosticFileSize(path string) *uint64 {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() < 0 {
		return nil
	}
	size := uint64(info.Size())
	return &size
}
