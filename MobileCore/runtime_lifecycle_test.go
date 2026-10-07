package mihomo

import (
	"context"
	"cora/mobilecore/internal/sessionclock"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/ntp/ntp"
	"github.com/metacubex/mihomo/tunnel"
)

func TestRuntimeLogHomeRebind(t *testing.T) {
	first, second := t.TempDir(), t.TempDir()
	Setup(first)
	defer Stop()
	log.SetLevel(log.ERROR)
	appendRunLog("first-home-only")
	var readers sync.WaitGroup
	readers.Add(1)
	done := make(chan struct{})
	go func() {
		defer readers.Done()
		for {
			select {
			case <-done:
				return
			default:
				_ = RunLogChunkData(-1, 0)
			}
		}
	}()
	for i := 0; i < 20; i++ {
		Setup(second)
		appendRunLog("second-home-only")
		Setup(first)
	}
	close(done)
	readers.Wait()
	Stop()
	for _, home := range []string{first, second} {
		if _, err := os.Stat(filepath.Join(home, "run.log")); err != nil {
			t.Fatal("rebound log missing:", err)
		}
	}
}

func TestRuntimeStopApply100Cycles(t *testing.T) {
	Setup(t.TempDir())
	defer Stop()
	log.SetLevel(log.ERROR)
	baseline := runtime.NumGoroutine()
	for i := 0; i < 100; i++ {
		lockConfigApplyForWrite()
		dnsConfig := "dns: {enable: false}\n"
		if i%2 == 0 {
			dnsConfig = "dns:\n  enable: true\n  enhanced-mode: fake-ip\n  nameserver: [udp://127.0.0.1:9]\n  fake-ip-filter: []\n"
		}
		cfg, err := config.Parse([]byte("mode: direct\nlog-level: error\n" + dnsConfig + "profile:\n  store-selected: false\n  store-fake-ip: false\nrules:\n  - MATCH,DIRECT\n"))
		if err != nil {
			unlockConfigApplyForWrite()
			t.Fatal(err)
		}
		startLogCapture()
		executor.ApplyConfig(cfg, true)
		coreSessionClock = sessionclock.New()
		cacheScriptTargetIP("session.example", "203.0.113.7")
		stopRuntimeLocked()
		unlockConfigApplyForWrite()
		if len(tunnel.Providers()) != 0 || len(tunnel.RuleProviders()) != 0 || len(tunnel.Proxies()) != 0 || ntp.RuntimeActive() || logCaptureIsActive() {
			t.Fatal("session objects retained")
		}
		if len(scriptTargetIPCache) != 0 || coreSessionClock != nil {
			t.Fatal("session cache/clock retained")
		}
		if resolver.CurrentDNSRuntime().DefaultResolver != nil || resolver.DefaultHostMapper != nil {
			t.Fatal("DNS runtime retained")
		}
		var traffic map[string]any
		if err := json.Unmarshal(TrafficNowData(), &traffic); err != nil || traffic["uptime"] != float64(0) {
			t.Fatal("traffic unavailable after stop")
		}
	}
	deadline := time.Now().Add(time.Second)
	for runtime.NumGoroutine() > baseline+5 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if n := runtime.NumGoroutine(); n > baseline+5 {
		t.Fatalf("goroutines increased: before=%d after=%d", baseline, n)
	}
}
func TestRuntimeControlCancelledBeforeStop(t *testing.T) {
	Setup(t.TempDir())
	defer Stop()
	lockConfigApplyForWrite()
	coreSessionClock = sessionclock.New()
	unlockConfigApplyForWrite()
	ctx, finish := beginRuntimeControl()
	done := make(chan struct{})
	go func() { Stop(); close(done) }()
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("Stop did not cancel control task")
	}
	finish()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Stop blocked after cancellation")
	}
	ctx, finish = beginRuntimeControl()
	defer finish()
	if ctx.Err() != context.Canceled {
		t.Fatal("control admission revived stopped runtime")
	}
}
func TestRuntimeStartRollback(t *testing.T) {
	Setup(t.TempDir())
	defer Stop()
	if err := StartWithConfig(-1, 1420, "proxies: [invalid", ""); err == nil {
		t.Fatal("invalid config started")
	}
	if logCaptureIsActive() || coreSessionClock != nil || ntp.RuntimeActive() {
		t.Fatal("failed start retained runtime")
	}
	if _, err := os.Stat(homeDir + "/run.log"); err != nil {
		t.Fatal("rollback log missing")
	}
}

func TestRuntimeProviderInitializationRollback(t *testing.T) {
	home := t.TempDir()
	Setup(home)
	defer Stop()
	configYAML := "mode: direct\ndns: {enable: false}\nprofile: {store-selected: false, store-fake-ip: false}\nrule-providers:\n  missing:\n    type: file\n    behavior: domain\n    path: missing-rules.yaml\nrules:\n  - RULE-SET,missing,DIRECT\n  - MATCH,DIRECT\n"
	if err := StartWithConfig(-1, 1420, configYAML, ""); err == nil {
		t.Fatal("missing provider file did not fail startup")
	}
	if len(tunnel.RuleProviders()) != 0 || coreSessionClock != nil || logCaptureIsActive() {
		t.Fatal("provider initialization failure retained partial runtime")
	}
	if _, err := os.Stat(filepath.Join(home, "run.log")); err != nil {
		t.Fatal("rollback log missing")
	}
}

type blockingRuntimeProvider struct {
	P.RuleProvider
	ctx     context.Context
	cancel  context.CancelFunc
	started chan struct{}
	done    chan struct{}
	closed  atomic.Int32
}

func (p *blockingRuntimeProvider) VehicleType() P.VehicleType { return P.HTTP }
func (p *blockingRuntimeProvider) Update() error {
	close(p.started)
	defer close(p.done)
	<-p.ctx.Done()
	return p.ctx.Err()
}
func (p *blockingRuntimeProvider) CancelRuntime() { p.cancel() }
func (p *blockingRuntimeProvider) WaitRuntimeIdle(deadline time.Time) bool {
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	select {
	case <-p.done:
		return true
	case <-timer.C:
		return false
	}
}
func (p *blockingRuntimeProvider) Close() error {
	p.cancel()
	p.closed.Add(1)
	return nil
}

func TestRuntimeStopCancelsProviderOutsideConfigLock(t *testing.T) {
	Setup(t.TempDir())
	defer Stop()
	ctx, cancel := context.WithCancel(context.Background())
	provider := &blockingRuntimeProvider{ctx: ctx, cancel: cancel,
		started: make(chan struct{}), done: make(chan struct{})}
	lockConfigApplyForWrite()
	coreSessionClock = sessionclock.New()
	tunnel.UpdateRules(nil, nil, map[string]P.RuleProvider{"blocked": provider})
	unlockConfigApplyForWrite()
	response := make(chan []byte, 1)
	go func() { response <- UpdateRuleProviderData("blocked") }()
	select {
	case <-provider.started:
	case <-time.After(time.Second):
		t.Fatal("provider refresh did not start")
	}
	done := make(chan struct{})
	go func() { Stop(); close(done) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		cancel()
		t.Fatal("provider refresh held the config lock during Stop")
	}
	var result struct {
		OK       bool              `json:"ok"`
		Updated  []string          `json:"updated"`
		Failures map[string]string `json:"failures"`
	}
	if err := json.Unmarshal(<-response, &result); err != nil || result.OK || len(result.Updated) != 0 {
		t.Fatal("old provider refresh reported success")
	}
	if provider.closed.Load() != 1 || atomic.LoadInt32(&activeProviderRefresh) != 0 {
		t.Fatal("provider update/close did not drain")
	}
}
