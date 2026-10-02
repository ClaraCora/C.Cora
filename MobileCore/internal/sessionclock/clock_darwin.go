//go:build darwin && cgo

package sessionclock

/*
#include <mach/mach_time.h>
*/
import "C"

import "time"

// GOOS=ios also selects Darwin files. gomobile enables cgo for both device and
// simulator builds, so every supported iOS target uses this sleep-aware clock.
var continuousTimebase = func() C.mach_timebase_info_data_t {
	var info C.mach_timebase_info_data_t
	if C.mach_timebase_info(&info) != 0 || info.numer == 0 || info.denom == 0 {
		panic("sessionclock: unavailable Mach timebase")
	}
	return info
}()

func continuousNow() time.Duration {
	// Go's time.Since uses mach_absolute_time on Apple platforms, which pauses
	// during system sleep. mach_continuous_time keeps counting through sleep.
	ticks := uint64(C.mach_continuous_time())
	numerator := uint64(continuousTimebase.numer)
	denominator := uint64(continuousTimebase.denom)
	// Divide before multiplying to avoid overflowing the raw tick conversion.
	return time.Duration(ticks/denominator*numerator + ticks%denominator*numerator/denominator)
}
