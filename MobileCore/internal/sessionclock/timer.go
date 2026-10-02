// Package sessionclock measures a tunnel session independently of wall-clock
// changes. Apple builds use a continuous clock that includes device sleep.
package sessionclock

import "time"

// Timer has an immutable start point; polling it never restarts the session.
type Timer struct {
	startedAt time.Duration
	now       func() time.Duration
}

// New starts a timer. Call it only after a new tunnel has started successfully.
func New() *Timer {
	return newTimer(continuousNow)
}

func newTimer(now func() time.Duration) *Timer {
	return &Timer{startedAt: now(), now: now}
}

// Seconds includes device sleep on iOS. A missing session reports zero.
func (t *Timer) Seconds() int64 {
	if t == nil {
		return 0
	}
	elapsed := t.now() - t.startedAt
	if elapsed < 0 {
		return 0
	}
	return int64(elapsed / time.Second)
}
