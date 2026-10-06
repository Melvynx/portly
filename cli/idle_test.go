package main

import (
	"encoding/json"
	"testing"
	"time"
)

func TestIdleTrackerActivitySignals(t *testing.T) {
	start := time.Unix(1_000_000, 0)
	var tr idleTracker
	if tr.isIdle(60, start.Add(time.Hour)) {
		t.Fatal("a tracker that never started must not report idle")
	}
	tr.reset(start)
	if tr.isIdle(60, start.Add(59*time.Second)) {
		t.Fatal("idle before the timeout")
	}
	if !tr.isIdle(60, start.Add(60*time.Second)) {
		t.Fatal("not idle at the timeout")
	}

	tr.recordOutput(start.Add(50 * time.Second))
	if tr.isIdle(60, start.Add(100*time.Second)) {
		t.Fatal("output should extend the deadline")
	}
	tr.recordCPU(idleBusyCPUPercent-0.1, start.Add(100*time.Second))
	if !tr.isIdle(60, start.Add(110*time.Second)) {
		t.Fatal("background CPU should not count as activity")
	}
	tr.recordCPU(idleBusyCPUPercent, start.Add(110*time.Second))
	if tr.isIdle(60, start.Add(160*time.Second)) {
		t.Fatal("busy CPU should extend the deadline")
	}
}

func TestIdleTrackerIgnoresHealthProbeEcho(t *testing.T) {
	start := time.Unix(1_000_000, 0)
	var tr idleTracker
	tr.reset(start)
	tr.recordProbe(start.Add(30*time.Second), 10*time.Second)
	tr.recordOutput(start.Add(30*time.Second + 200*time.Millisecond))
	if !tr.isIdle(60, start.Add(60*time.Second)) {
		t.Fatal("output answering a health probe should not count")
	}
	tr.recordOutput(start.Add(35 * time.Second))
	if tr.isIdle(60, start.Add(60*time.Second)) {
		t.Fatal("output between probes should count")
	}

	tr.reset(start)
	tr.recordProbe(start.Add(10*time.Second), time.Second)
	tr.recordOutput(start.Add(10*time.Second + 500*time.Millisecond))
	if tr.isIdle(60, start.Add(60*time.Second)) {
		t.Fatal("fast startup probes must keep the echo window short")
	}
}

func TestIdleTimeoutPolicyAndParsing(t *testing.T) {
	global := 1800
	zero := 0
	custom := 600
	server := newServerConfig("web", "pnpm dev")
	if server.effectiveIdleTimeout(nil) != nil {
		t.Fatal("no global and no override should be off")
	}
	if got := server.effectiveIdleTimeout(&global); got == nil || *got != 1800 {
		t.Fatalf("inherit got %v", got)
	}
	server.IdleTimeoutSeconds = &zero
	if server.effectiveIdleTimeout(&global) != nil {
		t.Fatal("0 should disable idle stops")
	}
	server.IdleTimeoutSeconds = &custom
	if got := server.effectiveIdleTimeout(&global); got == nil || *got != 600 {
		t.Fatalf("custom got %v", got)
	}

	if got, err := parseIdleTimeout("30m", false); err != nil || got == nil || *got != 1800 {
		t.Fatalf("30m got %v err %v", got, err)
	}
	if got, err := parseIdleTimeout("off", false); err != nil || got == nil || *got != 0 {
		t.Fatalf("off got %v err %v", got, err)
	}
	if got, err := parseIdleTimeout("inherit", true); err != nil || got != nil {
		t.Fatalf("inherit got %v err %v", got, err)
	}
	for _, raw := range []string{"30s", "8d", "soon"} {
		if _, err := parseIdleTimeout(raw, true); err == nil {
			t.Fatalf("%q should fail", raw)
		}
	}
	if _, err := parseIdleTimeout("inherit", false); err == nil {
		t.Fatal("global inherit should fail")
	}
	if describeIdleTimeout(3600) != "1 hour" || describeIdleTimeout(1800) != "30 minutes" {
		t.Fatal("describeIdleTimeout wording")
	}
}

func TestIdleTimeoutConfigRoundTripMatchesSwiftKeys(t *testing.T) {
	raw := []byte(`{"version":1,"idleTimeoutSeconds":1800,"projects":[{"name":"App","root":"/tmp","servers":[{"name":"db","command":"x","idleTimeoutSeconds":0},{"name":"web","command":"y"}]}]}`)
	var cfg PortlyConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatal(err)
	}
	if cfg.IdleTimeoutSeconds == nil || *cfg.IdleTimeoutSeconds != 1800 {
		t.Fatalf("global idle timeout %v", cfg.IdleTimeoutSeconds)
	}
	db, web := cfg.Projects[0].Servers[0], cfg.Projects[0].Servers[1]
	if db.IdleTimeoutSeconds == nil || *db.IdleTimeoutSeconds != 0 || web.IdleTimeoutSeconds != nil {
		t.Fatalf("server overrides db=%v web=%v", db.IdleTimeoutSeconds, web.IdleTimeoutSeconds)
	}
	out, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	var back PortlyConfig
	if err := json.Unmarshal(out, &back); err != nil {
		t.Fatal(err)
	}
	if back.Projects[0].Servers[0].IdleTimeoutSeconds == nil || back.Projects[0].Servers[1].IdleTimeoutSeconds != nil {
		t.Fatal("explicit 0 must survive a round trip and inherit must stay omitted")
	}
}

func TestRuntimeStopsAfterInactivity(t *testing.T) {
	t.Setenv("PORTLY_HOME", t.TempDir())
	seconds := 1
	cfg := newServerConfig("quiet", "sleep 30")
	cfg.IdleTimeoutSeconds = &seconds
	project := newProject("Idle", t.TempDir())
	rt := newRuntime(cfg, project, defaultConfig())
	rt.start()
	defer rt.stop(nil)

	waitUntil(t, 3*time.Second, func() bool { return rt.currentPID() > 0 })
	rt.stopIfIdle(time.Now())
	if !rt.isRunning() {
		t.Fatal("stopped before the idle timeout")
	}

	rt.stopIfIdle(time.Now().Add(2 * time.Second))
	waitUntil(t, 7*time.Second, func() bool { return rt.status().State == StateStopped })
	st := rt.status()
	if st.IdleStoppedAt == nil || st.LastError == nil {
		t.Fatalf("idle stop should be reported, got %+v", st)
	}
	if st.RestartCount != 0 {
		t.Fatal("an idle stop must not trigger an automatic restart")
	}
}

func waitUntil(t *testing.T, timeout time.Duration, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("condition not met before timeout")
}
