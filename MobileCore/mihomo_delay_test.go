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
