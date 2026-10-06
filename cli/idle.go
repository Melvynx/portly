package main

import (
	"fmt"
	"strings"
	"time"
)

const (
	minimumIdleTimeoutSeconds = 60
	maximumIdleTimeoutSeconds = maximumTimeoutSeconds
	idleBusyCPUPercent        = 5.0
	maximumProbeEchoWindow    = 2 * time.Second
)

// idleTracker decides when a supervised server has been quiet long enough to
// stop. Output and CPU at or above idleBusyCPUPercent count as activity.
// Output that lands right after a Portly health probe does not: servers that
// log every request would otherwise keep themselves alive answering Portly.
// Callers hold the runtime lock.
type idleTracker struct {
	lastActivityAt  time.Time
	lastProbeAt     time.Time
	probeEchoWindow time.Duration
}

func (t *idleTracker) reset(at time.Time) {
	t.lastActivityAt = at
	t.lastProbeAt = time.Time{}
}

func (t *idleTracker) clear() {
	t.lastActivityAt = time.Time{}
	t.lastProbeAt = time.Time{}
}

// The echo window stays a fraction of the probe interval so fast startup
// probing cannot hide all output.
func (t *idleTracker) recordProbe(at time.Time, interval time.Duration) {
	t.lastProbeAt = at
	t.probeEchoWindow = min(maximumProbeEchoWindow, interval/4)
}

func (t *idleTracker) recordOutput(at time.Time) {
	if !t.lastProbeAt.IsZero() {
		since := at.Sub(t.lastProbeAt)
		if since >= 0 && since < t.probeEchoWindow {
			return
		}
	}
	t.lastActivityAt = at
}

func (t *idleTracker) recordCPU(percent float64, at time.Time) {
	if percent >= idleBusyCPUPercent {
		t.lastActivityAt = at
	}
}

func (t *idleTracker) isIdle(timeoutSeconds int, now time.Time) bool {
	if t.lastActivityAt.IsZero() {
		return false
	}
	return now.Sub(t.lastActivityAt) >= time.Duration(timeoutSeconds)*time.Second
}

func validIdleTimeout(seconds int) bool {
	return seconds == 0 || (seconds >= minimumIdleTimeoutSeconds && seconds <= maximumIdleTimeoutSeconds)
}

// parseIdleTimeout returns nil for inherit and 0 for off.
func parseIdleTimeout(raw string, allowInherit bool) (*int, error) {
	value := strings.ToLower(strings.TrimSpace(raw))
	switch value {
	case "off", "disabled", "none", "never", "0":
		zero := 0
		return &zero, nil
	case "inherit":
		if !allowInherit {
			return nil, fmt.Errorf("the global idle timeout cannot inherit; use a duration or off")
		}
		return nil, nil
	}
	seconds, ok := parseTimeout(value)
	if !ok || seconds < minimumIdleTimeoutSeconds {
		return nil, fmt.Errorf("bad idle timeout '%s'. Use a duration from 1m to 7 days, for example 30m or 2h, or off", raw)
	}
	return &seconds, nil
}

func describeIdleTimeout(seconds int) string {
	plural := func(n int, unit string) string {
		if n == 1 {
			return fmt.Sprintf("%d %s", n, unit)
		}
		return fmt.Sprintf("%d %ss", n, unit)
	}
	switch {
	case seconds%3600 == 0:
		return plural(seconds/3600, "hour")
	case seconds%60 == 0:
		return plural(seconds/60, "minute")
	default:
		return plural(seconds, "second")
	}
}
