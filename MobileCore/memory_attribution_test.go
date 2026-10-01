package mihomo

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"sync/atomic"
	"testing"
	"time"

	pool "github.com/metacubex/mihomo/common/pool"
	buf "github.com/metacubex/sing/common/buf"
)

func TestForceGCTrimsIdlePoolsAndSharesCooldown(t *testing.T) {
	forceGCMu.Lock()
	previousAt := forceGCLastAt
	forceGCLastAt = time.Time{}
	forceGCMu.Unlock()
	t.Cleanup(func() { forceGCMu.Lock(); forceGCLastAt = previousAt; forceGCMu.Unlock() })
	trimIdleBufferPools()
	pool.DefaultAllocator.Put(make([]byte, 65552))
	buf.DefaultAllocator.Put(make([]byte, 65552))
	beforeSuppressed := atomic.LoadUint64(&forceGCSuppressed)
	oldPercent, oldLimit := debug.SetGCPercent(-1), debug.SetMemoryLimit(-1)
	debug.SetGCPercent(oldPercent)
	var before runtime.MemStats
	runtime.ReadMemStats(&before)
	ForceGC()
	if atomic.LoadUint64(&lastBufferPoolTrimBytes) != 2*65552 {
		t.Fatal("idle pools not trimmed before GC")
	}
	pool.DefaultAllocator.Put(make([]byte, 65552))
	ForceGC()
	var after runtime.MemStats
	runtime.ReadMemStats(&after)
	if after.NumForcedGC != before.NumForcedGC+1 || atomic.LoadUint64(&forceGCSuppressed) != beforeSuppressed+1 {
		t.Fatal("cooldown did not suppress repeated GC")
	}
	if pool.GetOversizePoolStats().Buffers != 1 {
		t.Fatal("cooldown repeatedly drained newly returned buffer")
	}
	if current := debug.SetGCPercent(oldPercent); current != oldPercent {
		t.Fatal("GC profile not restored")
	}
	if current := debug.SetMemoryLimit(oldLimit); current != oldLimit {
		t.Fatal("memory limit not restored")
	}
	trimIdleBufferPools()
}

func TestDiagnosticFilesAndOptionalFields(t *testing.T) {
	directory := t.TempDir()
	file := filepath.Join(directory, "geo.dat")
	if err := os.WriteFile(file, []byte("123456789"), 0600); err != nil {
		t.Fatal(err)
	}
	if size := diagnosticFileSize(file); size == nil || *size != 9 {
		t.Fatal("file size missing")
	}
	if diagnosticFileSize(directory) != nil || diagnosticFileSize(file+"missing") != nil {
		t.Fatal("unmeasured asset reported as zero")
	}
	data, err := json.Marshal(memoryAttribution{})
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"tunRXQueuedPackets", "fakeIP4", "geoIPFileBytes"} {
		if _, exists := fields[key]; exists {
			t.Fatalf("unmeasured optional field %s present", key)
		}
	}
}
