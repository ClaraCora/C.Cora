package mihomo

import (
	"testing"

	"gopkg.in/yaml.v3"
)

func mergedMap(t *testing.T, input string) map[string]any {
	t.Helper()
	return mergedMapWithSettings(t, input, appSettings{Stack: "gvisor", LogLevel: "info"})
}

func mergedMapWithSettings(t *testing.T, input string, settings appSettings) map[string]any {
	t.Helper()
	out, err := mergeConfig(input, settings)
	if err != nil {
		t.Fatalf("mergeConfig: %v", err)
	}
	var m map[string]any
	if err := yaml.Unmarshal(out, &m); err != nil {
		t.Fatalf("unmarshal merged config: %v", err)
	}
	return m
}

func TestParseSettingsGeoNegationDefaultAndOverride(t *testing.T) {
	if got := parseSettings("").IgnoreGeoNegation; !got {
		t.Error("IgnoreGeoNegation default = false, want true")
	}
	if got := parseSettings(`{"ignoreGeoNegation":false}`).IgnoreGeoNegation; got {
		t.Error("IgnoreGeoNegation override = true, want false")
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
  cache-max-size: 4096
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

	m = mergedMap(t, "mode: global\n")
	if got := m["mode"]; got != "global" {
		t.Errorf("mode = %v, want global", got)
	}
}

func TestMergeConfigKeepsIOSConstraints(t *testing.T) {
	m := mergedMap(t, "geo-auto-update: true\nmixed-port: 7890\n")
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
	if _, exists := m["mixed-port"]; exists {
		t.Error("mixed-port should be absent when the App setting is zero")
	}
}
