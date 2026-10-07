package mihomo

import (
	"context"
	"sync"
)

var runtimeControlMu sync.Mutex
var runtimeControlID uint64
var runtimeControls = make(map[uint64]context.CancelFunc)

// Admission and config writes share this gate. Finish drops the read lock
// before taking the gate so a writer can cancel and await all network work.
func beginRuntimeControl() (context.Context, func()) {
	runtimeControlMu.Lock()
	configApplyMu.RLock()
	ctx, cancel := context.WithCancel(context.Background())
	runtimeControlID++
	id := runtimeControlID
	runtimeControls[id] = cancel
	if coreSessionClock == nil {
		cancel()
	}
	runtimeControlMu.Unlock()
	return ctx, func() {
		cancel()
		configApplyMu.RUnlock()
		runtimeControlMu.Lock()
		delete(runtimeControls, id)
		runtimeControlMu.Unlock()
	}
}
