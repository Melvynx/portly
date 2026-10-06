package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

type serverRuntime struct {
	mu sync.Mutex

	id           string
	config       ServerConfig
	projectID    string
	projectName  string
	projectRoot  string
	projectColor string
	settings     PortlyConfig

	state        ServerState
	healthy      bool
	pid          *int
	startedAt    time.Time
	restartCount int
	lastExitCode *int
	lastError    *string
	metrics      *processMetrics

	child      *childProcess
	logs       *logStore
	manualStop bool
	onChange   func()

	timeoutSeconds     *int
	deadline           time.Time
	finishedAt         time.Time
	timedOut           bool
	stoppedByUser      bool
	temporaryStartedAt time.Time

	idle          idleTracker
	idleStoppedAt time.Time

	takeoverPending bool
	healthFails     int
	lastHealthyAt   time.Time
	stopThen        func()
	killTimer       *time.Timer
	timeoutTimer    *time.Timer
	restartTimer    *time.Timer
	healthStop      chan struct{}
}

func newRuntime(cfg ServerConfig, project Project, settings PortlyConfig) *serverRuntime {
	return &serverRuntime{
		id:           cfg.ID,
		config:       cfg,
		projectID:    project.ID,
		projectName:  project.Name,
		projectRoot:  project.Root,
		projectColor: project.Color,
		settings:     settings,
		state:        StateStopped,
		logs:         newLogStore(cfg.ID, settings.LogBufferLines, settings.LogFileMaxMB),
	}
}

func (r *serverRuntime) apply(cfg ServerConfig, project Project, settings PortlyConfig) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.config = cfg
	r.projectID = project.ID
	r.projectName = project.Name
	r.projectRoot = project.Root
	r.projectColor = project.Color
	r.settings = settings
	r.logs.updateLimits(settings.LogBufferLines, settings.LogFileMaxMB)
}

func (r *serverRuntime) isRunning() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.state.isActive()
}

func (r *serverRuntime) workingDirectory() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.workingDirectoryLocked()
}

func (r *serverRuntime) workingDirectoryLocked() string {
	if r.config.Directory == nil || *r.config.Directory == "" {
		return expandPath(r.projectRoot)
	}
	dir := *r.config.Directory
	if filepath.IsAbs(dir) || stringsHasTilde(dir) {
		return expandPath(dir)
	}
	return filepath.Join(expandPath(r.projectRoot), dir)
}

func stringsHasTilde(dir string) bool {
	return len(dir) > 0 && dir[0] == '~'
}

func (r *serverRuntime) configureTemporary(seconds int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.timeoutSeconds = &seconds
}

func (r *serverRuntime) isTemporary() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.timeoutSeconds != nil
}

func (r *serverRuntime) status() ServerStatus {
	r.mu.Lock()
	defer r.mu.Unlock()
	var url *string
	if r.config.Port != nil {
		u := fmt.Sprintf("http://localhost:%d", *r.config.Port)
		url = &u
	}
	st := ServerStatus{
		ID:           r.id,
		Name:         r.config.Name,
		ProjectID:    r.projectID,
		ProjectName:  r.projectName,
		Command:      r.config.Command,
		Port:         r.config.Port,
		Directory:    r.workingDirectoryLocked(),
		State:        r.state,
		PID:          r.pid,
		RestartCount: r.restartCount,
		LastExitCode: r.lastExitCode,
		LastError:    r.lastError,
		Healthy:      r.healthy,
		URL:          url,
	}
	if !r.startedAt.IsZero() {
		st.StartedAt = ptrTime(r.startedAt)
	} else if !r.temporaryStartedAt.IsZero() {
		st.StartedAt = ptrTime(r.temporaryStartedAt)
	}
	if r.metrics != nil {
		cpu := r.metrics.CPUPercent
		mem := r.metrics.MemoryBytes
		rss := r.metrics.ResidentMemoryBytes
		count := r.metrics.ProcessCount
		st.CPUPercent = &cpu
		st.MemoryBytes = &mem
		st.ResidentMemoryBytes = &rss
		st.ProcessCount = &count
	}
	if r.timeoutSeconds != nil {
		tmp := true
		st.Temporary = &tmp
		st.TimeoutSeconds = r.timeoutSeconds
		if !r.deadline.IsZero() {
			st.Deadline = ptrTime(r.deadline)
		}
		if !r.finishedAt.IsZero() {
			st.FinishedAt = ptrTime(r.finishedAt)
		}
		timedOut := r.timedOut
		st.TimedOut = &timedOut
	}
	st.IdleTimeoutSeconds = r.idleTimeoutLocked()
	if r.state.isActive() && !r.idle.lastActivityAt.IsZero() {
		st.LastActivityAt = ptrTime(r.idle.lastActivityAt)
	}
	if !r.idleStoppedAt.IsZero() {
		st.IdleStoppedAt = ptrTime(r.idleStoppedAt)
	}
	return st
}

// Temporary jobs already have a hard deadline, so they never idle out.
func (r *serverRuntime) idleTimeoutLocked() *int {
	if r.timeoutSeconds != nil {
		return nil
	}
	return r.config.effectiveIdleTimeout(r.settings.IdleTimeoutSeconds)
}

// stopIfIdle runs on every metrics tick, after CPU has been recorded.
func (r *serverRuntime) stopIfIdle(now time.Time) {
	r.mu.Lock()
	timeout := r.idleTimeoutLocked()
	if timeout == nil || r.manualStop || r.state == StateRestarting || r.child == nil || !r.idle.isIdle(*timeout, now) {
		r.mu.Unlock()
		return
	}
	msg := fmt.Sprintf("Stopped after %s without output or CPU activity", describeIdleTimeout(*timeout))
	r.lastError = &msg
	r.idleStoppedAt = now
	r.logs.note("idle guard: " + msg)
	r.mu.Unlock()
	r.stop(nil)
}

func (r *serverRuntime) jobStatus() *TemporaryJobStatus {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.timeoutSeconds == nil {
		return nil
	}
	state := JobRunning
	switch {
	case r.timedOut:
		state = JobTimedOut
	case r.state.isActive():
		state = JobRunning
	case r.state == StateFailed || (r.lastExitCode != nil && *r.lastExitCode != 0):
		state = JobFailed
	case r.stoppedByUser:
		state = JobStopped
	case r.lastExitCode != nil && *r.lastExitCode == 0:
		state = JobSucceeded
	default:
		state = JobStopped
	}
	return &TemporaryJobStatus{
		ID:             r.id,
		Name:           r.config.Name,
		Command:        r.config.Command,
		Directory:      r.workingDirectoryLocked(),
		State:          state,
		PID:            r.pid,
		StartedAt:      ptrTime(r.temporaryStartedAt),
		FinishedAt:     ptrTime(r.finishedAt),
		TimeoutSeconds: *r.timeoutSeconds,
		Deadline:       ptrTime(r.deadline),
		ExitCode:       r.lastExitCode,
		Error:          r.lastError,
	}
}

func (r *serverRuntime) start() {
	r.mu.Lock()
	if r.state.isActive() {
		r.mu.Unlock()
		return
	}
	r.takeoverPending = false
	if r.restartTimer != nil {
		r.restartTimer.Stop()
		r.restartTimer = nil
	}
	r.manualStop = false
	r.restartCount = 0
	r.lastHealthyAt = time.Time{}
	r.healthFails = 0
	if r.timeoutSeconds != nil {
		if r.timeoutTimer != nil {
			r.timeoutTimer.Stop()
			r.timeoutTimer = nil
		}
		r.temporaryStartedAt = time.Time{}
		r.deadline = time.Time{}
		r.finishedAt = time.Time{}
		r.timedOut = false
		r.stoppedByUser = false
		r.lastExitCode = nil
	}
	r.mu.Unlock()
	r.spawn()
}

func (r *serverRuntime) restart() {
	r.mu.Lock()
	r.restartCount = 0
	running := r.state.isActive()
	r.mu.Unlock()
	if running {
		r.stop(func() { r.start() })
		return
	}
	r.start()
}

func (r *serverRuntime) restartForMemory(footprint, limit uint64) {
	msg := fmt.Sprintf("memory guard: project footprint %s exceeded %s; restarting", displayMemorySize(footprint), displayMemorySize(limit))
	r.logs.note(msg)
	r.restart()
}

func (r *serverRuntime) stop(then func()) {
	r.mu.Lock()
	if r.timeoutSeconds != nil && !r.timedOut {
		r.stoppedByUser = true
	}
	if r.child == nil || r.child.pid() <= 0 {
		r.takeoverPending = false
		if r.timeoutSeconds != nil && r.finishedAt.IsZero() {
			r.finishedAt = time.Now()
		}
		if r.timeoutTimer != nil {
			r.timeoutTimer.Stop()
			r.timeoutTimer = nil
		}
		r.setStateLocked(StateStopped)
		r.mu.Unlock()
		if then != nil {
			then()
		}
		return
	}
	r.manualStop = true
	r.stopHealthLocked()
	if r.restartTimer != nil {
		r.restartTimer.Stop()
		r.restartTimer = nil
	}
	r.stopThen = then
	group := r.child.pgid
	r.logs.note(fmt.Sprintf("stopping (SIGTERM to process group %d)", group))
	r.child.signalGroup(syscall.SIGTERM)
	if r.killTimer != nil {
		r.killTimer.Stop()
	}
	child := r.child
	r.killTimer = time.AfterFunc(5*time.Second, func() {
		r.logs.note("did not exit in 5s, sending SIGKILL")
		child.signalGroup(syscall.SIGKILL)
	})
	r.mu.Unlock()
}

func (r *serverRuntime) spawn() {
	r.mu.Lock()
	r.setStateLocked(StateStarting)
	r.lastError = nil
	r.idleStoppedAt = time.Time{}
	r.healthy = false
	r.healthFails = 0
	cfg := r.config
	dir := r.workingDirectoryLocked()
	r.mu.Unlock()

	if cfg.Port != nil {
		if occ := occupantOf(*cfg.Port); occ != nil {
			msg := fmt.Sprintf("Port %d is already used by %s (pid %d)", *cfg.Port, occ.Command, occ.PID)
			r.failStart(msg)
			return
		}
	}
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() {
		r.failStart("Directory not found: " + dir)
		return
	}

	r.logs.note(fmt.Sprintf("starting: %s  (cwd: %s)", cfg.Command, dir))
	env := childEnv(nil, cfg.Name, cfg.Port, cfg.Env)
	child, reader, err := startChild(cfg.Command, dir, env)
	if err != nil {
		r.failStart(err.Error())
		return
	}

	r.mu.Lock()
	r.child = child
	pid := child.pid()
	r.pid = &pid
	r.startedAt = time.Now()
	r.idle.reset(r.startedAt)
	if r.timeoutSeconds != nil {
		r.temporaryStartedAt = r.startedAt
		r.scheduleTimeoutLocked()
	}
	r.startHealthLocked()
	r.notify()
	r.mu.Unlock()

	go r.consumeOutput(reader)
	go r.waitChild(child)
}

func (r *serverRuntime) failStart(msg string) {
	r.mu.Lock()
	r.lastError = &msg
	r.logs.note("cannot start, " + msg)
	r.setStateLocked(StateFailed)
	r.mu.Unlock()
}

func (r *serverRuntime) consumeOutput(reader io.Reader) {
	buf := make([]byte, 4096)
	for {
		n, err := reader.Read(buf)
		if n > 0 {
			r.logs.appendBytes(buf[:n])
			r.mu.Lock()
			r.idle.recordOutput(time.Now())
			r.mu.Unlock()
		}
		if err != nil {
			return
		}
	}
}

func (r *serverRuntime) waitChild(child *childProcess) {
	err := child.wait()
	code := exitCodeFromWait(err)
	r.mu.Lock()
	if r.killTimer != nil {
		r.killTimer.Stop()
		r.killTimer = nil
	}
	r.stopHealthLocked()
	if r.timeoutTimer != nil {
		r.timeoutTimer.Stop()
		r.timeoutTimer = nil
	}
	r.lastExitCode = &code
	r.pid = nil
	r.healthy = false
	r.metrics = nil
	r.child = nil
	r.idle.clear()
	if r.timeoutSeconds != nil {
		r.finishedAt = time.Now()
	}
	r.logs.note(fmt.Sprintf("process exited (%d)", code))
	manual := r.manualStop
	then := r.stopThen
	r.stopThen = nil
	temporary := r.timeoutSeconds != nil
	timedOut := r.timedOut
	auto := r.config.AutoRestart
	r.mu.Unlock()

	if manual {
		r.mu.Lock()
		r.manualStop = false
		if timedOut {
			r.setStateLocked(StateFailed)
		} else {
			r.setStateLocked(StateStopped)
		}
		r.mu.Unlock()
		if then != nil {
			then()
		}
		return
	}
	if temporary {
		r.mu.Lock()
		if code == 0 {
			r.setStateLocked(StateStopped)
		} else {
			msg := fmt.Sprintf("Exited with code %d", code)
			r.lastError = &msg
			r.setStateLocked(StateFailed)
		}
		r.mu.Unlock()
		return
	}
	if !auto {
		r.mu.Lock()
		r.setStateLocked(StateStopped)
		r.mu.Unlock()
		return
	}
	r.handleCrashRestart(fmt.Sprintf("exit %d", code))
}

func (r *serverRuntime) handleCrashRestart(reason string) {
	r.mu.Lock()
	if !r.config.AutoRestart {
		r.setStateLocked(StateStopped)
		r.mu.Unlock()
		return
	}
	if !r.lastHealthyAt.IsZero() && time.Since(r.lastHealthyAt) > 30*time.Second {
		r.restartCount = 0
	}
	if r.restartCount >= r.settings.MaxRestartAttempts {
		msg := fmt.Sprintf("Gave up after %d restart attempts (%s)", r.restartCount, reason)
		r.lastError = &msg
		r.logs.note(fmt.Sprintf("giving up after %d restart attempts", r.restartCount))
		r.setStateLocked(StateFailed)
		r.mu.Unlock()
		return
	}
	r.restartCount++
	delay := time.Duration(1<<min(uint(r.restartCount-1), 5)) * time.Second
	if delay > 30*time.Second {
		delay = 30 * time.Second
	}
	r.setStateLocked(StateRestarting)
	r.logs.note(fmt.Sprintf("restart %d/%d in %ds (%s)", r.restartCount, r.settings.MaxRestartAttempts, int(delay.Seconds()), reason))
	r.restartTimer = time.AfterFunc(delay, func() {
		r.mu.Lock()
		still := r.state == StateRestarting
		r.manualStop = false
		r.mu.Unlock()
		if still {
			r.spawn()
		}
	})
	r.mu.Unlock()
}

func (r *serverRuntime) scheduleTimeoutLocked() {
	if r.timeoutSeconds == nil {
		return
	}
	seconds := *r.timeoutSeconds
	r.deadline = time.Now().Add(time.Duration(seconds) * time.Second)
	if r.timeoutTimer != nil {
		r.timeoutTimer.Stop()
	}
	r.timeoutTimer = time.AfterFunc(time.Duration(seconds)*time.Second, func() {
		r.mu.Lock()
		running := r.state.isActive()
		if running {
			r.timedOut = true
			msg := "Timed out after " + displayTimeout(seconds)
			r.lastError = &msg
			r.logs.note(msg)
		}
		r.mu.Unlock()
		if running {
			r.stop(nil)
		}
	})
}

func (r *serverRuntime) startHealthLocked() {
	r.stopHealthLocked()
	r.healthStop = make(chan struct{})
	stop := r.healthStop
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		steady := false
		interval := time.Duration(max(2, r.settings.HealthIntervalSeconds)) * time.Second
		current := time.Second
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				r.runHealth(current)
				r.mu.Lock()
				state := r.state
				r.mu.Unlock()
				if !steady && (state == StateRunning || state == StateUnhealthy) {
					ticker.Reset(interval)
					current = interval
					steady = true
				}
			}
		}
	}()
}

func (r *serverRuntime) stopHealthLocked() {
	if r.healthStop != nil {
		close(r.healthStop)
		r.healthStop = nil
	}
}

func (r *serverRuntime) runHealth(interval time.Duration) {
	r.mu.Lock()
	running := r.state.isActive()
	cfg := r.config
	if running && (cfg.Port != nil || cfg.HealthURL != nil) {
		r.idle.recordProbe(time.Now(), interval)
	}
	r.mu.Unlock()
	if !running {
		return
	}
	ok := checkHealth(cfg)
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.state.isActive() {
		return
	}
	r.healthy = ok
	if ok {
		r.healthFails = 0
		r.lastHealthyAt = time.Now()
		if r.state != StateRunning {
			r.setStateLocked(StateRunning)
		} else {
			r.notify()
		}
		return
	}
	if r.state == StateStarting {
		r.notify()
		return
	}
	r.healthFails++
	if r.state == StateRunning {
		r.setStateLocked(StateUnhealthy)
	}
	if r.healthFails >= 3 && r.config.AutoRestart {
		r.logs.note(fmt.Sprintf("health check failed %dx, restarting", r.healthFails))
		r.healthFails = 0
		r.mu.Unlock()
		r.stop(func() { r.handleCrashRestart("unhealthy") })
		r.mu.Lock()
	} else {
		r.notify()
	}
}

func (r *serverRuntime) takeOverPort() bool {
	r.mu.Lock()
	if r.state.isActive() || r.config.Port == nil {
		r.mu.Unlock()
		return false
	}
	port := *r.config.Port
	r.mu.Unlock()
	occ := occupantOf(port)
	if occ == nil {
		return false
	}
	r.logs.note(fmt.Sprintf("preparing to take over port %d from %s (pid %d)", port, occ.Command, occ.PID))
	r.mu.Lock()
	r.takeoverPending = true
	msg := fmt.Sprintf("Stopping the current owner of port %d", port)
	r.lastError = &msg
	r.setStateLocked(StateStarting)
	expected := occ.PID
	r.mu.Unlock()

	go func() {
		outcome, err := stopOccupant(port, &expected)
		r.mu.Lock()
		pending := r.takeoverPending
		r.mu.Unlock()
		if !pending {
			return
		}
		if err != nil {
			r.mu.Lock()
			r.takeoverPending = false
			m := err.Error()
			r.lastError = &m
			r.logs.note("takeover failed: " + m)
			r.setStateLocked(StateFailed)
			r.mu.Unlock()
			return
		}
		r.logs.note(fmt.Sprintf("stopped %s; waiting for port %d", outcome.Description, port))
		r.mu.Lock()
		wait := fmt.Sprintf("Waiting for port %d to be released", port)
		r.lastError = &wait
		r.mu.Unlock()
		r.waitForPortRelease(port, 50)
	}()
	return true
}

func (r *serverRuntime) waitForPortRelease(port, remaining int) {
	time.Sleep(200 * time.Millisecond)
	r.mu.Lock()
	pending := r.takeoverPending
	r.mu.Unlock()
	if !pending {
		return
	}
	if !isListening(port) {
		r.mu.Lock()
		r.takeoverPending = false
		r.lastError = nil
		r.mu.Unlock()
		r.spawn()
		return
	}
	if remaining > 1 {
		r.waitForPortRelease(port, remaining-1)
		return
	}
	r.mu.Lock()
	r.takeoverPending = false
	msg := fmt.Sprintf("Port %d was not released after 5 seconds", port)
	r.lastError = &msg
	r.logs.note(msg)
	r.setStateLocked(StateFailed)
	r.mu.Unlock()
}

func (r *serverRuntime) setStateLocked(state ServerState) {
	if r.state == state {
		return
	}
	r.state = state
	if state == StateStopped || state == StateFailed {
		r.healthy = false
		r.pid = nil
		r.metrics = nil
		if state == StateStopped {
			r.startedAt = time.Time{}
		}
		if r.timeoutSeconds != nil && state == StateFailed && r.finishedAt.IsZero() {
			r.finishedAt = time.Now()
		}
	}
	r.notify()
}

func (r *serverRuntime) notify() {
	if r.onChange != nil {
		go r.onChange()
	}
}

func (r *serverRuntime) updateMetrics(m *processMetrics) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.metrics = m
	if m != nil {
		r.idle.recordCPU(m.ActiveCPUPercent, time.Now())
	}
}

func (r *serverRuntime) logTail(n int) []string { return r.logs.tail(n) }

func (r *serverRuntime) currentPID() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.pid == nil {
		return 0
	}
	return *r.pid
}
