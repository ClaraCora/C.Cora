package mihomo

import (
	"cora/mobilecore/internal/sessionclock"
	"encoding/json"
	"testing"

	"github.com/metacubex/mihomo/component/iosupdate"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type iosUpdateBlockTestTracker struct {
	C.Connection
	id       string
	metadata C.Metadata
	closed   bool
}

func (t *iosUpdateBlockTestTracker) ID() string { return t.id }
func (t *iosUpdateBlockTestTracker) Info() *statistic.TrackerInfo {
	return &statistic.TrackerInfo{Metadata: &t.metadata}
}
func (t *iosUpdateBlockTestTracker) Close() error { t.closed = true; return nil }

func TestIOSUpdateBlockHotConfigurationAndTargetedClose(t *testing.T) {
	Setup(t.TempDir())
	defer Stop()
	coreSessionClock = sessionclock.New()
	iosupdate.Begin(123, "default", false)
	target := &iosUpdateBlockTestTracker{id: "update-target", metadata: C.Metadata{Host: "MESU.APPLE.COM."}}
	sniffed := &iosUpdateBlockTestTracker{id: "update-sniffed", metadata: C.Metadata{Host: "elsewhere", SniffHost: "gdmf.apple.com"}}
	normal := &iosUpdateBlockTestTracker{id: "normal", metadata: C.Metadata{Host: "www.apple.com"}}
	for _, tracker := range []*iosUpdateBlockTestTracker{target, sniffed, normal} {
		statistic.DefaultManager.Join(tracker)
		defer statistic.DefaultManager.Leave(tracker)
	}
	var snapshot iosupdate.Snapshot
	if err := json.Unmarshal(ConfigureIOSUpdateBlockData(`{"id":"test-on","enabled":true}`), &snapshot); err != nil || !snapshot.Enabled || snapshot.ConfigurationID != "test-on" {
		t.Fatalf("configure failed: %+v %v", snapshot, err)
	}
	if !target.closed || !sniffed.closed || normal.closed {
		t.Fatal("toggle closed unrelated traffic or retained a recognized target")
	}
	if snapshot.Domains[0].ConnectionsRejected != 0 || snapshot.Domains[1].ConnectionsRejected != 0 {
		t.Fatal("closing old connections manufactured a new request")
	}
	iosupdate.RejectDNS("mesu.apple.com")
	_ = ConfigureIOSUpdateBlockData(`{"id":"test-off","enabled":false}`)
	if iosupdate.Status().Domains[1].DNSRefused != 1 {
		t.Fatal("hot disable reset session counts")
	}
	_ = ResetIOSUpdateBlockStatsData()
	if iosupdate.Status().Enabled || iosupdate.Status().Domains[1].DNSRefused != 0 {
		t.Fatal("stats reset altered policy")
	}
	Stop()
	if iosupdate.Status().Active || iosupdate.Status().Domains[1].DNSRefused != 0 {
		t.Fatal("stopped runtime retained state")
	}
}

func TestIOSUpdateBlockValidationAndLegacySettings(t *testing.T) {
	st := parseSettings(`{"ipv6":true}`)
	if st.IOSUpdateBlock.Enabled || !st.IOSUpdateBlock.valid() {
		t.Fatal("legacy settings did not default off")
	}
	for _, input := range []string{`{}`, `{"id":"bad/id","enabled":true}`, `{"id":"x","enabled":"yes"}`} {
		var response map[string]any
		_ = json.Unmarshal(ConfigureIOSUpdateBlockData(input), &response)
		if response["error"] == nil {
			t.Fatalf("accepted invalid configuration %s", input)
		}
	}
}

func TestIOSUpdateBlockStartupRollback(t *testing.T) {
	Setup(t.TempDir())
	defer Stop()
	err := StartWithConfig(-1, 1500, "invalid: [", `{"iosUpdateBlock":{"id":"rollback","enabled":true}}`)
	if err == nil || iosupdate.Status().Active || iosupdate.RejectDNS("mesu.apple.com") {
		t.Fatal("failed start left policy active")
	}
}
