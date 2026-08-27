package mihomo

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

type proxyDelayTimeoutError struct{}

func (proxyDelayTimeoutError) Error() string   { return "network timeout" }
func (proxyDelayTimeoutError) Timeout() bool   { return true }
func (proxyDelayTimeoutError) Temporary() bool { return false }

func TestProxyDelayTimedOut(t *testing.T) {
	expiredContext, cancel := context.WithDeadline(
		context.Background(), time.Now().Add(-time.Second))
	defer cancel()

	tests := []struct {
		name string
		ctx  context.Context
		err  error
		want bool
	}{
		{name: "expired context", ctx: expiredContext, err: errors.New("request failed"), want: true},
		{name: "deadline error", ctx: context.Background(), err: context.DeadlineExceeded, want: true},
		{name: "network timeout", ctx: context.Background(), err: proxyDelayTimeoutError{}, want: true},
		{name: "other error", ctx: context.Background(), err: errors.New("connection refused"), want: false},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := proxyDelayTimedOut(test.ctx, test.err); got != test.want {
				t.Fatalf("proxyDelayTimedOut() = %v, want %v", got, test.want)
			}
		})
	}
}

func TestProxyDelayErrorResponseEscapesJSON(t *testing.T) {
	testErr := errors.Join(
		errors.New(`Get "https://www.gstatic.com/generate_204": TFO probe failed`),
		errors.New("plain TCP probe failed\ncontext deadline exceeded"),
	)
	message := testErr.Error()
	response := proxyDelayErrorResponse(testErr)

	var decoded map[string]string
	if err := json.Unmarshal([]byte(response), &decoded); err != nil {
		t.Fatalf("proxyDelayErrorResponse() returned invalid JSON: %v\n%s", err, response)
	}
	if decoded["error"] != message {
		t.Fatalf("decoded error = %q, want %q", decoded["error"], message)
	}
}

func TestParseProxyDelayTargetsValidatesAndDeduplicates(t *testing.T) {
	targets, err := parseProxyDelayTargets(`[
		{"key":"node-a","name":"Tokyo","group":"Japan"},
		{"key":"node-a","name":"Ignored duplicate","group":"Other"},
		{"key":"node-b","name":"DIRECT","group":""}
	]`)
	if err != nil {
		t.Fatal(err)
	}
	if len(targets) != 2 {
		t.Fatalf("target count = %d, want 2", len(targets))
	}
	if targets[0].Name != "Tokyo" || targets[0].Group != "Japan" {
		t.Fatalf("first target = %#v", targets[0])
	}
	if targets[1].Key != "node-b" || targets[1].Name != "DIRECT" {
		t.Fatalf("second target = %#v", targets[1])
	}
}

func TestParseProxyDelayTargetsRejectsInvalidInput(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{name: "blank", raw: "  ", want: "测速目标为空"},
		{name: "null", raw: "null", want: "测速目标为空"},
		{name: "not array", raw: `{"key":"a"}`, want: "测速目标格式错误"},
		{name: "missing key", raw: `[{"name":"Tokyo"}]`, want: "缺少 key"},
		{name: "missing name", raw: `[{"key":"node-a"}]`, want: "缺少 name"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := parseProxyDelayTargets(test.raw)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want containing %q", err, test.want)
			}
		})
	}
}

func TestParseProxyDelayTargetsIsBounded(t *testing.T) {
	targets := make([]proxyDelayTarget, maxProxyDelayTargets+1)
	for index := range targets {
		targets[index] = proxyDelayTarget{
			Key:  fmt.Sprintf("key-%d", index),
			Name: fmt.Sprintf("node-%d", index),
		}
	}
	raw, err := json.Marshal(targets)
	if err != nil {
		t.Fatal(err)
	}
	_, err = parseProxyDelayTargets(string(raw))
	if err == nil || !strings.Contains(err.Error(), fmt.Sprint(maxProxyDelayTargets)) {
		t.Fatalf("error = %v, want target limit", err)
	}
}

func TestConfigWriteCancelsActiveProxyDelayBatch(t *testing.T) {
	session := beginProxyDelayBatch()
	finished := false
	defer func() {
		if !finished {
			finishProxyDelayBatch(session)
		}
	}()

	writerAcquired := make(chan struct{})
	writerDone := make(chan struct{})
	go func() {
		lockConfigApplyForWrite()
		close(writerAcquired)
		unlockConfigApplyForWrite()
		close(writerDone)
	}()

	select {
	case <-session.ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("configuration writer did not cancel the active batch")
	}
	select {
	case <-writerAcquired:
		t.Fatal("configuration writer acquired the lock before the batch released its read lock")
	default:
	}

	finishProxyDelayBatch(session)
	finished = true
	select {
	case <-writerDone:
	case <-time.After(time.Second):
		t.Fatal("configuration writer stayed blocked after batch cancellation cleanup")
	}
}

func TestProxyDelayWorkerCounts(t *testing.T) {
	previous := currentPhysicalInterface()
	defer storePhysicalInterface(previous)

	tests := []struct {
		name      string
		iface     string
		batchWant int
		groupWant int
	}{
		{name: "wifi", iface: "en0", batchWant: proxyDelayBatchWorkerLimit, groupWant: proxyDelayGroupWorkerLimit},
		{name: "cellular", iface: "pdp_ip0", batchWant: proxyDelayCellularBatchWorkerLimit, groupWant: proxyDelayCellularGroupWorkerLimit},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			storePhysicalInterface(test.iface)
			if got := proxyDelayWorkerCount(); got != test.batchWant {
				t.Fatalf("proxyDelayWorkerCount() = %d, want %d", got, test.batchWant)
			}
			if got := proxyGroupDelayWorkerCount(); got != test.groupWant {
				t.Fatalf("proxyGroupDelayWorkerCount() = %d, want %d", got, test.groupWant)
			}
		})
	}
}

func TestProxyDelayRunContextCapsDuration(t *testing.T) {
	tests := []struct {
		name      string
		targets   int
		timeoutMs int
		workers   int
		want      time.Duration
	}{
		{name: "small run", targets: 4, timeoutMs: 1000, workers: 2, want: 7 * time.Second},
		{name: "large run cap", targets: 256, timeoutMs: 5000, workers: 2, want: proxyDelayMaxRunDuration},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx, cancel := proxyDelayRunContext(context.Background(), test.targets, test.timeoutMs, test.workers)
			defer cancel()
			deadline, ok := ctx.Deadline()
			if !ok {
				t.Fatal("proxyDelayRunContext() did not set a deadline")
			}
			remaining := time.Until(deadline)
			if remaining < test.want-150*time.Millisecond || remaining > test.want+150*time.Millisecond {
				t.Fatalf("deadline remaining = %s, want about %s", remaining, test.want)
			}
		})
	}
}

func TestMarshalProxyDelayMapPartialPreservesResults(t *testing.T) {
	response := marshalProxyDelayMap(map[string]uint16{"node-a": 123, "node-b": 0}, true)
	var decoded map[string]any
	if err := json.Unmarshal([]byte(response), &decoded); err != nil {
		t.Fatalf("marshalProxyDelayMap() returned invalid JSON: %v", err)
	}
	if partial, ok := decoded["_partial"].(bool); !ok || !partial {
		t.Fatalf("_partial = %#v, want true", decoded["_partial"])
	}
	if delay, ok := decoded["node-a"].(float64); !ok || delay != 123 {
		t.Fatalf("node-a delay = %#v, want 123", decoded["node-a"])
	}
	if delay, ok := decoded["node-b"].(float64); !ok || delay != 0 {
		t.Fatalf("node-b delay = %#v, want 0", decoded["node-b"])
	}
}

func TestBeginProxyDelayBatchWaitsForPreviousSession(t *testing.T) {
	first := beginProxyDelayBatch()
	secondReady := make(chan *proxyDelayBatchSession, 1)
	go func() {
		secondReady <- beginProxyDelayBatch()
	}()

	select {
	case second := <-secondReady:
		finishProxyDelayBatch(second)
		t.Fatal("new delay session started before previous session finished")
	case <-time.After(50 * time.Millisecond):
	}

	finishProxyDelayBatch(first)
	select {
	case second := <-secondReady:
		finishProxyDelayBatch(second)
	case <-time.After(time.Second):
		t.Fatal("new delay session did not start after previous session finished")
	}
}
