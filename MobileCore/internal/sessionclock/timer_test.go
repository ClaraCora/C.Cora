package sessionclock

import (
	"sync/atomic"
	"testing"
	"time"
)

func TestTimerIncludesOvernightSleep(t *testing.T) {
	clock := 10 * time.Hour
	timer := newTimer(func() time.Duration { return clock })

	// No reads or background task run during this simulated night. A continuous
	// clock includes the 4h17m asleep as well as the 1h54m awake.
	clock += 1*time.Hour + 54*time.Minute
	clock += 4*time.Hour + 17*time.Minute
	if got, want := timer.Seconds(), int64((6*time.Hour+11*time.Minute)/time.Second); got != want {
		t.Fatalf("overnight uptime = %d, want %d including sleep", got, want)
	}

	// Further reads (e.g. reopening the app) retain the original session start.
	clock += 3 * time.Second
	if got := timer.Seconds(); got != 6*3600+11*60+3 {
		t.Fatalf("uptime after reopening = %d", got)
	}
}

func TestTimerOnlyRestartsForNewSession(t *testing.T) {
	clock := 2 * time.Hour
	now := func() time.Duration { return clock }
	timer := newTimer(now)
	clock += 48 * time.Hour
	if got := timer.Seconds(); got != 48*3600 {
		t.Fatalf("long-running session uptime = %d", got)
	}
	for range 5 {
		if got := timer.Seconds(); got != 48*3600 {
			t.Fatalf("polling reset uptime to %d", got)
		}
	}

	timer = newTimer(now)
	if got := timer.Seconds(); got != 0 {
		t.Fatalf("new session uptime = %d, want 0", got)
	}
	clock += time.Second + 500*time.Millisecond
	if got := timer.Seconds(); got != 1 {
		t.Fatalf("new session uptime = %d, want 1", got)
	}

	timer = nil
	if got := timer.Seconds(); got != 0 {
		t.Fatalf("stopped session uptime = %d, want 0", got)
	}
}

func TestTimerConcurrentReads(t *testing.T) {
	var clock atomic.Int64
	clock.Store(int64(time.Hour))
	timer := newTimer(func() time.Duration { return time.Duration(clock.Load()) })
	clock.Add(int64(6 * time.Hour))
	for range 16 {
		t.Run("reader", func(t *testing.T) {
			t.Parallel()
			if got := timer.Seconds(); got != 6*3600 {
				t.Fatalf("concurrent uptime = %d", got)
			}
		})
	}
}

func TestNativeClockAdvances(t *testing.T) {
	start := continuousNow()
	time.Sleep(10 * time.Millisecond)
	if elapsed := continuousNow() - start; elapsed <= 0 {
		t.Fatalf("native clock failed to advance: %v", elapsed)
	}
}
