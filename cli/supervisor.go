package main

import (
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	temporaryProjectID    = "portly-temporary"
	temporaryProjectColor = "#8E8E93"
)

var palette = []string{
	"#0A84FF", "#FF9F0A", "#BF5AF2", "#30D158", "#FF375F",
	"#64D2FF", "#FFD60A", "#5E5CE6", "#66D4CF", "#8E8E93",
}

type memoryRestart struct {
	at        time.Time
	bytes     uint64
	serverIDs []string
}

type supervisor struct {
	mu           sync.Mutex
	store        *configStore
	runtimes     map[string]*serverRuntime
	temporaryIDs []string
	guard        *memoryGuard
	restarts     map[string]memoryRestart
	apiPort      int
	quit         chan struct{}
}

func newSupervisor(store *configStore, apiPort int) *supervisor {
	s := &supervisor{
		store:    store,
		runtimes: map[string]*serverRuntime{},
		guard:    newMemoryGuard(),
		restarts: map[string]memoryRestart{},
		apiPort:  apiPort,
		quit:     make(chan struct{}),
	}
	s.syncRuntimes()
	store.onChange = func(PortlyConfig) {
		s.mu.Lock()
		s.syncRuntimes()
		s.mu.Unlock()
	}
	store.startWatching()
	go s.metricsLoop()
	return s
}

func (s *supervisor) settings() PortlyConfig { return s.store.current() }

func (s *supervisor) syncRuntimes() {
	cfg := s.store.current()
	seen := map[string]bool{}
	for _, project := range cfg.Projects {
		for _, server := range project.Servers {
			seen[server.ID] = true
			if existing, ok := s.runtimes[server.ID]; ok {
				existing.apply(server, project, cfg)
				continue
			}
			rt := newRuntime(server, project, cfg)
			s.wire(rt, false)
			s.runtimes[server.ID] = rt
		}
	}
	temp := map[string]bool{}
	for _, id := range s.temporaryIDs {
		temp[id] = true
	}
	for id, rt := range s.runtimes {
		if !seen[id] && !temp[id] {
			rt.stop(nil)
			delete(s.runtimes, id)
		}
	}
}

func (s *supervisor) wire(rt *serverRuntime, temporary bool) {
	rt.onChange = func() {}
	if temporary {
		rt.onChange = func() {
			if !rt.isRunning() {
				s.scheduleTemporaryCleanup(rt.id)
			}
		}
	}
}

func (s *supervisor) scheduleTemporaryCleanup(id string) {
	time.AfterFunc(time.Hour, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		rt := s.runtimes[id]
		if rt == nil || rt.isRunning() {
			return
		}
		found := false
		for _, tid := range s.temporaryIDs {
			if tid == id {
				found = true
				break
			}
		}
		if !found {
			return
		}
		delete(s.runtimes, id)
		filtered := s.temporaryIDs[:0]
		for _, tid := range s.temporaryIDs {
			if tid != id {
				filtered = append(filtered, tid)
			}
		}
		s.temporaryIDs = filtered
	})
}

func (s *supervisor) metricsLoop() {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-s.quit:
			return
		case <-ticker.C:
			s.refreshMetrics()
		}
	}
}

func (s *supervisor) refreshMetrics() {
	s.mu.Lock()
	roots := map[int]struct{}{}
	targets := map[string]int{}
	for id, rt := range s.runtimes {
		if !rt.isRunning() {
			rt.updateMetrics(nil)
			continue
		}
		if pid := rt.currentPID(); pid > 0 {
			roots[pid] = struct{}{}
			targets[id] = pid
		}
	}
	cfg := s.store.current()
	s.mu.Unlock()

	samples := sampleMetrics(roots)

	s.mu.Lock()
	defer s.mu.Unlock()
	byProject := map[string]uint64{}
	runningByProject := map[string]bool{}
	for id, pid := range targets {
		rt := s.runtimes[id]
		if rt == nil || rt.currentPID() != pid {
			continue
		}
		m, ok := samples[pid]
		if ok {
			rt.updateMetrics(&m)
			byProject[rt.projectID] += m.MemoryBytes
		} else {
			rt.updateMetrics(nil)
		}
		if rt.isRunning() && !rt.isTemporary() {
			runningByProject[rt.projectID] = true
		}
	}
	for _, project := range cfg.Projects {
		limit := project.effectiveMemoryLimit(cfg.GlobalMemoryLimitBytes)
		var limitVal uint64
		if limit != nil {
			limitVal = *limit
		}
		if s.guard.shouldRestart(project.ID, byProject[project.ID], limitVal, runningByProject[project.ID]) {
			var ids []string
			for _, server := range project.Servers {
				if rt := s.runtimes[server.ID]; rt != nil && rt.isRunning() {
					ids = append(ids, server.ID)
					rt.restartForMemory(byProject[project.ID], limitVal)
				}
			}
			s.restarts[project.ID] = memoryRestart{at: time.Now(), bytes: byProject[project.ID], serverIDs: ids}
		}
	}
	now := time.Now()
	for _, rt := range s.runtimes {
		rt.stopIfIdle(now)
	}
}

func (s *supervisor) status() PortlyStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	cfg := s.store.current()
	projects := make([]ProjectStatus, 0, len(cfg.Projects))
	for _, project := range cfg.Projects {
		servers := make([]ServerStatus, 0, len(project.Servers))
		for _, server := range project.Servers {
			if rt := s.runtimes[server.ID]; rt != nil {
				servers = append(servers, rt.status())
			}
		}
		ps := ProjectStatus{
			ID:                        project.ID,
			Name:                      project.Name,
			Icon:                      project.Icon,
			Color:                     project.Color,
			Root:                      project.Root,
			Servers:                   servers,
			MemoryLimitMode:           project.MemoryLimitMode,
			MemoryLimitBytes:          project.MemoryLimitBytes,
			EffectiveMemoryLimitBytes: project.effectiveMemoryLimit(cfg.GlobalMemoryLimitBytes),
		}
		if ev, ok := s.restarts[project.ID]; ok {
			ps.LastMemoryRestartAt = ptrTime(ev.at)
			b := ev.bytes
			ps.LastMemoryRestartBytes = &b
		}
		projects = append(projects, ps)
	}
	temps := make([]ServerStatus, 0, len(s.temporaryIDs))
	for _, id := range s.temporaryIDs {
		if rt := s.runtimes[id]; rt != nil {
			temps = append(temps, rt.status())
		}
	}
	return PortlyStatus{
		Version:                  portlyVersion,
		APIPort:                  s.apiPort,
		GlobalMemoryLimitBytes:   cfg.GlobalMemoryLimitBytes,
		GlobalIdleTimeoutSeconds: cfg.IdleTimeoutSeconds,
		Projects:                 projects,
		TemporaryServers:         temps,
	}
}

func (s *supervisor) resolveRuntime(query string) *serverRuntime {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.resolveRuntimeLocked(query)
}

func (s *supervisor) resolveRuntimeLocked(query string) *serverRuntime {
	cfg := s.store.current()
	if hit := cfg.resolveServer(query); hit != nil {
		return s.runtimes[hit.Server.ID]
	}
	if rt := s.runtimes[query]; rt != nil {
		return rt
	}
	normalized := query
	if parts := strings.SplitN(query, "/", 2); len(parts) == 2 {
		normalized = parts[1]
	}
	for _, id := range s.temporaryIDs {
		rt := s.runtimes[id]
		if rt != nil && strings.EqualFold(rt.config.Name, normalized) {
			return rt
		}
	}
	return nil
}

func (s *supervisor) resolveProject(query string) *Project {
	cfg := s.store.current()
	return cfg.resolveProject(query)
}

func (s *supervisor) start(id string) { s.runtimeByID(id).start() }
func (s *supervisor) stop(id string)  { s.runtimeByID(id).stop(nil) }
func (s *supervisor) restart(id string) {
	if rt := s.runtimeByID(id); rt != nil {
		rt.restart()
	}
}

func (s *supervisor) runtimeByID(id string) *serverRuntime {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.runtimes[id]
}

func (s *supervisor) startProject(id string) {
	for _, rt := range s.runtimesInProject(id) {
		rt.start()
	}
}

func (s *supervisor) stopProject(id string) {
	for _, rt := range s.runtimesInProject(id) {
		rt.stop(nil)
	}
}

func (s *supervisor) stopAll() {
	s.mu.Lock()
	all := make([]*serverRuntime, 0, len(s.runtimes))
	for _, rt := range s.runtimes {
		all = append(all, rt)
	}
	s.mu.Unlock()
	for _, rt := range all {
		rt.stop(nil)
	}
}

func (s *supervisor) runtimesInProject(id string) []*serverRuntime {
	s.mu.Lock()
	defer s.mu.Unlock()
	cfg := s.store.current()
	p := cfg.projectByID(id)
	if p == nil {
		return nil
	}
	out := make([]*serverRuntime, 0, len(p.Servers))
	for _, server := range p.Servers {
		if rt := s.runtimes[server.ID]; rt != nil {
			out = append(out, rt)
		}
	}
	return out
}

func (s *supervisor) allRuntimes() []*serverRuntime {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]*serverRuntime, 0, len(s.runtimes))
	for _, rt := range s.runtimes {
		out = append(out, rt)
	}
	return out
}

func (s *supervisor) terminateEverything() {
	s.stopAll()
	deadline := time.Now().Add(6 * time.Second)
	for time.Now().Before(deadline) {
		still := false
		for _, rt := range s.allRuntimes() {
			if rt.isRunning() {
				still = true
				break
			}
		}
		if !still {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	for _, rt := range s.allRuntimes() {
		if pid := rt.currentPID(); pid > 0 {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
		}
	}
}

func (s *supervisor) addProject(name, root string, icon, color *string, mode MemoryLimitMode, bytes *uint64) Project {
	project := newProject(name, root)
	if icon != nil && *icon != "" {
		project.Icon = *icon
	}
	if color != nil && *color != "" {
		project.Color = *color
	} else {
		used := []string{}
		for _, p := range s.store.current().Projects {
			used = append(used, p.Color)
		}
		project.Color = nextColor(used)
	}
	project.MemoryLimitMode = mode
	if mode == MemoryCustom {
		project.MemoryLimitBytes = bytes
	}
	s.store.mutate(func(cfg *PortlyConfig) {
		cfg.Projects = append(cfg.Projects, project)
	})
	s.mu.Lock()
	s.syncRuntimes()
	s.mu.Unlock()
	return project
}

func (s *supervisor) removeProject(id string) {
	s.stopProject(id)
	s.store.mutate(func(cfg *PortlyConfig) {
		filtered := cfg.Projects[:0]
		for _, p := range cfg.Projects {
			if p.ID != id {
				filtered = append(filtered, p)
			}
		}
		cfg.Projects = filtered
	})
	s.mu.Lock()
	s.syncRuntimes()
	s.mu.Unlock()
}

func (s *supervisor) addServer(projectID string, server ServerConfig) {
	s.store.mutate(func(cfg *PortlyConfig) {
		for i := range cfg.Projects {
			if cfg.Projects[i].ID == projectID {
				cfg.Projects[i].Servers = append(cfg.Projects[i].Servers, server)
				return
			}
		}
	})
	s.mu.Lock()
	s.syncRuntimes()
	s.mu.Unlock()
}

func (s *supervisor) updateServer(server ServerConfig) {
	s.store.mutate(func(cfg *PortlyConfig) {
		for i := range cfg.Projects {
			for j := range cfg.Projects[i].Servers {
				if cfg.Projects[i].Servers[j].ID == server.ID {
					cfg.Projects[i].Servers[j] = server
					return
				}
			}
		}
	})
	s.mu.Lock()
	s.syncRuntimes()
	s.mu.Unlock()
}

func (s *supervisor) removeServer(id string) {
	s.mu.Lock()
	isTemp := false
	for _, tid := range s.temporaryIDs {
		if tid == id {
			isTemp = true
			break
		}
	}
	rt := s.runtimes[id]
	s.mu.Unlock()
	if isTemp {
		if rt != nil && rt.isRunning() {
			rt.stop(func() { s.dropTemporary(id) })
			return
		}
		s.dropTemporary(id)
		return
	}
	if rt != nil {
		rt.stop(nil)
	}
	s.store.mutate(func(cfg *PortlyConfig) {
		for i := range cfg.Projects {
			filtered := cfg.Projects[i].Servers[:0]
			for _, srv := range cfg.Projects[i].Servers {
				if srv.ID != id {
					filtered = append(filtered, srv)
				}
			}
			cfg.Projects[i].Servers = filtered
		}
	})
	s.mu.Lock()
	s.syncRuntimes()
	s.mu.Unlock()
}

func (s *supervisor) dropTemporary(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.runtimes, id)
	filtered := s.temporaryIDs[:0]
	for _, tid := range s.temporaryIDs {
		if tid != id {
			filtered = append(filtered, tid)
		}
	}
	s.temporaryIDs = filtered
}

func (s *supervisor) runTemporary(name, command, directory string, port *int, env map[string]string, healthURL *string, healthStatus *int, timeout int) *serverRuntime {
	dir := expandPath(directory)
	server := newServerConfig(s.uniqueTemporaryName(name), command)
	server.ID = newID("tmp")
	server.Port = port
	if env != nil {
		server.Env = env
	}
	server.HealthURL = healthURL
	server.HealthStatus = healthStatus
	server.AutoRestart = false
	project := Project{
		ID:      temporaryProjectID,
		Name:    "Temporary",
		Icon:    "clock.badge",
		Color:   temporaryProjectColor,
		Root:    dir,
		Servers: []ServerConfig{server},
	}
	rt := newRuntime(server, project, s.store.current())
	rt.configureTemporary(timeout)
	s.mu.Lock()
	s.wire(rt, true)
	s.runtimes[server.ID] = rt
	s.temporaryIDs = append(s.temporaryIDs, server.ID)
	s.mu.Unlock()
	rt.start()
	return rt
}

func (s *supervisor) runAction(action ServerAction, rt *serverRuntime, timeout int) *serverRuntime {
	rt.mu.Lock()
	env := map[string]string{}
	for k, v := range rt.config.Env {
		env[k] = v
	}
	env["PORTLY_SERVER"] = rt.config.Name
	if rt.config.Port != nil {
		env["PORT"] = itoa(*rt.config.Port)
	}
	dir := rt.workingDirectoryLocked()
	name := rt.config.Name + ": " + action.Name
	rt.mu.Unlock()
	return s.runTemporary(name, action.Command, dir, nil, env, nil, nil, timeout)
}

func (s *supervisor) uniqueTemporaryName(name string) string {
	base := strings.TrimSpace(name)
	if base == "" {
		base = "Temporary process"
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	existing := map[string]bool{}
	for _, id := range s.temporaryIDs {
		if rt := s.runtimes[id]; rt != nil {
			existing[strings.ToLower(rt.config.Name)] = true
		}
	}
	if !existing[strings.ToLower(base)] {
		return base
	}
	for n := 2; ; n++ {
		candidate := base + " " + itoa(n)
		if !existing[strings.ToLower(candidate)] {
			return candidate
		}
	}
}

func (s *supervisor) updateGlobalMemoryLimit(bytes *uint64) {
	s.guard.resetAll()
	s.store.mutate(func(cfg *PortlyConfig) { cfg.GlobalMemoryLimitBytes = bytes })
}

func (s *supervisor) updateProjectMemoryLimit(projectID string, mode MemoryLimitMode, bytes *uint64) {
	s.guard.reset(projectID)
	s.store.mutate(func(cfg *PortlyConfig) {
		for i := range cfg.Projects {
			if cfg.Projects[i].ID == projectID {
				cfg.Projects[i].MemoryLimitMode = mode
				if mode == MemoryCustom {
					cfg.Projects[i].MemoryLimitBytes = bytes
				} else {
					cfg.Projects[i].MemoryLimitBytes = nil
				}
				return
			}
		}
	})
}

func (s *supervisor) updateGlobalIdleTimeout(seconds *int) {
	s.store.mutate(func(cfg *PortlyConfig) {
		if seconds == nil || *seconds <= 0 {
			cfg.IdleTimeoutSeconds = nil
		} else {
			value := *seconds
			cfg.IdleTimeoutSeconds = &value
		}
	})
	s.mu.Lock()
	s.syncRuntimes()
	s.mu.Unlock()
}

func (s *supervisor) updateServerIdleTimeout(serverID string, seconds *int) {
	s.store.mutate(func(cfg *PortlyConfig) {
		for i := range cfg.Projects {
			for j := range cfg.Projects[i].Servers {
				if cfg.Projects[i].Servers[j].ID == serverID {
					cfg.Projects[i].Servers[j].IdleTimeoutSeconds = seconds
					return
				}
			}
		}
	})
	s.mu.Lock()
	s.syncRuntimes()
	s.mu.Unlock()
}

func (s *supervisor) serverConfiguredOn(port int, excluding string) *resolvedServer {
	cfg := s.store.current()
	for i := range cfg.Projects {
		for j := range cfg.Projects[i].Servers {
			srv := &cfg.Projects[i].Servers[j]
			if srv.Port != nil && *srv.Port == port && srv.ID != excluding {
				return &resolvedServer{Project: &cfg.Projects[i], Server: srv}
			}
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, id := range s.temporaryIDs {
		if id == excluding {
			continue
		}
		rt := s.runtimes[id]
		if rt != nil && rt.config.Port != nil && *rt.config.Port == port {
			p := &Project{ID: temporaryProjectID, Name: "Temporary", Root: rt.workingDirectory()}
			return &resolvedServer{Project: p, Server: &rt.config}
		}
	}
	return nil
}

func (s *supervisor) nextAvailablePort(start int, excluding string) int {
	if start < 1 {
		start = 1
	}
	for port := start; port <= 65535; port++ {
		if s.serverConfiguredOn(port, excluding) == nil && occupantOf(port) == nil {
			return port
		}
	}
	return start
}

func (s *supervisor) occupant(port int) *PortOccupant {
	found := occupantOf(port)
	if found == nil {
		return nil
	}
	s.mu.Lock()
	var owned *serverRuntime
	for _, rt := range s.runtimes {
		st := rt.status()
		if (st.PID != nil && *st.PID == found.PID) || (st.Port != nil && *st.Port == port && rt.isRunning()) {
			owned = rt
			break
		}
	}
	s.mu.Unlock()
	occ := &PortOccupant{
		Port:          port,
		PID:           found.PID,
		Command:       found.Command,
		User:          found.User,
		OwnedByPortly: owned != nil,
	}
	if owned != nil {
		id := owned.id
		occ.ServerID = &id
	}
	if container := dockerContainerPublishing(port); container != nil {
		occ.DockerContainerID = &container.ID
		occ.DockerContainerName = &container.Name
		if container.ComposeProject != "" {
			occ.DockerComposeProject = &container.ComposeProject
		}
		if container.ComposeService != "" {
			occ.DockerComposeService = &container.ComposeService
		}
	}
	return occ
}

func (s *supervisor) isTemporaryID(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, tid := range s.temporaryIDs {
		if tid == id {
			return true
		}
	}
	return false
}

func (s *supervisor) close() {
	s.store.stopWatching()
	select {
	case <-s.quit:
	default:
		close(s.quit)
	}
}

func nextColor(used []string) string {
	counts := map[string]int{}
	for _, hex := range used {
		counts[strings.ToUpper(hex)]++
	}
	best := palette[0]
	bestCount := int(^uint(0) >> 1)
	for _, hex := range palette {
		count := counts[strings.ToUpper(hex)]
		if count < bestCount {
			best = hex
			bestCount = count
			if count == 0 {
				break
			}
		}
	}
	return best
}

func itoa(n int) string {
	return strconv.Itoa(n)
}

func dirExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
