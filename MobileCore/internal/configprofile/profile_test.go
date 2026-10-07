package configprofile

import (
	"go.yaml.in/yaml/v3"
	"testing"
)

func TestOptionalProfilePreservesRoutingAndProxyHealth(t *testing.T) {
	source := []byte("find-process-mode: always\nproxy-providers:\n  airport:\n    interval: 3600\n    health-check: {enable: true, interval: 600}\nrule-providers:\n  keep: {type: http, interval: 7200}\n  manual: {type: http, interval: 3600}\nrules: [RULE-SET,keep,DIRECT]\n")
	out, err := Generate(source, []string{"keep"})
	if err != nil {
		t.Fatal(err)
	}
	var before, after map[string]any
	_ = yaml.Unmarshal(source, &before)
	_ = yaml.Unmarshal(out, &after)
	if after["find-process-mode"] != "off" {
		t.Fatal("process lookup unchanged")
	}
	providers := after["rule-providers"].(map[string]any)
	if providers["manual"].(map[string]any)["interval"] != 0 || providers["keep"].(map[string]any)["interval"] != 7200 {
		t.Fatal("provider intervals changed incorrectly")
	}
	// Marshal unchanged sections so ordering of Go map traversal cannot affect comparison.
	for _, key := range []string{"proxy-providers", "rules"} {
		a, _ := yaml.Marshal(before[key])
		b, _ := yaml.Marshal(after[key])
		if string(a) != string(b) {
			t.Fatalf("changed %s", key)
		}
	}
	if _, err := Generate(source, []string{"missing"}); err == nil {
		t.Fatal("unknown provider accepted")
	}
}
