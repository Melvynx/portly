package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

type apiServer struct {
	sup      *supervisor
	listener net.Listener
	http     *http.Server
	port     int
}

func startAPI(sup *supervisor, port int) (*apiServer, error) {
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	actual := ln.Addr().(*net.TCPAddr).Port
	sup.apiPort = actual
	srv := &apiServer{sup: sup, listener: ln, port: actual}
	mux := http.NewServeMux()
	mux.HandleFunc("/ping", srv.get(srv.ping))
	mux.HandleFunc("/status", srv.get(srv.status))
	mux.HandleFunc("/config", srv.get(srv.config))
	mux.HandleFunc("/logs", srv.get(srv.logs))
	mux.HandleFunc("/temporary/status", srv.get(srv.temporaryStatus))
	mux.HandleFunc("/ports", srv.get(srv.ports))
	mux.HandleFunc("/start", srv.post(srv.start))
	mux.HandleFunc("/stop", srv.post(srv.stop))
	mux.HandleFunc("/restart", srv.post(srv.restart))
	mux.HandleFunc("/projects/add", srv.post(srv.addProject))
	mux.HandleFunc("/projects/remove", srv.post(srv.removeProject))
	mux.HandleFunc("/servers/add", srv.post(srv.addServer))
	mux.HandleFunc("/servers/update", srv.post(srv.updateServer))
	mux.HandleFunc("/servers/remove", srv.post(srv.removeServer))
	mux.HandleFunc("/servers/take-over", srv.post(srv.takeOver))
	mux.HandleFunc("/temporary/run", srv.post(srv.runTemporary))
	mux.HandleFunc("/actions/run", srv.post(srv.runAction))
	mux.HandleFunc("/memory-limit", srv.post(srv.memoryLimit))
	mux.HandleFunc("/idle-timeout", srv.post(srv.idleTimeout))
	mux.HandleFunc("/ports/kill", srv.post(srv.killPort))
	mux.HandleFunc("/open", srv.post(srv.open))
	mux.HandleFunc("/quit", srv.post(srv.quit))
	srv.http = &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = srv.http.Serve(ln) }()
	return srv, nil
}

func (s *apiServer) close() {
	_ = s.http.Close()
	_ = s.listener.Close()
}

func (s *apiServer) get(fn http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeFail(w, http.StatusNotFound, "Unknown endpoint "+r.Method+" "+r.URL.Path)
			return
		}
		fn(w, r)
	}
}

func (s *apiServer) post(fn http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeFail(w, http.StatusNotFound, "Unknown endpoint "+r.Method+" "+r.URL.Path)
			return
		}
		fn(w, r)
	}
}

func (s *apiServer) ping(w http.ResponseWriter, _ *http.Request) {
	writeOK(w, map[string]string{"pong": portlyVersion})
}

func (s *apiServer) status(w http.ResponseWriter, _ *http.Request) {
	writeOK(w, s.sup.status())
}

func (s *apiServer) config(w http.ResponseWriter, _ *http.Request) {
	writeOK(w, s.sup.settings())
}

func (s *apiServer) logs(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("server")
	tail, _ := strconv.Atoi(r.URL.Query().Get("tail"))
	if tail == 0 {
		tail = 200
	}
	rt := s.sup.resolveRuntime(query)
	if rt == nil {
		writeFail(w, http.StatusNotFound, "No server matching '"+query+"'")
		return
	}
	writeOK(w, logsResponse{Server: rt.config.Name, Lines: rt.logTail(tail)})
}

func (s *apiServer) temporaryStatus(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	if !s.sup.isTemporaryID(id) {
		writeFail(w, http.StatusNotFound, "No temporary job matching '"+id+"'")
		return
	}
	rt := s.sup.runtimeByID(id)
	if rt == nil || rt.jobStatus() == nil {
		writeFail(w, http.StatusNotFound, "No temporary job matching '"+id+"'")
		return
	}
	writeOK(w, rt.jobStatus())
}

func (s *apiServer) ports(w http.ResponseWriter, r *http.Request) {
	raw := r.URL.Query().Get("port")
	port, err := strconv.Atoi(raw)
	if err != nil {
		writeFail(w, http.StatusBadRequest, "Missing ?port=")
		return
	}
	writeOK(w, portQueryResponse{Port: port, Occupant: s.sup.occupant(port)})
}

func (s *apiServer) start(w http.ResponseWriter, r *http.Request)   { s.act(w, r, "start") }
func (s *apiServer) stop(w http.ResponseWriter, r *http.Request)    { s.act(w, r, "stop") }
func (s *apiServer) restart(w http.ResponseWriter, r *http.Request) { s.act(w, r, "restart") }

func (s *apiServer) act(w http.ResponseWriter, r *http.Request, verb string) {
	var body targetRequest
	if err := decodeBody(r, &body); err != nil {
		writeFail(w, http.StatusBadRequest, err.Error())
		return
	}
	if body.Server != nil {
		rt := s.sup.resolveRuntime(*body.Server)
		if rt == nil {
			writeFail(w, http.StatusNotFound, "No server matching '"+*body.Server+"'")
			return
		}
		applyVerb(verb, rt)
		writeOK(w, actionResponse{Affected: []string{rt.id}, Message: verb + " " + rt.config.Name})
		return
	}
	if body.Project != nil {
		project := s.sup.resolveProject(*body.Project)
		if project == nil {
			writeFail(w, http.StatusNotFound, "No project matching '"+*body.Project+"'")
			return
		}
		runtimes := s.sup.runtimesInProject(project.ID)
		ids := make([]string, 0, len(runtimes))
		for _, rt := range runtimes {
			applyVerb(verb, rt)
			ids = append(ids, rt.id)
		}
		writeOK(w, actionResponse{Affected: ids, Message: fmt.Sprintf("%s %d server(s) in %s", verb, len(runtimes), project.Name)})
		return
	}
	all := s.sup.allRuntimes()
	ids := make([]string, 0, len(all))
	for _, rt := range all {
		applyVerb(verb, rt)
		ids = append(ids, rt.id)
	}
	writeOK(w, actionResponse{Affected: ids, Message: verb + " all servers"})
}

func applyVerb(verb string, rt *serverRuntime) {
	switch verb {
	case "start":
		rt.start()
	case "stop":
		rt.stop(nil)
	case "restart":
		rt.restart()
	}
}

func (s *apiServer) addProject(w http.ResponseWriter, r *http.Request) {
	var body addProjectRequest
	if err := decodeBody(r, &body); err != nil {
		writeFail(w, http.StatusBadRequest, err.Error())
		return
	}
	root := expandPath(body.Root)
	if !dirExists(root) {
		writeFail(w, http.StatusBadRequest, "Directory does not exist: "+root)
		return
	}
	if s.sup.resolveProject(body.Name) != nil {
		writeFail(w, http.StatusBadRequest, "A project named '"+body.Name+"' already exists")
		return
	}
	mode := MemoryInherit
	if body.MemoryLimitMode != nil {
		mode = *body.MemoryLimitMode
	}
	if mode == MemoryCustom && !validMemoryLimit(body.MemoryLimitBytes) {
		writeFail(w, http.StatusBadRequest, "Custom memory limit must be between 128 MB and 1 TB")
		return
	}
	project := s.sup.addProject(body.Name, root, body.Icon, body.Color, mode, body.MemoryLimitBytes)
	writeOK(w, project)
}

func (s *apiServer) removeProject(w http.ResponseWriter, r *http.Request) {
	var body removeRequest
	if err := decodeBody(r, &body); err != nil {
		writeFail(w, http.StatusBadRequest, err.Error())
		return
	}
	if body.Project == nil {
		writeFail(w, http.StatusNotFound, "No project matching ''")
		return
	}
	project := s.sup.resolveProject(*body.Project)
	if project == nil {
		writeFail(w, http.StatusNotFound, "No project matching '"+*body.Project+"'")
		return
	}
	id, name := project.ID, project.Name
	s.sup.removeProject(id)
	writeOK(w, actionResponse{Affected: []string{id}, Message: "Removed project " + name})
}

func (s *apiServer) addServer(w http.ResponseWriter, r *http.Request) {
	var body addServerRequest
	if err := decodeBody(r, &body); err != nil {
		writeFail(w, http.StatusBadRequest, err.Error())
		return
	}
	project := s.sup.resolveProject(body.Project)
	if project == nil {
		writeFail(w, http.StatusNotFound, "No project matching '"+body.Project+"'")
		return
	}
	for _, srv := range project.Servers {
		if strings.EqualFold(srv.Name, body.Name) {
			writeFail(w, http.StatusBadRequest, project.Name+" already has a server named '"+body.Name+"'")
			return
		}
	}
	if body.Port != nil {
		if conflict := s.sup.serverConfiguredOn(*body.Port, ""); conflict != nil {
			next := s.sup.nextAvailablePort(3000, "")
			writeFail(w, http.StatusBadRequest, fmt.Sprintf("Port %d is already configured for %s/%s. Try %d.", *body.Port, conflict.Project.Name, conflict.Server.Name, next))
			return
		}
	}
	if !validActions(body.Actions) {
		writeFail(w, http.StatusBadRequest, "Actions need unique non-empty names and non-empty commands")
		return
	}
	if body.IdleTimeoutSeconds != nil && !validIdleTimeout(*body.IdleTimeoutSeconds) {
		writeFail(w, http.StatusBadRequest, idleTimeoutRangeMessage)
		return
	}
	server := newServerConfig(body.Name, body.Command)
	server.IdleTimeoutSeconds = body.IdleTimeoutSeconds
	server.Port = body.Port
	server.Directory = body.Directory
	if body.Env != nil {
		server.Env = body.Env
	}
	server.HealthURL = body.HealthURL
	server.HealthStatus = body.HealthStatus
	if body.AutoRestart != nil {
		server.AutoRestart = *body.AutoRestart
	}
	if body.Actions != nil {
		server.Actions = body.Actions
	}
	s.sup.addServer(project.ID, server)
	if body.Start != nil && *body.Start {
		s.sup.start(server.ID)
	}
	writeOK(w, server)
}

func (s *apiServer) updateServer(w http.ResponseWriter, r *http.Request) {
	var body updateServerRequest
	if err := decodeBody(r, &body); err != nil {
		writeFail(w, http.StatusBadRequest, err.Error())
		return
	}
	rt := s.sup.resolveRuntime(body.Server)
	if rt == nil {
		writeFail(w, http.StatusNotFound, "No server matching '"+body.Server+"'")
		return
	}
	cfg := rt.config
	if body.Name != nil {
		cfg.Name = *body.Name
	}
	if body.Command != nil {
		cfg.Command = *body.Command
	}
	if body.Port != nil {
		cfg.Port = body.Port
	}
	if body.Directory != nil {
		cfg.Directory = body.Directory
	}
	if body.Env != nil {
		cfg.Env = body.Env
	}
	if body.HealthURL != nil {
		cfg.HealthURL = body.HealthURL
	}
	if body.HealthStatus != nil {
		cfg.HealthStatus = body.HealthStatus
	}
	if body.AutoRestart != nil {
		cfg.AutoRestart = *body.AutoRestart
	}
	if body.Actions != nil {
		cfg.Actions = body.Actions
	}
	if !validActions(cfg.Actions) {
		writeFail(w, http.StatusBadRequest, "Actions need unique non-empty names and non-empty commands")
		return
	}
	if cfg.Port != nil {
		if conflict := s.sup.serverConfiguredOn(*cfg.Port, cfg.ID); conflict != nil {
			next := s.sup.nextAvailablePort(3000, cfg.ID)
			writeFail(w, http.StatusBadRequest, fmt.Sprintf("Port %d is already configured for %s/%s. Try %d.", *cfg.Port, conflict.Project.Name, conflict.Server.Name, next))
			return
		}
	}
	s.sup.updateServer(cfg)
	writeOK(w, cfg)
}

func (s *apiServer) removeServer(w http.ResponseWriter, r *http.Request) {
	var body removeRequest
	if err := decodeBody(r, &body); err != nil {
		writeFail(w, http.StatusBadRequest, err.Error())
		return
	}
	if body.Server == nil {
		writeFail(w, http.StatusNotFound, "No server matching ''")
		return
	}
	rt := s.sup.resolveRuntime(*body.Server)
	if rt == nil {
		writeFail(w, http.StatusNotFound, "No server matching '"+*body.Server+"'")
		return
	}
	id, name := rt.id, rt.config.Name
	s.sup.removeServer(id)
	writeOK(w, actionResponse{Affected: []string{id}, Message: "Removed server " + name})
}

func (s *apiServer) takeOver(w http.ResponseWriter, r *http.Request) {
	var body takeOverRequest
	if err := decodeBody(r, &body); err != nil {
		writeFail(w, http.StatusBadRequest, err.Error())
		return
	}
	rt := s.sup.resolveRuntime(body.Server)
	if rt == nil {
		writeFail(w, http.StatusNotFound, "No server matching '"+body.Server+"'")
		return
	}
	if !rt.takeOverPort() {
		writeFail(w, http.StatusBadRequest, "The configured port is free, already managed, or could not be stopped")
		return
	}
	port := ""
	if rt.config.Port != nil {
		port = strconv.Itoa(*rt.config.Port)
	}
	writeOK(w, actionResponse{Affected: []string{rt.id}, Message: "Moving port " + port + " to Portly"})
}

func (s *apiServer) runTemporary(w http.ResponseWriter, r *http.Request) {
	var body runTemporaryRequest
	if err := decodeBody(r, &body); err != nil {
		writeFail(w, http.StatusBadRequest, err.Error())
		return
	}
	name := strings.TrimSpace(body.Name)
	command := strings.TrimSpace(body.Command)
	directory := expandPath(body.Directory)
	timeout := defaultTimeoutSeconds
	if body.TimeoutSeconds != nil {
		timeout = *body.TimeoutSeconds
	}
	if name == "" {
		writeFail(w, http.StatusBadRequest, "Temporary process name cannot be empty")
		return
	}
	if command == "" {
		writeFail(w, http.StatusBadRequest, "Temporary command cannot be empty")
		return
	}
	if timeout < 1 || timeout > maximumTimeoutSeconds {
		writeFail(w, http.StatusBadRequest, "Timeout must be between 1 second and 7 days")
		return
	}
	if !dirExists(directory) {
		writeFail(w, http.StatusBadRequest, "Directory does not exist: "+directory)
		return
	}
	if body.Port != nil {
		if conflict := s.sup.serverConfiguredOn(*body.Port, ""); conflict != nil {
			next := s.sup.nextAvailablePort(*body.Port+1, "")
			writeFail(w, http.StatusBadRequest, fmt.Sprintf("Port %d is configured for %s/%s. Try %d.", *body.Port, conflict.Project.Name, conflict.Server.Name, next))
			return
		}
		if occ := s.sup.occupant(*body.Port); occ != nil {
			writeFail(w, http.StatusBadRequest, fmt.Sprintf("Port %d is already used by %s (pid %d)", *body.Port, occ.Command, occ.PID))
			return
		}
	}
	rt := s.sup.runTemporary(name, command, directory, body.Port, body.Env, body.HealthURL, body.HealthStatus, timeout)
	job := rt.jobStatus()
	if job == nil {
		writeFail(w, http.StatusInternalServerError, "Temporary job metadata was not created")
		return
	}
	writeOK(w, job)
}

func (s *apiServer) runAction(w http.ResponseWriter, r *http.Request) {
	var body runActionRequest
	if err := decodeBody(r, &body); err != nil {
		writeFail(w, http.StatusBadRequest, err.Error())
		return
	}
	rt := s.sup.resolveRuntime(body.Server)
	if rt == nil || s.sup.isTemporaryID(rt.id) {
		writeFail(w, http.StatusNotFound, "No configured server matching '"+body.Server+"'")
		return
	}
	var action *ServerAction
	for i := range rt.config.Actions {
		if strings.EqualFold(rt.config.Actions[i].Name, body.Action) {
			action = &rt.config.Actions[i]
			break
		}
	}
	if action == nil {
		writeFail(w, http.StatusNotFound, "No action named '"+body.Action+"' on "+rt.projectName+"/"+rt.config.Name)
		return
	}
	timeout := defaultTimeoutSeconds
	if body.TimeoutSeconds != nil {
		timeout = *body.TimeoutSeconds
	}
	if timeout < 1 || timeout > maximumTimeoutSeconds {
		writeFail(w, http.StatusBadRequest, "Timeout must be between 1 second and 7 days")
		return
	}
	jobRT := s.sup.runAction(*action, rt, timeout)
	job := jobRT.jobStatus()
	if job == nil {
		writeFail(w, http.StatusInternalServerError, "Action job metadata was not created")
		return
	}
	writeOK(w, job)
}

func (s *apiServer) memoryLimit(w http.ResponseWriter, r *http.Request) {
	var body updateMemoryLimitRequest
	if err := decodeBody(r, &body); err != nil {
		writeFail(w, http.StatusBadRequest, err.Error())
		return
	}
	if body.Project != nil {
		project := s.sup.resolveProject(*body.Project)
		if project == nil {
			writeFail(w, http.StatusNotFound, "No project matching '"+*body.Project+"'")
			return
		}
		if body.Mode == MemoryCustom && !validMemoryLimit(body.Bytes) {
			writeFail(w, http.StatusBadRequest, "Custom memory limit must be between 128 MB and 1 TB")
			return
		}
		s.sup.updateProjectMemoryLimit(project.ID, body.Mode, body.Bytes)
		value := string(body.Mode)
		if body.Mode == MemoryCustom {
			value = displayMemorySize(*body.Bytes)
		}
		writeOK(w, actionResponse{Affected: []string{project.ID}, Message: "Memory limit for " + project.Name + ": " + value})
		return
	}
	if body.Mode == MemoryInherit {
		writeFail(w, http.StatusBadRequest, "The global memory limit can be a size or off, not inherit")
		return
	}
	if body.Mode == MemoryCustom && !validMemoryLimit(body.Bytes) {
		writeFail(w, http.StatusBadRequest, "Global memory limit must be between 128 MB and 1 TB")
		return
	}
	var bytes *uint64
	if body.Mode == MemoryCustom {
		bytes = body.Bytes
	}
	s.sup.updateGlobalMemoryLimit(bytes)
	value := "off"
	if body.Mode == MemoryCustom {
		value = displayMemorySize(*body.Bytes)
	}
	writeOK(w, actionResponse{Affected: []string{}, Message: "Global project memory limit: " + value})
}

const idleTimeoutRangeMessage = "Idle timeout must be 0 (off) or between 1 minute and 7 days"

func (s *apiServer) idleTimeout(w http.ResponseWriter, r *http.Request) {
	var body updateIdleTimeoutRequest
	if err := decodeBody(r, &body); err != nil {
		writeFail(w, http.StatusBadRequest, err.Error())
		return
	}
	if body.Seconds != nil && !validIdleTimeout(*body.Seconds) {
		writeFail(w, http.StatusBadRequest, idleTimeoutRangeMessage)
		return
	}
	value := "inherit"
	if body.Seconds != nil {
		value = "off"
		if *body.Seconds > 0 {
			value = describeIdleTimeout(*body.Seconds)
		}
	}
	if body.Server != nil {
		rt := s.sup.resolveRuntime(*body.Server)
		if rt == nil || rt.isTemporary() {
			writeFail(w, http.StatusNotFound, "No configured server matching '"+*body.Server+"'")
			return
		}
		st := rt.status()
		s.sup.updateServerIdleTimeout(rt.id, body.Seconds)
		writeOK(w, actionResponse{Affected: []string{rt.id}, Message: "Idle timeout for " + st.ProjectName + "/" + st.Name + ": " + value})
		return
	}
	if body.Seconds == nil {
		writeFail(w, http.StatusBadRequest, "The global idle timeout can be a duration or off, not inherit")
		return
	}
	s.sup.updateGlobalIdleTimeout(body.Seconds)
	writeOK(w, actionResponse{Affected: []string{}, Message: "Global idle timeout: " + value})
}

func (s *apiServer) killPort(w http.ResponseWriter, r *http.Request) {
	var body killPortRequest
	if err := decodeBody(r, &body); err != nil {
		writeFail(w, http.StatusBadRequest, err.Error())
		return
	}
	occ := s.sup.occupant(body.Port)
	if occ == nil {
		writeFail(w, http.StatusNotFound, fmt.Sprintf("Nothing is listening on port %d", body.Port))
		return
	}
	expected := occ.PID
	outcome, err := stopOccupant(body.Port, &expected)
	if err != nil {
		writeFail(w, http.StatusBadRequest, err.Error())
		return
	}
	affected := []string{strconv.Itoa(occ.PID)}
	if outcome.DockerContainer != nil {
		affected = []string{outcome.DockerContainer.ID}
	}
	writeOK(w, actionResponse{Affected: affected, Message: fmt.Sprintf("Stopped %s on port %d", outcome.Description, body.Port)})
}

func (s *apiServer) open(w http.ResponseWriter, r *http.Request) {
	var body openRequest
	_ = decodeBody(r, &body)
	writeOK(w, actionResponse{Affected: []string{}, Message: "No UI on this host. Portly is running as a headless daemon."})
}

func (s *apiServer) quit(w http.ResponseWriter, _ *http.Request) {
	writeOK(w, actionResponse{Affected: []string{}, Message: "Quitting Portly"})
	go func() {
		time.Sleep(200 * time.Millisecond)
		s.sup.terminateEverything()
		s.sup.close()
		osExit(0)
	}()
}

func validActions(actions []ServerAction) bool {
	seen := map[string]bool{}
	for _, action := range actions {
		name := strings.TrimSpace(action.Name)
		command := strings.TrimSpace(action.Command)
		if name == "" || command == "" || seen[strings.ToLower(name)] {
			return false
		}
		seen[strings.ToLower(name)] = true
	}
	return true
}

func decodeBody(r *http.Request, dest any) error {
	data, err := io.ReadAll(r.Body)
	if err != nil {
		return fmt.Errorf("Missing JSON body")
	}
	if len(strings.TrimSpace(string(data))) == 0 {
		return fmt.Errorf("Missing JSON body")
	}
	if err := json.Unmarshal(data, dest); err != nil {
		return fmt.Errorf("Invalid JSON body: %s", err.Error())
	}
	return nil
}

func writeOK(w http.ResponseWriter, data any) {
	writeEnvelope(w, http.StatusOK, envelope{OK: true, Data: data})
}

func writeFail(w http.ResponseWriter, status int, message string) {
	writeEnvelope(w, status, envelope{OK: false, Error: &message})
}

func writeEnvelope(w http.ResponseWriter, status int, env envelope) {
	body, err := encodeJSON(env)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

var osExit = func(code int) { os.Exit(code) }

type quitCode int
