package mihomo

import (
	"testing"

	"gopkg.in/yaml.v3"
)

func mergedMap(t *testing.T, input string) map[string]any {
	t.Helper()
	out, err := mergeConfig(input, appSettings{Stack: "gvisor", LogLevel: "info"})
	if err != nil {
		t.Fatalf("mergeConfig: %v", err)
	}
	var m map[string]any
	if err := yaml.Unmarshal(out, &m); err != nil {
		t.Fatalf("unmarshal merged config: %v", err)
	}
	return m
}

func nestedMap(t *testing.T, m map[string]any, key string) map[string]any {
	t.Helper()
	v, ok := m[key].(map[string]any)
	if !ok {
		t.Fatalf("%s is %T, want map[string]any", key, m[key])
	}
	return v
}

func TestMergeConfigLowMemoryOverrides(t *testing.T) {
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

	for _, key := range []string{"external-ui", "external-ui-url", "external-ui-name"} {
		if _, exists := m[key]; exists {
			t.Errorf("%s was not removed", key)
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
