package main

import (
	"encoding/json"
	"flag"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestTemporaryTimeoutParsesFriendlyDurations(t *testing.T) {
	cases := map[string]int{"45": 45, "30s": 30, "1.5m": 90, "2h": 7200}
	for raw, want := range cases {
		got, ok := parseTimeout(raw)
		if !ok || got != want {
			t.Fatalf("parseTimeout(%q)=%d,%v want %d,true", raw, got, ok, want)
		}
	}
	for _, raw := range []string{"0", "forever", "8d"} {
		if _, ok := parseTimeout(raw); ok {
			t.Fatalf("parseTimeout(%q) should fail", raw)
		}
	}
}

func TestMemorySizeParseAndDisplay(t *testing.T) {
	got, ok := parseMemorySize("5GB")
	if !ok || got != 5*1024*1024*1024 {
		t.Fatalf("parse 5GB got %d ok=%v", got, ok)
	}
	if displayMemorySize(5*1024*1024*1024) != "5 GB" {
		t.Fatalf("display 5GB = %s", displayMemorySize(5*1024*1024*1024))
	}
	if _, ok := parseMemorySize("10MB"); ok {
		t.Fatal("10MB is below the 128MB floor")
	}
}

func TestMemoryGuardRequiresThreeSamples(t *testing.T) {
	g := newMemoryGuard()
	if g.shouldRestart("p", 200, 100, true) {
		t.Fatal("first sample should not restart")
	}
	if g.shouldRestart("p", 200, 100, true) {
		t.Fatal("second sample should not restart")
	}
	if !g.shouldRestart("p", 200, 100, true) {
		t.Fatal("third sample should restart")
	}
	if g.shouldRestart("p", 200, 100, true) {
		t.Fatal("counter should reset after a restart")
	}
	if g.shouldRestart("p", 50, 100, true) {
		t.Fatal("under-limit sample should not restart")
	}
}

func TestServerConfigDecodesOlderPayloadWithoutActions(t *testing.T) {
	var server ServerConfig
	if err := json.Unmarshal([]byte(`{"name":"web","command":"pnpm dev"}`), &server); err != nil {
		t.Fatal(err)
	}
	if len(server.Actions) != 0 {
		t.Fatalf("actions=%v", server.Actions)
	}
	if !server.AutoRestart {
		t.Fatal("autoRestart should default true")
	}
	if server.ID == "" {
		t.Fatal("id should be generated")
	}
}

func TestPortlyStatusDecodesOlderPayloadWithoutTemporaryServers(t *testing.T) {
	var status PortlyStatus
	if err := json.Unmarshal([]byte(`{"version":"0.1.10","apiPort":7737,"projects":[]}`), &status); err != nil {
		t.Fatal(err)
	}
	if status.TemporaryServers == nil {
		status.TemporaryServers = []ServerStatus{}
	}
	if len(status.TemporaryServers) != 0 {
		t.Fatal(status.TemporaryServers)
	}
}

func TestTemporaryJobMapsTerminalStateToShellExitCode(t *testing.T) {
	base := TemporaryJobStatus{ID: "tmp_test", Name: "build", Command: "true", Directory: "/tmp", TimeoutSeconds: 60}
	cases := []struct {
		state TemporaryJobState
		exit  *int
		want  int
	}{
		{JobSucceeded, intPtr(0), 0},
		{JobTimedOut, nil, 124},
		{JobStopped, nil, 130},
		{JobFailed, intPtr(7), 7},
		{JobFailed, intPtr(0), 1},
	}
	for _, tc := range cases {
		job := base
		job.State = tc.state
		job.ExitCode = tc.exit
		if job.processExitCode() != tc.want {
			t.Fatalf("%s => %d want %d", tc.state, job.processExitCode(), tc.want)
		}
	}
}

func TestSanitizeLogStripsANSIAndCarriageReturns(t *testing.T) {
	got := sanitizeLog("\x1b[31mred\x1b[0m\rfinal")
	if got != "final" {
		t.Fatalf("got %q", got)
	}
}

func TestAPIBindsLoopbackOnly(t *testing.T) {
	home := t.TempDir()
	t.Setenv("PORTLY_HOME", home)
	store := newConfigStore(filepath.Join(home, "config.json"))
	sup := newSupervisor(store, 0)
	defer sup.close()
	srv, err := startAPI(sup, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer srv.close()
	host, _, err := net.SplitHostPort(srv.listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	if host != "127.0.0.1" {
		t.Fatalf("bound %s, want 127.0.0.1", host)
	}
}

func TestTempWaitIntegration(t *testing.T) {
	home := t.TempDir()
	t.Setenv("PORTLY_HOME", home)
	store := newConfigStore(filepath.Join(home, "config.json"))
	sup := newSupervisor(store, 0)
	defer sup.close()
	srv, err := startAPI(sup, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer srv.close()

	c := newClient(srv.port)
	dir := t.TempDir()
	timeout := 30
	command := "printf 'hello-portly\\n'; exit 3"
	if runtime.GOOS == "windows" {
		command = "echo hello-portly& exit /b 3"
	}
	var job TemporaryJobStatus
	if err := c.post("temporary/run", runTemporaryRequest{
		Name:           "echo-job",
		Command:        command,
		Directory:      dir,
		TimeoutSeconds: &timeout,
	}, &job); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(job.ID, "tmp_") {
		t.Fatalf("id=%s", job.ID)
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) && !job.State.isFinished() {
		time.Sleep(50 * time.Millisecond)
		if err := c.request("GET", "temporary/status?id="+job.ID, nil, &job, false); err != nil {
			t.Fatal(err)
		}
	}
	if job.State != JobFailed {
		t.Fatalf("state=%s error=%v", job.State, job.Error)
	}
	if job.processExitCode() != 3 {
		errMsg := ""
		if job.Error != nil {
			errMsg = *job.Error
		}
		t.Fatalf("exit=%d state=%s err=%s", job.processExitCode(), job.State, errMsg)
	}
	var logs logsResponse
	if err := c.request("GET", "logs?server="+job.ID+"&tail=50", nil, &logs, false); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(logs.Lines, "\n")
	if !strings.Contains(joined, "hello-portly") {
		t.Fatalf("logs=%q", joined)
	}
	cfg, _ := os.ReadFile(filepath.Join(home, "config.json"))
	if strings.Contains(string(cfg), job.ID) {
		t.Fatal("temporary job leaked into config.json")
	}
}

func TestProjectServerLifecycle(t *testing.T) {
	home := t.TempDir()
	t.Setenv("PORTLY_HOME", home)
	root := t.TempDir()
	store := newConfigStore(filepath.Join(home, "config.json"))
	sup := newSupervisor(store, 0)
	defer sup.close()
	srv, err := startAPI(sup, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer srv.close()
	c := newClient(srv.port)

	var project Project
	if err := c.post("projects/add", addProjectRequest{Name: "demo", Root: root}, &project); err != nil {
		t.Fatal(err)
	}
	start := true
	port := freePort(t)
	python := "python3"
	if runtime.GOOS == "windows" {
		python = "python"
	}
	var server ServerConfig
	if err := c.post("servers/add", addServerRequest{
		Project: project.Name,
		Name:    "web",
		Command: python + " -m http.server " + itoa(port),
		Port:    &port,
		Start:   &start,
	}, &server); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(8 * time.Second)
	var status PortlyStatus
	healthy := false
	for time.Now().Before(deadline) {
		if err := c.request("GET", "status", nil, &status, false); err != nil {
			t.Fatal(err)
		}
		if len(status.Projects) == 1 && len(status.Projects[0].Servers) == 1 {
			st := status.Projects[0].Servers[0]
			if st.State == StateRunning && st.Healthy {
				healthy = true
				break
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !healthy {
		errMsg := ""
		if len(status.Projects) > 0 && len(status.Projects[0].Servers) > 0 && status.Projects[0].Servers[0].LastError != nil {
			errMsg = *status.Projects[0].Servers[0].LastError
		}
		t.Fatalf("server never became healthy: %s status=%+v", errMsg, status)
	}
	var resp actionResponse
	if err := c.post("stop", targetRequest{Server: strPtr(project.Name + "/web")}, &resp); err != nil {
		t.Fatal(err)
	}
	if err := c.post("open", openRequest{}, &resp); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(resp.Message, "No UI") {
		t.Fatalf("open message=%q", resp.Message)
	}
}

func TestParseFlexibleKeepsFlagsAfterCommand(t *testing.T) {
	fs := flag.NewFlagSet("temp", flag.ContinueOnError)
	timeout := fs.String("timeout", "30m", "")
	if err := parseFlexible(fs, []string{"echo hi", "--timeout", "10s"}); err != nil {
		t.Fatal(err)
	}
	if fs.Arg(0) != "echo hi" {
		t.Fatalf("arg=%q", fs.Arg(0))
	}
	if *timeout != "10s" {
		t.Fatalf("timeout=%q", *timeout)
	}
}

func TestForeverStatusDoesNotWriteLaunchAgent(t *testing.T) {
	state := currentForeverState()
	if strings.Contains(state.Unit, "LaunchAgents") {
		t.Fatalf("unit path leaked launchd: %s", state.Unit)
	}
}

func TestForeverUnitIsSystemdUserService(t *testing.T) {
	unit := foreverUnitContents("/usr/local/bin/portly")
	for _, want := range []string{
		"[Unit]",
		"[Service]",
		"[Install]",
		"WantedBy=default.target",
		"ExecStart=/usr/local/bin/portly daemon",
		"WorkingDirectory=%h",
	} {
		if !strings.Contains(unit, want) {
			t.Fatalf("missing %q in:\n%s", want, unit)
		}
	}
	if strings.Contains(unit, "LaunchAgents") || strings.Contains(unit, "launchctl") {
		t.Fatal(unit)
	}
}

func intPtr(v int) *int       { return &v }
func strPtr(v string) *string { return &v }

func freePort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	return port
}

func TestParseNetstatListenerIgnoresLocalizedStateAndClients(t *testing.T) {
	out := "  Proto  Adresse locale         Adresse distante       État\r\n" +
		"  TCP    127.0.0.1:51730        127.0.0.1:5173         ESTABLISHED     900\r\n" +
		"  TCP    0.0.0.0:15173          0.0.0.0:0              LISTENING       901\r\n" +
		"  TCP    [::1]:5173             [::]:0                 ABHÖREN         4242\r\n"
	if pid := parseNetstatListener(out, 5173); pid != 4242 {
		t.Fatalf("pid=%d", pid)
	}
	if pid := parseNetstatListener(out, 5174); pid != 0 {
		t.Fatalf("pid=%d", pid)
	}
}
