package mihomo

import (
	"context"
	"encoding/json"
	"errors"
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
