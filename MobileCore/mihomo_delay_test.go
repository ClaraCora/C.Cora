package mihomo

import (
	"context"
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
