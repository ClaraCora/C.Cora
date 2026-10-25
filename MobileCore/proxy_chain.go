package mihomo

import (
	"encoding/json"
	"errors"
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
	chainLegacyID       = "00000000-0000-0000-0000-000000000001"
	chainUpstreamPrefix = "__CORA_CHAIN_UPSTREAM__"
	chainCustomPrefix   = "__CORA_CHAIN_NODE__"
	chainUpstreamName   = chainUpstreamPrefix + "00000000000000000000000000000001"
	chainCustomName     = chainCustomPrefix + "00000000000000000000000000000001"
	chainMaxGroups      = 32
	chainMaxTargets     = 4096
	chainMaxYAMLBytes   = 64 * 1024
)

var chainNonProxyTypes = []string{"", "direct", "reject", "reject-drop", "pass", "pass-rule", "compatible", "dns", "rematch", "select", "selector", "url-test", "urltest", "fallback", "load-balance", "loadbalance", "relay"}
var chainGroupIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// Source is empty for top-level proxies, otherwise it is the exact provider
// name. A provider's final (post-override) name is used, never a fuzzy match.
type chainReference struct {
	Source string `json:"source"`
	Name   string `json:"name"`
}

type proxyChainSettings struct {
	Version  int               `json:"version,omitempty"`
	Groups   []proxyChainGroup `json:"groups,omitempty"`
	Enabled  bool              `json:"enabled"`
	Mode     string            `json:"mode"`
	Upstream *chainReference   `json:"upstream,omitempty"`
	YAML     string            `json:"yaml"`
	Targets  []chainReference  `json:"targets"`
}

type proxyChainGroup struct {
	ID       string           `json:"id"`
	Name     string           `json:"name"`
	Enabled  bool             `json:"enabled"`
	Mode     string           `json:"mode"`
	Upstream *chainReference  `json:"upstream,omitempty"`
	YAML     string           `json:"yaml"`
	Targets  []chainReference `json:"targets"`
}

func (g proxyChainGroup) upstreamName() string {
	return chainUpstreamPrefix + strings.ReplaceAll(strings.ToLower(g.ID), "-", "")
}
func (g proxyChainGroup) customName() string {
	return chainCustomPrefix + strings.ReplaceAll(strings.ToLower(g.ID), "-", "")
}

type chainGroupError struct {
	GroupID      string
	OtherGroupID string
	Message      string
}

func (e *chainGroupError) Error() string { return e.Message }
func chainGroupFailure(g proxyChainGroup, message string, other ...proxyChainGroup) error {
	e := &chainGroupError{GroupID: g.ID, Message: g.Name + "：" + message}
	if len(other) > 0 {
		e.OtherGroupID = other[0].ID
		e.Message += "（" + other[0].Name + "）"
	}
	return e
}

// Legacy snapshots use the same stable ID as the App migration. No random
// identity is generated while decoding a successful reconnect snapshot.
func (s proxyChainSettings) normalizedGroups() ([]proxyChainGroup, error) {
	if s.Version != 0 && s.Version != 2 {
		return nil, fmt.Errorf("前置设置版本不受支持")
	}
	groups := s.Groups
	if s.Version == 0 && groups == nil {
		mode := s.Mode
		if mode == "" {
			mode = "existing"
		}
		if s.Enabled || s.Upstream != nil || s.YAML != "" || len(s.Targets) > 0 || mode != "existing" {
			groups = []proxyChainGroup{{ID: chainLegacyID, Name: "分组 1", Enabled: true, Mode: mode, Upstream: s.Upstream, YAML: s.YAML, Targets: s.Targets}}
		}
	}
	if len(groups) > chainMaxGroups {
		return nil, fmt.Errorf("每份配置最多可添加 32 组前置")
	}
	groups = append([]proxyChainGroup(nil), groups...)
	seen := map[string]bool{}
	total := 0
	for i := range groups {
		g := &groups[i]
		g.ID = strings.ToLower(g.ID)
		if !chainGroupIDPattern.MatchString(g.ID) || seen[g.ID] {
			return nil, fmt.Errorf("分组标识无效或重复，请重新创建分组")
		}
		seen[g.ID] = true
		if strings.TrimSpace(g.Name) == "" {
			g.Name = fmt.Sprintf("分组 %d", i+1)
		}
		total += len(g.Targets)
		if total > chainMaxTargets {
			return nil, fmt.Errorf("全部分组最多可勾选 4096 个后置节点")
		}
		if len(g.YAML) > chainMaxYAMLBytes {
			return nil, chainGroupFailure(*g, "单节点 YAML 不能超过 64 KB")
		}
	}
	return groups, nil
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
	case []map[string]any:
		copy := make([]map[string]any, len(v))
		for index, child := range v {
			copy[index] = chainCopy(child)
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
		result := map[string]any{"error": err.Error()}
		var groupError *chainGroupError
		if errors.As(err, &groupError) {
			result["groupID"] = groupError.GroupID
			if groupError.OtherGroupID != "" {
				result["conflictingGroupID"] = groupError.OtherGroupID
			}
		}
		return marshalJSON(result)
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

// Prepare all groups against the original configuration. Commit the derived
// map only when every provider expression and dependency check has succeeded.
func applyProxyChain(m map[string]any, settings proxyChainSettings) ([]string, error) {
	groups, err := settings.normalizedGroups()
	if err != nil {
		return nil, err
	}
	if !settings.Enabled {
		return []string{}, nil
	}
	active := []proxyChainGroup{}
	for _, g := range groups {
		if g.Enabled && len(g.Targets) > 0 {
			active = append(active, g)
		}
	}
	if len(active) == 0 {
		return []string{}, nil
	}
	candidate := chainCopy(m)
	warnings, err := chainApplyGroups(candidate, active)
	if err != nil {
		return nil, err
	}
	for key := range m {
		delete(m, key)
	}
	for key, value := range candidate {
		m[key] = value
	}
	return warnings, nil
}

func chainApplyGroups(m map[string]any, groups []proxyChainGroup) ([]string, error) {
	warnings := []string{}
	owners := map[chainReference]proxyChainGroup{}
	required := map[chainReference]proxyChainGroup{}
	customs := map[string]map[string]any{}
	targets := []chainReference{}
	for _, g := range groups {
		if g.Mode != "existing" && g.Mode != "custom" {
			return nil, chainGroupFailure(g, "请选择前置节点来源")
		}
		if g.Mode == "existing" {
			if g.Upstream == nil || g.Upstream.Name == "" {
				return nil, chainGroupFailure(g, "请选择前置节点")
			}
			if chainReservedName(g.Upstream.Name) {
				return nil, chainGroupFailure(g, "前置必须是真实代理节点")
			}
			required[*g.Upstream] = g
		} else {
			custom, err := chainCustomProxy(g.YAML)
			if err != nil {
				return nil, chainGroupFailure(g, err.Error())
			}
			custom["name"] = g.customName()
			customs[g.ID] = custom
		}
		for _, ref := range g.Targets {
			if ref.Name == "" || chainReservedName(ref.Name) {
				return nil, chainGroupFailure(g, "后置必须是真实代理节点")
			}
			if previous, exists := owners[ref]; exists {
				if previous.ID != g.ID {
					return nil, chainGroupFailure(g, "后置节点 "+ref.Name+" 已用于其他启用组", previous)
				}
				continue
			}
			owners[ref] = g
			required[ref] = g
			targets = append(targets, ref)
		}
	}
	for _, g := range groups {
		if g.Mode == "existing" {
			if owner, exists := owners[*g.Upstream]; exists {
				return nil, chainGroupFailure(g, "前置节点不能同时作为启用组的后置节点", owner)
			}
		}
	}
	for _, section := range []string{"proxies", "proxy-groups"} {
		for _, item := range chainMaps(m[section]) {
			if chainInternalName(chainString(item, "name")) {
				return nil, fmt.Errorf("配置节点名与 App 内部前置名称冲突")
			}
		}
	}
	providers, _ := m["proxy-providers"].(map[string]any)
	for source := range providers {
		if chainInternalName(source) {
			return nil, fmt.Errorf("Provider 名称与 App 内部前置名称冲突")
		}
	}
	nodes, mappings, notices, err := chainInventory(m)
	if err != nil {
		return nil, err
	}
	warnings = append(warnings, notices...)
	for _, node := range nodes {
		if g, exists := required[node.chainReference]; exists && node.Issue != "" {
			return nil, chainGroupFailure(g, "节点重名，无法精确应用前置："+node.Name)
		}
	}
	protected := chainProtectedNames(m, targets)
	for _, g := range groups {
		protected[g.upstreamName()] = true
		protected[g.customName()] = true
	}
	for ref, mapping := range mappings {
		dialer := chainString(mapping, "dialer-proxy")
		if g, selected := owners[ref]; selected && dialer != "" {
			return nil, chainGroupFailure(g, "节点 "+ref.Name+" 已有代理链，请先取消勾选")
		}
		if protected[dialer] || chainInternalName(dialer) {
			return nil, fmt.Errorf("节点 %s 的已有代理链引用了勾选范围，无法保持未勾选节点原链路", ref.Name)
		}
	}
	for _, mapping := range chainMaps(m["proxies"]) {
		ref := chainReference{"", chainString(mapping, "name")}
		if g, exists := required[ref]; exists && !chainRealType(chainString(mapping, "type")) {
			return nil, chainGroupFailure(g, "引用项已不是真实代理节点，请重新选择")
		}
		dialer := chainString(mapping, "dialer-proxy")
		if protected[dialer] || chainInternalName(dialer) {
			return nil, fmt.Errorf("已有代理链引用了勾选节点，无法保持未勾选节点原链路")
		}
	}
	for _, ref := range targets {
		if mappings[ref] == nil {
			warnings = append(warnings, owners[ref].Name+"：勾选节点当前不存在或尚未缓存："+ref.Name)
		}
	}

	// One provider guard covers the union of all groups before any App
	// assignment. Evaluating another group's assignment as an original dialer
	// would incorrectly reject independent groups sharing a provider.
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
		selected := []chainReference{}
		requiredRefs := []chainReference{}
		for _, ref := range targets {
			if ref.Source == source {
				selected = append(selected, ref)
			}
		}
		for ref := range required {
			if ref.Source == source {
				requiredRefs = append(requiredRefs, ref)
			}
		}
		sort.Slice(requiredRefs, func(i, j int) bool { return requiredRefs[i].Name < requiredRefs[j].Name })
		condition := chainNameCondition(selected)
		guard := "(" + condition + " == false or (.dialer-proxy // \"\") == \"\")"
		if len(requiredRefs) > 0 {
			realType := []string{}
			for _, typ := range chainNonProxyTypes {
				realType = append(realType, "(.type // \"\" | downcase) != "+chainLiteral(typ))
			}
			guard += " and (" + chainNameCondition(requiredRefs) + " == false or (" + strings.Join(realType, " and ") + "))"
		}
		// Reserve the full helper namespace, including old snapshot names.
		for _, prefix := range []string{chainUpstreamPrefix, chainCustomPrefix} {
			guard += " and (.name | test(" + chainLiteral("^"+regexp.QuoteMeta(prefix)) + ")) == false"
			guard += " and ((.dialer-proxy // \"\") | test(" + chainLiteral("^"+regexp.QuoteMeta(prefix)) + ")) == false"
		}
		for _, name := range unsafe {
			guard += " and (.dialer-proxy // \"\") != " + chainLiteral(name)
		}
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
				if g, exists := required[chainReference{source, chainString(entry, "name")}]; exists {
					return nil, chainGroupFailure(g, "Provider "+source+" 的节点类型、名称或已有代理链与前置设置冲突")
				}
				return nil, fmt.Errorf("Provider %s 的节点与前置设置冲突，请检查节点类型、名称及已有代理链", source)
			}
		}
		expressions := append(stringList(override["override-expr"]), guardSource)
		for _, g := range groups {
			refs := []chainReference{}
			for _, ref := range g.Targets {
				if ref.Source == source {
					refs = append(refs, ref)
				}
			}
			if len(refs) > 0 {
				expressions = append(expressions, "(select("+chainNameCondition(refs)+") | .dialer-proxy) = "+chainLiteral(g.upstreamName()))
			}
		}
		for _, expression := range expressions {
			if _, err := provider.NewOverrideExpr(expression); err != nil {
				return nil, fmt.Errorf("前置条件生成失败")
			}
		}
		override["override-expr"] = stringsToAny(expressions)
		def["override"] = override
	}
	chainPreserveGlobalGroup(m)
	customNames := []string{}
	for _, g := range groups {
		if g.Mode == "custom" {
			customNames = append(customNames, g.customName())
		}
	}
	chainExcludeInternalProxiesFromGroups(m, customNames)
	proxyItems := []any{}
	for _, proxy := range chainMaps(m["proxies"]) {
		if g, selected := owners[chainReference{"", chainString(proxy, "name")}]; selected {
			proxy["dialer-proxy"] = g.upstreamName()
		}
		proxyItems = append(proxyItems, proxy)
	}
	groupItems := []any{}
	for _, group := range chainMaps(m["proxy-groups"]) {
		groupItems = append(groupItems, group)
	}
	for _, g := range groups {
		upstream := map[string]any{"name": g.upstreamName(), "type": "select", "hidden": true, "empty-fallback": "REJECT"}
		if g.Mode == "custom" {
			proxyItems = append(proxyItems, customs[g.ID])
			upstream["proxies"] = []any{g.customName()}
		} else if ref := *g.Upstream; ref.Source == "" {
			if mappings[ref] == nil {
				upstream["proxies"] = []any{"REJECT"}
				warnings = append(warnings, g.Name+"：前置节点不存在，勾选节点将拒绝连接")
			} else {
				upstream["proxies"] = []any{ref.Name}
			}
		} else if _, exists := providers[ref.Source]; exists {
			upstream["use"] = []any{ref.Source}
			upstream["filter"] = `\A` + strings.ReplaceAll(regexp.QuoteMeta(ref.Name), "`", `\x60`) + `\z`
		} else {
			upstream["proxies"] = []any{"REJECT"}
			warnings = append(warnings, g.Name+"：前置来源不存在，勾选节点将拒绝连接")
		}
		groupItems = append(groupItems, upstream)
	}
	m["proxies"] = proxyItems
	m["proxy-groups"] = groupItems
	return warnings, nil
}

func chainInternalName(name string) bool {
	return strings.HasPrefix(name, chainUpstreamPrefix) || strings.HasPrefix(name, chainCustomPrefix)
}

func chainReservedName(name string) bool {
	if chainInternalName(name) {
		return true
	}
	switch name {
	case "DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE", "GLOBAL", chainUpstreamName, chainCustomName:
		return true
	}
	return false
}

func chainExcludeInternalProxiesFromGroups(m map[string]any, names []string) {
	if len(names) == 0 {
		return
	}
	patterns := []string{}
	for _, name := range names {
		patterns = append(patterns, `\A`+regexp.QuoteMeta(name)+`\z`)
	}
	pattern := strings.Join(patterns, "`")
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
