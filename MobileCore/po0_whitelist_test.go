package mihomo

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	http "github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
)

func po0TestConfig(id, tokens string, enabled bool) string {
	data, _ := json.Marshal(po0Configuration{ID: id, Tokens: tokens, Enabled: enabled, IntervalMinutes: 5})
	return string(data)
}

func TestPO0ConfigurationValidation(t *testing.T) {
	cfg, tokens, err := parsePO0Configuration(po0TestConfig("test", "pgnfw_one@0；pgnfw_two\npgnfw_three", true))
	if err != nil || !cfg.Enabled || len(tokens) != 3 || tokens[0].slot == nil || *tokens[0].slot != 0 {
		t.Fatalf("valid multi-token config rejected: %v", err)
	}
	for _, value := range []string{"", "wrong", "pgnfw_x@-1", "pgnfw_x@abc", "pgnfw_x@00", "pgnfw_x@65536",
		"pgnfw_x@0@1", "pgnfw_x,pgnfw_x@1", strings.Repeat("pgnfw_x,", 9), "pgnfw_x/path"} {
		if _, _, err := parsePO0Configuration(po0TestConfig("test", value, true)); err == nil {
			t.Errorf("invalid config accepted: %q", value)
		}
	}
	if _, _, err := parsePO0Configuration(po0TestConfig("off", "", false)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := parsePO0Configuration(`{"id":"test","intervalMinutes":0}`); err == nil {
		t.Fatal("unbounded frequency")
	}
}

func TestPO0WhitelistFormatsAndNetworks(t *testing.T) {
	for _, entries := range []string{
		`["1.2.3.0/24","2.3.4.5"]`,
		`[{"ip":"1.2.3.0/24","slot":0},{"ip":"2.3.4.5","slot":null}]`,
	} {
		result := decodePO0Response(200, []byte(`{"enabled":true,"currentIp":"1.2.3.99","limit":5,"whitelist":`+entries+`}`))
		if result.Error != "" || !result.Applied || len(result.Whitelist) != 2 {
			t.Fatalf("unexpected result: %+v", result)
		}
	}
	for _, tc := range []struct {
		a, b  string
		match bool
	}{
		{"1.2.3.1", "1.2.3.2", false}, {"1.2.3.1", "1.2.3.1", true},
		{"1.2.3.0/24", "1.2.3.254", true}, {"1.2.3.10", "1.2.3.0/24", true},
		{"1.2.3.0/24", "1.2.4.0/24", false}, {"999.2.3.1", "999.2.3.0/24", false},
		{"1.2.3.0/16", "1.2.3.4", false},
	} {
		if samePO0Network(tc.a, tc.b) != tc.match {
			t.Errorf("network match %s %s", tc.a, tc.b)
		}
	}
	for _, body := range []string{`{}`, `{"error":"secret"}`, `null`, `not json`,
		`{"enabled":true,"currentIp":"1.2.3.4","whitelist":["invalid"]}`} {
		if decodePO0Response(200, []byte(body)).Error == "" {
			t.Errorf("malformed response accepted: %s", body)
		}
	}
	result := decodePO0Response(200, []byte(`{"enabled":false,"currentIp":"1.2.3.4","limit":1,"whitelist":["1.2.3.4"]}`))
	if result.Applied || result.Enabled || result.Error != "" {
		t.Fatal("disabled firewall treated as active")
	}
}

func TestPO0HTTPRetriesAndLimits(t *testing.T) {
	for _, tc := range []struct {
		name     string
		status   int
		body     string
		attempts int
		applied  bool
	}{
		{"success", 200, `{"enabled":true,"currentIp":"1.2.3.4","whitelist":["1.2.3.0/24"],"limit":2}`, 1, true},
		{"conflict", 403, `{"error":"pgnfw_private"}`, 1, false},
		{"invalid-token", 400, `{"error":"pgnfw_private"}`, 1, false},
		{"transient-400", 400, `Error`, 3, false},
		{"server-error", 503, `Error`, 3, false},
		{"too-large", 200, strings.Repeat("x", po0MaximumResponseBytes+1), 1, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var attempts atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				attempts.Add(1)
				if r.Method != "POST" || r.URL.Path != "/pgnfw_private/add" || r.URL.Query().Get("slot") != "0" {
					t.Errorf("wrong method/path/slot")
				}
				w.WriteHeader(tc.status)
				fmt.Fprint(w, tc.body)
			}))
			defer server.Close()
			slot := 0
			result := requestPO0Whitelist(context.Background(), newPO0HTTPClient(http.DefaultTransport),
				server.URL+"/", po0Token{value: "pgnfw_private", slot: &slot}, time.Millisecond)
			if int(attempts.Load()) != tc.attempts || result.Applied != tc.applied {
				t.Fatalf("attempts=%d, result=%+v", attempts.Load(), result)
			}
			encoded, _ := json.Marshal(result)
			if strings.Contains(string(encoded), "pgnfw_") {
				t.Fatal("credential exposed")
			}
		})
	}
}

func TestPO0NeverFollowsRedirects(t *testing.T) {
	var reached atomic.Int32
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { reached.Add(1) }))
	defer destination.Close()
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, destination.URL+r.URL.Path, http.StatusTemporaryRedirect)
	}))
	defer source.Close()
	result := requestPO0Whitelist(context.Background(), newPO0HTTPClient(http.DefaultTransport),
		source.URL+"/", po0Token{value: "pgnfw_private"}, time.Millisecond)
	if reached.Load() != 0 || result.Error == "" {
		t.Fatal("redirect leaked request")
	}
}

func po0Wait(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("timed out waiting for PO0 worker")
}

func TestPO0PeriodicChecksAndStop(t *testing.T) {
	var count atomic.Int32
	s := newPO0Service(func(ctx context.Context, token po0Token) po0Result {
		count.Add(1)
		return po0Result{Applied: true}
	})
	s.initialDelay, s.minimumGap, s.intervalUnit = time.Millisecond, 5*time.Millisecond, 5*time.Millisecond
	defer s.stop()
	if err := s.configure(po0TestConfig("on", "pgnfw_private", true)); err != nil {
		t.Fatal(err)
	}
	po0Wait(t, func() bool { return count.Load() >= 2 })
	s.stop()
	n := count.Load()
	s.request(true)
	time.Sleep(35 * time.Millisecond)
	if count.Load() != n || strings.Contains(s.snapshotJSON(), "pgnfw_") {
		t.Fatal("worker survived stop or token exposed")
	}
	if err := s.configure(po0TestConfig("off", "pgnfw_private", false)); err != nil {
		t.Fatal(err)
	}
	if s.run != nil {
		t.Fatal("disabled configuration spawned a worker")
	}
}

func TestPO0ReconfigurationCancelsAndSerializes(t *testing.T) {
	var active, maximum atomic.Int32
	entered := make(chan struct{}, 1)
	s := newPO0Service(func(ctx context.Context, token po0Token) po0Result {
		n := active.Add(1)
		defer active.Add(-1)
		if n > maximum.Load() {
			maximum.Store(n)
		}
		if token.value == "pgnfw_old" {
			entered <- struct{}{}
			<-ctx.Done()
		}
		return po0Result{CurrentIP: "1.2.3.4", Applied: true}
	})
	s.initialDelay = time.Millisecond
	defer s.stop()
	if err := s.configure(po0TestConfig("old", "pgnfw_old", true)); err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("old request did not start")
	}
	if err := s.configure(po0TestConfig("new", "pgnfw_new", true)); err != nil {
		t.Fatal(err)
	}
	po0Wait(t, func() bool {
		var state po0Snapshot
		json.Unmarshal([]byte(s.snapshotJSON()), &state)
		return state.ConfigurationID == "new" && len(state.Results) == 1
	})
	if maximum.Load() != 1 {
		t.Fatal("overlapping workers")
	}
}

func TestPO0NetworkChangeDuringRequestGetsOneFollowup(t *testing.T) {
	var count atomic.Int32
	entered, release := make(chan struct{}), make(chan struct{})
	s := newPO0Service(func(ctx context.Context, token po0Token) po0Result {
		if count.Add(1) == 1 {
			close(entered)
			select {
			case <-release:
			case <-ctx.Done():
			}
		}
		return po0Result{Applied: true}
	})
	s.initialDelay, s.minimumGap = time.Millisecond, 10*time.Millisecond
	defer s.stop()
	if err := s.configure(po0TestConfig("path", "pgnfw_x", true)); err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("request did not start")
	}
	for i := 0; i < 20; i++ {
		s.request(true)
	}
	close(release)
	po0Wait(t, func() bool { return count.Load() == 2 })
	time.Sleep(30 * time.Millisecond)
	if count.Load() != 2 {
		t.Fatal("network flaps created duplicate checks")
	}
}

func TestPO0ReadOnlyHTTPNeverAddsOrPins(t *testing.T) {
	for _, status := range []int{200, 503} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			var count atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				count.Add(1)
				if r.Method != http.MethodGet || r.URL.Path != "/pgnfw_private" || r.URL.RawQuery != "" {
					t.Errorf("read-only refresh attempted a write: %s %s", r.Method, r.URL.Path)
				}
				w.WriteHeader(status)
				fmt.Fprint(w, `{"enabled":true,"currentIp":"1.2.3.4","whitelist":["1.2.3.0/24"],"limit":5}`)
			}))
			defer server.Close()
			slot := 3
			result := requestPO0(context.Background(), newPO0HTTPClient(http.DefaultTransport),
				server.URL+"/", po0Token{value: "pgnfw_private", slot: &slot}, time.Millisecond, true)
			if status == 200 && (!result.Applied || count.Load() != 1) {
				t.Fatalf("query failed: %+v", result)
			}
			if status == 503 && (result.Error == "" || count.Load() != 3) {
				t.Fatal("GET retry behavior changed")
			}
		})
	}
}

func TestPO0ReadOnlyDoesNotConfigureOrReschedule(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		t.Run(fmt.Sprint(enabled), func(t *testing.T) {
			var writes, reads atomic.Int32
			s := newPO0Service(func(context.Context, po0Token) po0Result { writes.Add(1); return po0Result{} })
			s.lookup = func(context.Context, po0Token) po0Result { reads.Add(1); return po0Result{CurrentIP: "1.2.3.4"} }
			s.initialDelay = time.Hour
			defer s.stop()
			cfg := po0TestConfig("readonly", "pgnfw_x@0", enabled)
			if err := s.configure(cfg); err != nil {
				t.Fatal(err)
			}
			var before, after po0Snapshot
			json.Unmarshal([]byte(s.snapshotJSON()), &before)
			if err := s.refreshReadOnly(cfg); err != nil {
				t.Fatal(err)
			}
			po0Wait(t, func() bool {
				json.Unmarshal([]byte(s.snapshotJSON()), &after)
				return after.LastRefreshedAt > 0 && !after.Refreshing
			})
			if writes.Load() != 0 || reads.Load() != 1 || after.NextCheckAt != before.NextCheckAt ||
				after.Pending != before.Pending || after.LastCheckedAt != before.LastCheckedAt || after.Enabled != enabled ||
				len(after.Results) != 1 || !after.Results[0].ReadOnly {
				t.Fatalf("read changed automatic state: before=%+v, after=%+v", before, after)
			}
			if err := s.refreshReadOnly(po0TestConfig("stale", "pgnfw_x", enabled)); err == nil {
				t.Fatal("stale configuration accepted")
			}
			if reads.Load() != 1 || writes.Load() != 0 {
				t.Fatal("stale query scheduled network work")
			}
		})
	}
}

func TestPO0ReadAndAutomaticWriteShareOneBatch(t *testing.T) {
	var active, writes atomic.Int32
	var overlap atomic.Bool
	entered, release := make(chan struct{}), make(chan struct{})
	s := newPO0Service(func(context.Context, po0Token) po0Result {
		if active.Add(1) != 1 {
			overlap.Store(true)
		}
		defer active.Add(-1)
		writes.Add(1)
		return po0Result{}
	})
	s.lookup = func(ctx context.Context, _ po0Token) po0Result {
		if active.Add(1) != 1 {
			overlap.Store(true)
		}
		defer active.Add(-1)
		close(entered)
		select {
		case <-release:
		case <-ctx.Done():
		}
		return po0Result{}
	}
	s.initialDelay = 20 * time.Millisecond
	defer s.stop()
	cfg := po0TestConfig("serial", "pgnfw_x", true)
	if err := s.configure(cfg); err != nil {
		t.Fatal(err)
	}
	if err := s.refreshReadOnly(cfg); err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("read did not start")
	}
	po0Wait(t, func() bool { var st po0Snapshot; json.Unmarshal([]byte(s.snapshotJSON()), &st); return st.Checking })
	if writes.Load() != 0 {
		t.Fatal("write bypassed the shared gate")
	}
	close(release)
	po0Wait(t, func() bool { return writes.Load() == 1 })
	if overlap.Load() {
		t.Fatal("GET and POST ran concurrently")
	}
}

func TestPO0StopCancelsReadAndDropsStaleResults(t *testing.T) {
	entered := make(chan struct{})
	s := newPO0Service(func(context.Context, po0Token) po0Result { t.Error("unexpected POST"); return po0Result{} })
	s.lookup = func(ctx context.Context, _ po0Token) po0Result {
		close(entered)
		<-ctx.Done()
		return po0Result{Applied: true}
	}
	defer s.stop()
	cfg := po0TestConfig("cancel", "pgnfw_x", false)
	if err := s.configure(cfg); err != nil {
		t.Fatal(err)
	}
	if err := s.refreshReadOnly(cfg); err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("read did not start")
	}
	s.stop()
	var state po0Snapshot
	json.Unmarshal([]byte(s.snapshotJSON()), &state)
	if state.Refreshing || len(state.Results) != 0 || state.LastRefreshedAt != 0 {
		t.Fatal("read outlived VPN stop")
	}
}
