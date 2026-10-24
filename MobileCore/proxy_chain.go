package mihomo

import (
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/dlclark/regexp2"
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/common/convert"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
	"go.yaml.in/yaml/v3"
)

const (
	chainUpstreamName = "__CORA_CHAIN_UPSTREAM__"
	chainCustomName   = "__CORA_CHAIN_NODE__"
	chainMaxTargets   = 4096
	chainMaxYAMLBytes = 64 * 1024
)

var chainNonProxyTypes = []string{"", "direct", "reject", "reject-drop", "pass", "pass-rule", "compatible", "dns", "rematch", "select", "selector", "url-test", "urltest", "fallback", "load-balance", "loadbalance", "relay"}

// Source is empty for top-level proxies, otherwise it is the exact provider
// name. A provider's final (post-override) name is used, never a fuzzy match.
type chainReference struct {
	Source string `json:"source"`
	Name   string `json:"name"`
}

type proxyChainSettings struct {
	Enabled  bool             `json:"enabled"`
	Mode     string           `json:"mode"`
	Upstream *chainReference  `json:"upstream,omitempty"`
	YAML     string           `json:"yaml"`
	Targets  []chainReference `json:"targets"`
}

type chainCatalogNode struct {
	chainReference
	Type  string `json:"type"`
	Issue string `json:"issue,omitempty"`
}

func chainRealType(typ string) bool {
	for _, special := range chainNonProxyTypes {
		if strings.EqualFold(typ, special) {
			return false
		}
	}
	return true
}

func chainString(m map[string]any, key string) string { s, _ := m[key].(string); return s }

func chainMaps(value any) []map[string]any {
	var out []map[string]any
	switch values := value.(type) {
	case []any:
		for _, value := range values {
			if m, ok := value.(map[string]any); ok {
				out = append(out, m)
			}
		}
	case []map[string]any:
		out = values
	}
	return out
}

func chainCopy(m map[string]any) map[string]any {
	// Provider overrides may update nested fields. Do not mutate a cache or a
	// fallback payload while deriving its effective name and dependencies.
	return chainCopyValue(m).(map[string]any)
}

func chainCopyValue(value any) any {
	switch v := value.(type) {
	case map[string]any:
		copy := make(map[string]any, len(v))
		for key, child := range v {
			copy[key] = chainCopyValue(child)
		}
		return copy
	case []any:
		copy := make([]any, len(v))
		for index, child := range v {
			copy[index] = chainCopyValue(child)
		}
		return copy
	default:
		return value
	}
}

func chainMatches(pattern, name string) (bool, error) {
	if pattern == "" {
		return true, nil
	}
	for _, part := range strings.Split(pattern, "`") {
		r, err := regexp2.Compile(part, regexp2.None)
		if err != nil {
			return false, fmt.Errorf("节点筛选表达式无效")
		}
		r.MatchTimeout = 100 * time.Millisecond
		match, err := r.MatchString(name)
		if err != nil {
			return false, fmt.Errorf("节点筛选表达式超时")
		}
		if match {
			return true, nil
		}
	}
	return false, nil
}

// Mirror provider override order, including renaming and override-expr. This
// runs only for the settings inventory/validation, never on the packet path.
func chainProviderMappings(def map[string]any, payload []map[string]any) ([]map[string]any, error) {
	var out []map[string]any
	for _, raw := range payload {
		name, typ := chainString(raw, "name"), chainString(raw, "type")
		include, err := chainMatches(chainString(def, "filter"), name)
		if err != nil {
			return nil, err
		}
		exclude := false
		if pattern := chainString(def, "exclude-filter"); pattern != "" {
			exclude, err = chainMatches(pattern, name)
			if err != nil {
				return nil, err
			}
		}
		for _, excluded := range strings.Split(chainString(def, "exclude-type"), "|") {
			if excluded != "" && strings.EqualFold(excluded, typ) {
				exclude = true
			}
		}
		if !include || exclude {
			continue
		}
		m := chainCopy(raw)
		if dialer := chainString(def, "dialer-proxy"); dialer != "" {
			m["dialer-proxy"] = dialer
		}
		override, _ := def["override"].(map[string]any)
		for _, key := range []string{"tfo", "mptcp", "udp", "udp-over-tcp", "up", "down", "dialer-proxy", "skip-cert-verify", "name-cert-verify", "interface-name", "routing-mark", "ip-version"} {
			if value, ok := override[key]; ok {
				m[key] = value
			}
		}
		for _, rule := range chainMaps(override["proxy-name"]) {
			r, err := regexp2.Compile(chainString(rule, "pattern"), regexp2.None)
			if err != nil {
				return nil, fmt.Errorf("Provider 节点重命名表达式无效")
			}
			r.MatchTimeout = 100 * time.Millisecond
			name, err = r.Replace(chainString(m, "name"), chainString(rule, "target"), 0, -1)
			if err != nil {
				return nil, fmt.Errorf("Provider 节点重命名失败")
			}
			m["name"] = name
		}
		m["name"] = chainString(override, "additional-prefix") + chainString(m, "name") + chainString(override, "additional-suffix")
		for _, source := range stringList(override["override-expr"]) {
			expr, err := provider.NewOverrideExpr(source)
			if err != nil {
				return nil, fmt.Errorf("Provider 覆写表达式无效")
			}
			if err := expr.Apply(m); err != nil {
				return nil, fmt.Errorf("Provider 覆写执行失败")
			}
		}
		out = append(out, m)
	}
	return out, nil
}

func chainReadConfig(configYAML, payloadsJSON string) (map[string]any, error) {
	m := map[string]any{}
	if err := yaml.Unmarshal([]byte(configYAML), &m); err != nil {
		return nil, fmt.Errorf("当前配置 YAML 无效")
	}
	if m == nil {
		m = map[string]any{}
	}
	payloads := map[string]string{}
	if payloadsJSON != "" && json.Unmarshal([]byte(payloadsJSON), &payloads) != nil {
		return nil, fmt.Errorf("Provider 缓存索引无效")
	}
	providers, _ := m["proxy-providers"].(map[string]any)
	for source, payload := range payloads {
		def, ok := providers[source].(map[string]any)
		if !ok {
			continue
		}
		var schema struct {
			Proxies []map[string]any `yaml:"proxies"`
		}
		err := yaml.Unmarshal([]byte(payload), &schema)
		if err != nil || schema.Proxies == nil {
			schema.Proxies, err = convert.ConvertsV2Ray([]byte(payload))
		}
		if err != nil {
			return nil, fmt.Errorf("Provider 缓存无法解析，请刷新远程资源")
		}
		def["payload"] = schema.Proxies
	}
	return m, nil
}

func chainInventory(m map[string]any) ([]chainCatalogNode, map[chainReference]map[string]any, []string, error) {
	nodes := []chainCatalogNode{}
	mappings := map[chainReference]map[string]any{}
	warnings := []string{}
	add := func(source string, entries []map[string]any) {
		for _, entry := range entries {
			name, typ := chainString(entry, "name"), chainString(entry, "type")
			if name == "" || chainReservedName(name) || !chainRealType(typ) {
				continue
			}
			ref := chainReference{source, name}
			if _, exists := mappings[ref]; exists {
				for i := range nodes {
					if nodes[i].chainReference == ref {
						nodes[i].Issue = "同一来源存在重名节点，无法精确选择"
					}
				}
				continue
			}
			mappings[ref] = entry
			nodes = append(nodes, chainCatalogNode{chainReference: ref, Type: typ})
		}
	}
	add("", chainMaps(m["proxies"]))
	providers, _ := m["proxy-providers"].(map[string]any)
	names := make([]string, 0, len(providers))
	for name := range providers {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		def, _ := providers[name].(map[string]any)
		payload := chainMaps(def["payload"])
		if len(payload) == 0 {
			warnings = append(warnings, "节点来源尚未缓存："+name)
			continue
		}
		entries, err := chainProviderMappings(def, payload)
		if err != nil {
			return nil, nil, nil, err
		}
		add(name, entries)
	}
	return nodes, mappings, warnings, nil
}

// ProxyChainCatalog is credential-free and does not initialize providers,
// listeners, a tunnel, or any network requests.
func ProxyChainCatalog(configYAML, providerPayloadsJSON string) string {
	m, err := chainReadConfig(configYAML, providerPayloadsJSON)
	if err != nil {
		return marshalJSON(map[string]any{"error": err.Error()})
	}
	nodes, _, warnings, err := chainInventory(m)
	if err != nil {
		return marshalJSON(map[string]any{"error": err.Error()})
	}
	return marshalJSON(map[string]any{"nodes": nodes, "warnings": warnings})
}

// ProxyChainRuntimeCatalog reports the currently loaded provider versions;
// unlike the App's offline cache it also observes automatic provider updates.
func ProxyChainRuntimeCatalog() string {
	configApplyMu.RLock()
	defer configApplyMu.RUnlock()
	nodes := []chainCatalogNode{}
	for name, proxy := range tunnel.Proxies() {
		_, isGroup := proxy.Adapter().(outboundgroup.ProxyGroup)
		if chainReservedName(name) || !chainRealType(proxy.Type().String()) || isGroup {
			continue
		}
		nodes = append(nodes, chainCatalogNode{chainReference: chainReference{"", name}, Type: proxy.Type().String()})
	}
	for source, pd := range tunnel.Providers() {
		if pd.VehicleType() == P.Compatible {
			continue
		}
		seen := map[string]bool{}
		for _, proxy := range pd.Proxies() {
			if chainReservedName(proxy.Name()) || !chainRealType(proxy.Type().String()) || seen[proxy.Name()] {
				continue
			}
			seen[proxy.Name()] = true
			nodes = append(nodes, chainCatalogNode{chainReference: chainReference{source, proxy.Name()}, Type: proxy.Type().String()})
		}
	}
	sort.Slice(nodes, func(i, j int) bool {
		if nodes[i].Source != nodes[j].Source {
			return nodes[i].Source < nodes[j].Source
		}
		return nodes[i].Name < nodes[j].Name
	})
	return marshalJSON(map[string]any{"nodes": nodes, "warnings": []string{}})
}

// ValidateProxyChain returns only safe validation messages, never parser
// errors containing a pasted password or the original YAML.
func ValidateProxyChain(configYAML, providerPayloadsJSON, chainJSON string) string {
	m, err := chainReadConfig(configYAML, providerPayloadsJSON)
	var settings proxyChainSettings
	if err == nil && json.Unmarshal([]byte(chainJSON), &settings) != nil {
		err = fmt.Errorf("前置设置格式无效")
	}
	var warnings []string
	if err == nil {
		warnings, err = applyProxyChain(m, settings)
	}
	if err != nil {
		return marshalJSON(map[string]any{"error": err.Error()})
	}
	return marshalJSON(map[string]any{"warnings": warnings})
}

func chainLiteral(value string) string {
	// override-expr follows yq's small escape set, not JSON's \uXXXX escapes.
	return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`).Replace(value) + `"`
}

func chainNameCondition(refs []chainReference) string {
	parts := make([]string, 0, len(refs))
	for _, ref := range refs {
		parts = append(parts, ".name == "+chainLiteral(ref.Name))
	}
	if len(parts) == 0 {
		return "false"
	}
	return "(" + strings.Join(parts, " or ") + ")"
}

func chainCustomProxy(source string) (map[string]any, error) {
	if len(source) > chainMaxYAMLBytes {
		return nil, fmt.Errorf("单节点 YAML 不能超过 64 KB")
	}
	var m map[string]any
	if yaml.Unmarshal([]byte(source), &m) != nil || m == nil || !chainRealType(chainString(m, "type")) || chainString(m, "name") == "" {
		return nil, fmt.Errorf("请粘贴包含 name、type 的单节点 YAML 映射，而不是完整配置或 proxies 列表")
	}
	if chainString(m, "dialer-proxy") != "" {
		return nil, fmt.Errorf("单独添加的前置不能再指定 dialer-proxy")
	}
	// Use the same protocol parser as the runtime, then immediately release its
	// resources. Errors are intentionally redacted because they may echo keys.
	p, err := adapter.ParseProxy(m)
	if err != nil {
		return nil, fmt.Errorf("前置节点参数无效，请检查协议、服务器、端口及认证字段")
	}
	_ = p.Close()
	m["name"] = chainCustomName
	return m, nil
}

// Groups in this set can route to a selected target. Existing dialer-proxy
// references to any of them would change an unselected node indirectly. Be
// conservative about provider membership so future updates remain isolated.
func chainProtectedNames(m map[string]any, targets []chainReference) map[string]bool {
	protected := map[string]bool{chainUpstreamName: true, chainCustomName: true}
	if len(targets) > 0 {
		protected["GLOBAL"] = true
	}
	sources := map[string]bool{}
	for _, target := range targets {
		// mihomo's dialer-proxy field is name-only. If a selected Provider
		// node shares a name with any other source, reject every matching
		// existing reference conservatively instead of letting an unselected
		// node inherit the chain through an ambiguous name.
		protected[target.Name] = true
		if target.Source != "" {
			sources[target.Source] = true
		}
	}
	groups := chainMaps(m["proxy-groups"])
	for changed := true; changed; {
		changed = false
		for _, group := range groups {
			name := chainString(group, "name")
			if protected[name] {
				continue
			}
			hit := false
			hit = hit || protected[chainString(group, "empty-fallback")]
			for _, member := range stringList(group["proxies"]) {
				hit = hit || protected[member]
			}
			for _, source := range stringList(group["use"]) {
				hit = hit || sources[source]
			}
			all, _ := group["include-all"].(bool)
			allProviders, _ := group["include-all-providers"].(bool)
			allProxies, _ := group["include-all-proxies"].(bool)
			hit = hit || (all || allProviders) && len(sources) > 0
			if all || allProxies {
				for _, target := range targets {
					hit = hit || target.Source == ""
				}
			}
			if hit {
				protected[name] = true
				changed = true
			}
		}
	}
	return protected
}

func applyProxyChain(m map[string]any, settings proxyChainSettings) ([]string, error) {
	warnings := []string{}
	if !settings.Enabled {
		return warnings, nil
	}
	if len(settings.Targets) > chainMaxTargets {
		return nil, fmt.Errorf("后置节点最多可勾选 4096 个")
	}
	if settings.Mode != "existing" && settings.Mode != "custom" {
		return nil, fmt.Errorf("请选择前置节点来源")
	}
	if settings.Mode == "existing" && (settings.Upstream == nil || settings.Upstream.Name == "") {
		return nil, fmt.Errorf("请选择前置节点")
	}
	if settings.Mode == "existing" && chainReservedName(settings.Upstream.Name) {
		return nil, fmt.Errorf("前置必须是真实代理节点")
	}
	targetSet := map[chainReference]bool{}
	for _, ref := range settings.Targets {
		if ref.Name == "" || chainReservedName(ref.Name) {
			return nil, fmt.Errorf("后置必须是真实代理节点")
		}
		if settings.Mode == "existing" && ref == *settings.Upstream {
			return nil, fmt.Errorf("前置节点不能同时作为后置节点")
		}
		targetSet[ref] = true
	}
	var custom map[string]any
	var err error
	if settings.Mode == "custom" {
		custom, err = chainCustomProxy(settings.YAML)
		if err != nil {
			return nil, err
		}
	}
	if len(settings.Targets) == 0 {
		return warnings, nil
	}
	for _, section := range []string{"proxies", "proxy-groups"} {
		for _, item := range chainMaps(m[section]) {
			if name := chainString(item, "name"); name == chainCustomName || name == chainUpstreamName {
				return nil, fmt.Errorf("配置节点名与 App 内部前置名称冲突")
			}
		}
	}
	providers, _ := m["proxy-providers"].(map[string]any)
	if _, exists := providers[chainUpstreamName]; exists {
		return nil, fmt.Errorf("Provider 名称与 App 内部前置名称冲突")
	}
	for source, value := range providers {
		def, _ := value.(map[string]any)
		for _, entry := range chainMaps(def["payload"]) {
			if name := chainString(entry, "name"); name == chainUpstreamName || name == chainCustomName {
				return nil, fmt.Errorf("Provider %s 的节点名与 App 内部前置名称冲突", source)
			}
		}
	}
	nodes, mappings, notices, err := chainInventory(m)
	if err != nil {
		return nil, err
	}
	warnings = append(warnings, notices...)
	for _, node := range nodes {
		if node.Issue != "" && (targetSet[node.chainReference] || settings.Mode == "existing" && settings.Upstream != nil && node.chainReference == *settings.Upstream) {
			return nil, fmt.Errorf("节点重名，无法精确应用前置：%s", node.Name)
		}
	}
	protected := chainProtectedNames(m, settings.Targets)
	for ref, mapping := range mappings {
		dialer := chainString(mapping, "dialer-proxy")
		if dialer != "" && (targetSet[ref] || protected[dialer]) {
			return nil, fmt.Errorf("节点 %s 的已有代理链与勾选范围冲突，请先取消勾选相关节点", ref.Name)
		}
	}
	// Include non-proxy builtins in dependency validation as well.
	for _, mapping := range chainMaps(m["proxies"]) {
		if targetSet[chainReference{"", chainString(mapping, "name")}] && !chainRealType(chainString(mapping, "type")) {
			return nil, fmt.Errorf("勾选项已不是真实代理节点，请重新选择")
		}
		if protected[chainString(mapping, "dialer-proxy")] {
			return nil, fmt.Errorf("已有代理链引用了勾选节点，无法保持未勾选节点原链路")
		}
	}
	for ref := range targetSet {
		if mappings[ref] == nil {
			warnings = append(warnings, "勾选节点当前不存在或尚未缓存："+ref.Name)
		}
	}
	chainPreserveGlobalGroup(m)
	// Keep every original group dynamic while preventing the App-only custom
	// proxy from entering include-all groups. Provider refreshes therefore keep
	// their normal membership and the user's original filters remain intact.
	if settings.Mode == "custom" {
		chainExcludeInternalProxyFromGroups(m)
	}
	upstream := map[string]any{"name": chainUpstreamName, "type": "select", "hidden": true, "empty-fallback": "REJECT"}
	if settings.Mode == "custom" {
		items, _ := m["proxies"].([]any)
		m["proxies"] = append(items, custom)
		upstream["proxies"] = []any{chainCustomName}
	} else if ref := *settings.Upstream; ref.Source == "" {
		if mappings[ref] == nil {
			upstream["proxies"] = []any{"REJECT"}
			warnings = append(warnings, "前置节点不存在，勾选节点将拒绝连接")
		} else {
			upstream["proxies"] = []any{ref.Name}
		}
	} else if _, exists := providers[ref.Source]; exists {
		upstream["use"] = []any{ref.Source}
		upstream["filter"] = `\A` + strings.ReplaceAll(regexp.QuoteMeta(ref.Name), "`", `\x60`) + `\z`
	} else {
		upstream["proxies"] = []any{"REJECT"}
		warnings = append(warnings, "前置来源不存在，勾选节点将拒绝连接")
	}
	for _, mapping := range chainMaps(m["proxies"]) {
		if targetSet[chainReference{"", chainString(mapping, "name")}] {
			mapping["dialer-proxy"] = chainUpstreamName
		}
	}
	unsafe := make([]string, 0, len(protected))
	for name := range protected {
		unsafe = append(unsafe, name)
	}
	sort.Strings(unsafe)
	for source, value := range providers {
		def, _ := value.(map[string]any)
		override, _ := def["override"].(map[string]any)
		if override == nil {
			override = map[string]any{}
		}
		var selected []chainReference
		for _, target := range settings.Targets {
			if target.Source == source {
				selected = append(selected, target)
			}
		}
		condition := chainNameCondition(selected)
		guard := "(" + condition + " == false or (.dialer-proxy // \"\") == \"\")"
		required := append([]chainReference{}, selected...)
		if settings.Mode == "existing" && settings.Upstream.Source == source {
			required = append(required, *settings.Upstream)
		}
		if len(required) > 0 {
			var realType []string
			for _, typ := range chainNonProxyTypes {
				realType = append(realType, "(.type // \"\") != "+chainLiteral(typ))
			}
			guard += " and (" + chainNameCondition(required) + " == false or (" + strings.Join(realType, " and ") + "))"
		}
		// Keep Provider refreshes from introducing a node that collides with
		// the hidden helper objects added by this overlay. A false select makes
		// mihomo retain the previous Provider version rather than dropping only
		// the offending entry.
		guard += " and .name != " + chainLiteral(chainUpstreamName)
		guard += " and .name != " + chainLiteral(chainCustomName)
		for _, name := range unsafe {
			guard += " and (.dialer-proxy // \"\") != " + chainLiteral(name)
		}
		// A failing filter returns an error (not a dropped node), so the native
		// fetcher retains both its previous adapters and the raw cache file.
		expressions := stringList(override["override-expr"])
		guardSource := ". | select(" + guard + ")"
		guardExpr, err := provider.NewOverrideExpr(guardSource)
		if err != nil {
			return nil, fmt.Errorf("前置条件生成失败")
		}
		entries, err := chainProviderMappings(def, chainMaps(def["payload"]))
		if err != nil {
			return nil, err
		}
		for _, entry := range entries {
			if err := guardExpr.Apply(entry); err != nil {
				return nil, fmt.Errorf("Provider %s 的节点与前置设置冲突，请检查节点类型、名称及已有代理链", source)
			}
		}
		expressions = append(expressions, guardSource)
		if len(selected) > 0 {
			expressions = append(expressions, "(select("+condition+") | .dialer-proxy) = "+chainLiteral(chainUpstreamName))
		}
		for _, expression := range expressions {
			if _, err := provider.NewOverrideExpr(expression); err != nil {
				return nil, fmt.Errorf("前置条件生成失败")
			}
		}
		override["override-expr"] = stringsToAny(expressions)
		def["override"] = override
	}
	groups, _ := m["proxy-groups"].([]any)
	m["proxy-groups"] = append(groups, upstream)
	return warnings, nil
}

func chainReservedName(name string) bool {
	switch name {
	case "DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE", "GLOBAL", chainUpstreamName, chainCustomName:
		return true
	}
	return false
}

func chainExcludeInternalProxyFromGroups(m map[string]any) {
	pattern := `\A` + regexp.QuoteMeta(chainCustomName) + `\z`
	for _, group := range chainMaps(m["proxy-groups"]) {
		all, _ := group["include-all"].(bool)
		allProxies, _ := group["include-all-proxies"].(bool)
		if !all && !allProxies {
			continue
		}
		existing := chainString(group, "exclude-filter")
		if existing != "" {
			existing += "`"
		}
		group["exclude-filter"] = existing + pattern
	}
}

// The native implicit GLOBAL includes all top-level nodes and groups. Commit
// its original member list before adding helpers, preserving order and exact
// node names while keeping the helpers out of the user's global selection.
func chainPreserveGlobalGroup(m map[string]any) {
	groups := chainMaps(m["proxy-groups"])
	for _, group := range groups {
		if chainString(group, "name") == "GLOBAL" {
			return
		}
	}
	members := []any{"DIRECT", "REJECT"}
	for _, proxy := range chainMaps(m["proxies"]) {
		typ := strings.ToLower(chainString(proxy, "type"))
		if typ != "pass" && typ != "pass-rule" {
			members = append(members, chainString(proxy, "name"))
		}
	}
	items := make([]any, 0, len(groups)+1)
	for _, group := range groups {
		members = append(members, chainString(group, "name"))
		items = append(items, group)
	}
	m["proxy-groups"] = append(items, map[string]any{"name": "GLOBAL", "type": "select", "proxies": members})
}
