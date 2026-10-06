package main

import "strings"

type MemoryLimitMode string

const (
	MemoryInherit  MemoryLimitMode = "inherit"
	MemoryDisabled MemoryLimitMode = "disabled"
	MemoryCustom   MemoryLimitMode = "custom"
)

type ServerState string

const (
	StateStopped    ServerState = "stopped"
	StateStarting   ServerState = "starting"
	StateRunning    ServerState = "running"
	StateUnhealthy  ServerState = "unhealthy"
	StateRestarting ServerState = "restarting"
	StateFailed     ServerState = "failed"
)

func (s ServerState) isActive() bool {
	switch s {
	case StateStarting, StateRunning, StateUnhealthy, StateRestarting:
		return true
	default:
		return false
	}
}

type TemporaryJobState string

const (
	JobRunning   TemporaryJobState = "running"
	JobSucceeded TemporaryJobState = "succeeded"
	JobFailed    TemporaryJobState = "failed"
	JobTimedOut  TemporaryJobState = "timedOut"
	JobStopped   TemporaryJobState = "stopped"
)

func (s TemporaryJobState) isFinished() bool { return s != JobRunning }

type ServerAction struct {
	Name    string `json:"name"`
	Command string `json:"command"`
}

func (a ServerAction) ID() string { return a.Name }

type ServerConfig struct {
	ID           string            `json:"id"`
	Name         string            `json:"name"`
	Command      string            `json:"command"`
	Port         *int              `json:"port"`
	Directory    *string           `json:"directory"`
	Env          map[string]string `json:"env"`
	HealthURL    *string           `json:"healthURL"`
	HealthStatus *int              `json:"healthStatus"`
	AutoRestart  bool              `json:"autoRestart"`
	Actions      []ServerAction    `json:"actions"`
	// Nil inherits the global default, 0 turns idle stops off for this server.
	IdleTimeoutSeconds *int `json:"idleTimeoutSeconds,omitempty"`
}

func (s ServerConfig) effectiveIdleTimeout(global *int) *int {
	value := s.IdleTimeoutSeconds
	if value == nil {
		value = global
	}
	if value == nil || *value <= 0 {
		return nil
	}
	seconds := *value
	return &seconds
}

func newServerConfig(name, command string) ServerConfig {
	return ServerConfig{
		ID:          newID("srv"),
		Name:        name,
		Command:     command,
		Env:         map[string]string{},
		AutoRestart: true,
		Actions:     []ServerAction{},
	}
}

func (s *ServerConfig) UnmarshalJSON(data []byte) error {
	type raw ServerConfig
	aux := struct {
		raw
		AutoRestart *bool `json:"autoRestart"`
	}{
		raw: raw{
			Env:     map[string]string{},
			Actions: []ServerAction{},
		},
	}
	if err := decodeJSON(data, &aux); err != nil {
		return err
	}
	*s = ServerConfig(aux.raw)
	if s.ID == "" {
		s.ID = newID("srv")
	}
	if s.Env == nil {
		s.Env = map[string]string{}
	}
	if s.Actions == nil {
		s.Actions = []ServerAction{}
	}
	s.AutoRestart = true
	if aux.AutoRestart != nil {
		s.AutoRestart = *aux.AutoRestart
	}
	return nil
}

type Project struct {
	ID               string          `json:"id"`
	Name             string          `json:"name"`
	Icon             string          `json:"icon"`
	Color            string          `json:"color"`
	Root             string          `json:"root"`
	Servers          []ServerConfig  `json:"servers"`
	MemoryLimitMode  MemoryLimitMode `json:"memoryLimitMode"`
	MemoryLimitBytes *uint64         `json:"memoryLimitBytes"`
}

const defaultProjectIcon = "shippingbox.fill"

func newProject(name, root string) Project {
	return Project{
		ID:              newID("prj"),
		Name:            name,
		Icon:            defaultProjectIcon,
		Color:           "#8E8E93",
		Root:            root,
		Servers:         []ServerConfig{},
		MemoryLimitMode: MemoryInherit,
	}
}

func (p *Project) UnmarshalJSON(data []byte) error {
	type raw Project
	aux := raw{
		Icon:            defaultProjectIcon,
		Color:           "#8E8E93",
		Servers:         []ServerConfig{},
		MemoryLimitMode: MemoryInherit,
	}
	if err := decodeJSON(data, &aux); err != nil {
		return err
	}
	*p = Project(aux)
	if p.ID == "" {
		p.ID = newID("prj")
	}
	if p.Icon == "" {
		p.Icon = defaultProjectIcon
	}
	if p.Color == "" {
		p.Color = "#8E8E93"
	}
	if p.Servers == nil {
		p.Servers = []ServerConfig{}
	}
	if p.MemoryLimitMode == "" {
		p.MemoryLimitMode = MemoryInherit
	}
	return nil
}

func (p Project) effectiveMemoryLimit(global *uint64) *uint64 {
	switch p.MemoryLimitMode {
	case MemoryDisabled:
		return nil
	case MemoryCustom:
		return p.MemoryLimitBytes
	default:
		return global
	}
}

type PortlyConfig struct {
	Version                int       `json:"version"`
	APIPort                int       `json:"apiPort"`
	HealthIntervalSeconds  int       `json:"healthIntervalSeconds"`
	MaxRestartAttempts     int       `json:"maxRestartAttempts"`
	LogBufferLines         int       `json:"logBufferLines"`
	LogFileMaxMB           int       `json:"logFileMaxMB"`
	GlobalMemoryLimitBytes *uint64   `json:"globalMemoryLimitBytes,omitempty"`
	IdleTimeoutSeconds     *int      `json:"idleTimeoutSeconds,omitempty"`
	Projects               []Project `json:"projects"`
}

const defaultAPIPort = 7737

func defaultConfig() PortlyConfig {
	return PortlyConfig{
		Version:               1,
		APIPort:               defaultAPIPort,
		HealthIntervalSeconds: 10,
		MaxRestartAttempts:    5,
		LogBufferLines:        5000,
		LogFileMaxMB:          10,
		Projects:              []Project{},
	}
}

func (c *PortlyConfig) UnmarshalJSON(data []byte) error {
	type raw PortlyConfig
	aux := raw(defaultConfig())
	if err := decodeJSON(data, &aux); err != nil {
		return err
	}
	*c = PortlyConfig(aux)
	if c.APIPort == 0 {
		c.APIPort = defaultAPIPort
	}
	if c.HealthIntervalSeconds == 0 {
		c.HealthIntervalSeconds = 10
	}
	if c.MaxRestartAttempts == 0 {
		c.MaxRestartAttempts = 5
	}
	if c.LogBufferLines == 0 {
		c.LogBufferLines = 5000
	}
	if c.LogFileMaxMB == 0 {
		c.LogFileMaxMB = 10
	}
	if c.Projects == nil {
		c.Projects = []Project{}
	}
	return nil
}

func (c PortlyConfig) projectByID(id string) *Project {
	for i := range c.Projects {
		if c.Projects[i].ID == id {
			return &c.Projects[i]
		}
	}
	return nil
}

func (c PortlyConfig) resolveProject(query string) *Project {
	if p := c.projectByID(query); p != nil {
		return p
	}
	for i := range c.Projects {
		if strings.EqualFold(c.Projects[i].Name, query) {
			return &c.Projects[i]
		}
	}
	return nil
}

func (c PortlyConfig) resolveServer(query string) *resolvedServer {
	for i := range c.Projects {
		for j := range c.Projects[i].Servers {
			if c.Projects[i].Servers[j].ID == query {
				return &resolvedServer{Project: &c.Projects[i], Server: &c.Projects[i].Servers[j]}
			}
		}
	}
	parts := strings.SplitN(query, "/", 2)
	if len(parts) == 2 {
		p := c.resolveProject(parts[0])
		if p == nil {
			return nil
		}
		for j := range p.Servers {
			if strings.EqualFold(p.Servers[j].Name, parts[1]) {
				return &resolvedServer{Project: p, Server: &p.Servers[j]}
			}
		}
		return nil
	}
	for i := range c.Projects {
		for j := range c.Projects[i].Servers {
			if strings.EqualFold(c.Projects[i].Servers[j].Name, query) {
				return &resolvedServer{Project: &c.Projects[i], Server: &c.Projects[i].Servers[j]}
			}
		}
	}
	return nil
}

type resolvedServer struct {
	Project *Project
	Server  *ServerConfig
}

type TemporaryJobStatus struct {
	ID             string            `json:"id"`
	Name           string            `json:"name"`
	Command        string            `json:"command"`
	Directory      string            `json:"directory"`
	State          TemporaryJobState `json:"state"`
	PID            *int              `json:"pid"`
	StartedAt      *isoTime          `json:"startedAt"`
	FinishedAt     *isoTime          `json:"finishedAt"`
	TimeoutSeconds int               `json:"timeoutSeconds"`
	Deadline       *isoTime          `json:"deadline"`
	ExitCode       *int              `json:"exitCode"`
	Error          *string           `json:"error"`
}

func (j TemporaryJobStatus) processExitCode() int {
	switch j.State {
	case JobSucceeded:
		return 0
	case JobTimedOut:
		return 124
	case JobStopped:
		return 130
	case JobFailed:
		if j.ExitCode != nil && *j.ExitCode != 0 {
			return *j.ExitCode
		}
		return 1
	default:
		return 0
	}
}

func (j TemporaryJobStatus) elapsedSeconds() *float64 {
	if j.StartedAt == nil {
		return nil
	}
	end := nowTime()
	if j.FinishedAt != nil {
		end = j.FinishedAt.Time
	}
	sec := end.Sub(j.StartedAt.Time).Seconds()
	return &sec
}

type ServerStatus struct {
	ID                  string      `json:"id"`
	Name                string      `json:"name"`
	ProjectID           string      `json:"projectID"`
	ProjectName         string      `json:"projectName"`
	Command             string      `json:"command"`
	Port                *int        `json:"port"`
	Directory           string      `json:"directory"`
	State               ServerState `json:"state"`
	PID                 *int        `json:"pid"`
	StartedAt           *isoTime    `json:"startedAt"`
	RestartCount        int         `json:"restartCount"`
	LastExitCode        *int        `json:"lastExitCode"`
	LastError           *string     `json:"lastError"`
	Healthy             bool        `json:"healthy"`
	URL                 *string     `json:"url"`
	CPUPercent          *float64    `json:"cpuPercent,omitempty"`
	MemoryBytes         *uint64     `json:"memoryBytes,omitempty"`
	ResidentMemoryBytes *uint64     `json:"residentMemoryBytes,omitempty"`
	ProcessCount        *int        `json:"processCount,omitempty"`
	Temporary           *bool       `json:"temporary,omitempty"`
	TimeoutSeconds      *int        `json:"timeoutSeconds,omitempty"`
	Deadline            *isoTime    `json:"deadline,omitempty"`
	FinishedAt          *isoTime    `json:"finishedAt,omitempty"`
	TimedOut            *bool       `json:"timedOut,omitempty"`
	IdleTimeoutSeconds  *int        `json:"idleTimeoutSeconds,omitempty"`
	LastActivityAt      *isoTime    `json:"lastActivityAt,omitempty"`
	IdleStoppedAt       *isoTime    `json:"idleStoppedAt,omitempty"`
}

type ProjectStatus struct {
	ID                        string          `json:"id"`
	Name                      string          `json:"name"`
	Icon                      string          `json:"icon"`
	Color                     string          `json:"color"`
	Root                      string          `json:"root"`
	Servers                   []ServerStatus  `json:"servers"`
	MemoryLimitMode           MemoryLimitMode `json:"memoryLimitMode"`
	MemoryLimitBytes          *uint64         `json:"memoryLimitBytes,omitempty"`
	EffectiveMemoryLimitBytes *uint64         `json:"effectiveMemoryLimitBytes,omitempty"`
	LastMemoryRestartAt       *isoTime        `json:"lastMemoryRestartAt,omitempty"`
	LastMemoryRestartBytes    *uint64         `json:"lastMemoryRestartBytes,omitempty"`
}

type PortlyStatus struct {
	Version                  string          `json:"version"`
	APIPort                  int             `json:"apiPort"`
	GlobalMemoryLimitBytes   *uint64         `json:"globalMemoryLimitBytes,omitempty"`
	GlobalIdleTimeoutSeconds *int            `json:"globalIdleTimeoutSeconds,omitempty"`
	Projects                 []ProjectStatus `json:"projects"`
	TemporaryServers         []ServerStatus  `json:"temporaryServers"`
}

type PortOccupant struct {
	Port                 int     `json:"port"`
	PID                  int     `json:"pid"`
	Command              string  `json:"command"`
	User                 string  `json:"user"`
	OwnedByPortly        bool    `json:"ownedByPortly"`
	ServerID             *string `json:"serverID"`
	DockerContainerID    *string `json:"dockerContainerID,omitempty"`
	DockerContainerName  *string `json:"dockerContainerName,omitempty"`
	DockerComposeProject *string `json:"dockerComposeProject,omitempty"`
	DockerComposeService *string `json:"dockerComposeService,omitempty"`
}

type envelope struct {
	OK    bool    `json:"ok"`
	Data  any     `json:"data"`
	Error *string `json:"error"`
}

type actionResponse struct {
	Affected []string `json:"affected"`
	Message  string   `json:"message"`
}

type targetRequest struct {
	Server  *string `json:"server"`
	Project *string `json:"project"`
}

type addProjectRequest struct {
	Name             string           `json:"name"`
	Root             string           `json:"root"`
	Icon             *string          `json:"icon"`
	Color            *string          `json:"color"`
	MemoryLimitMode  *MemoryLimitMode `json:"memoryLimitMode"`
	MemoryLimitBytes *uint64          `json:"memoryLimitBytes"`
}

type addServerRequest struct {
	Project            string            `json:"project"`
	Name               string            `json:"name"`
	Command            string            `json:"command"`
	Port               *int              `json:"port"`
	Directory          *string           `json:"directory"`
	Env                map[string]string `json:"env"`
	HealthURL          *string           `json:"healthURL"`
	HealthStatus       *int              `json:"healthStatus"`
	AutoRestart        *bool             `json:"autoRestart"`
	Actions            []ServerAction    `json:"actions"`
	IdleTimeoutSeconds *int              `json:"idleTimeoutSeconds"`
	Start              *bool             `json:"start"`
}

type updateServerRequest struct {
	Server       string            `json:"server"`
	Name         *string           `json:"name"`
	Command      *string           `json:"command"`
	Port         *int              `json:"port"`
	Directory    *string           `json:"directory"`
	Env          map[string]string `json:"env"`
	HealthURL    *string           `json:"healthURL"`
	HealthStatus *int              `json:"healthStatus"`
	AutoRestart  *bool             `json:"autoRestart"`
	Actions      []ServerAction    `json:"actions"`
}

type runTemporaryRequest struct {
	Name           string            `json:"name"`
	Command        string            `json:"command"`
	Directory      string            `json:"directory"`
	Port           *int              `json:"port"`
	Env            map[string]string `json:"env"`
	HealthURL      *string           `json:"healthURL"`
	HealthStatus   *int              `json:"healthStatus"`
	TimeoutSeconds *int              `json:"timeoutSeconds"`
}

type runActionRequest struct {
	Server         string `json:"server"`
	Action         string `json:"action"`
	TimeoutSeconds *int   `json:"timeoutSeconds"`
}

type removeRequest struct {
	Server  *string `json:"server"`
	Project *string `json:"project"`
}

type takeOverRequest struct {
	Server string `json:"server"`
}

type killPortRequest struct {
	Port int `json:"port"`
}

type updateMemoryLimitRequest struct {
	Project *string         `json:"project"`
	Mode    MemoryLimitMode `json:"mode"`
	Bytes   *uint64         `json:"bytes"`
}

// Seconds 0 turns idle stops off. A nil Seconds is only valid with Server and inherits.
type updateIdleTimeoutRequest struct {
	Server  *string `json:"server,omitempty"`
	Seconds *int    `json:"seconds,omitempty"`
}

type openRequest struct {
	Destination *string `json:"destination"`
}

type logsResponse struct {
	Server string   `json:"server"`
	Lines  []string `json:"lines"`
}

type portQueryResponse struct {
	Port     int           `json:"port"`
	Occupant *PortOccupant `json:"occupant"`
}
