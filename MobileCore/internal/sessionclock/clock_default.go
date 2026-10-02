//go:build !darwin || !cgo

package sessionclock

import "time"

// Portable clock for non-Apple test hosts and cgo-free cross-compilation.
// Shipped iOS frameworks always use the Mach continuous clock instead.
var processClockOrigin = time.Now()

func continuousNow() time.Duration {
	return time.Since(processClockOrigin)
}
