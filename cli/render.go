package main

import (
	"fmt"
	"strings"
	"time"
	"unicode/utf8"
)

type namedServer struct {
	name   string
	status ServerStatus
}

func namedServers(status PortlyStatus) []namedServer {
	var out []namedServer
	for _, project := range status.Projects {
		for _, server := range project.Servers {
			out = append(out, namedServer{name: project.Name + "/" + server.Name, status: server})
		}
	}
	for _, server := range status.TemporaryServers {
		out = append(out, namedServer{name: "Temporary/" + server.Name, status: server})
	}
	return out
}

func stateGlyph(s ServerStatus) string {
	if s.TimedOut != nil && *s.TimedOut {
		return "✕"
	}
	if s.Temporary != nil && *s.Temporary && s.FinishedAt != nil && s.LastExitCode != nil && *s.LastExitCode == 0 {
		return "✓"
	}
	switch s.State {
	case StateRunning:
		return "●"
	case StateStarting, StateRestarting:
		return "◐"
	case StateUnhealthy:
		return "◍"
	case StateFailed:
		return "✕"
	default:
		return "○"
	}
}

func renderCompact(status PortlyStatus) string {
	servers := namedServers(status)
	if len(servers) == 0 {
		return "No servers configured. Use 'portly temp' for one-off work, or add a project for long-lived services."
	}
	running, transitioning, problem, completed, stopped := 0, 0, 0, 0, 0
	var visible []namedServer
	for _, item := range servers {
		switch item.status.State {
		case StateRunning:
			running++
		case StateStarting, StateRestarting:
			transitioning++
		case StateUnhealthy, StateFailed:
			problem++
		}
		if item.status.Temporary != nil && *item.status.Temporary && item.status.FinishedAt != nil && item.status.LastExitCode != nil && *item.status.LastExitCode == 0 {
			completed++
		}
		if item.status.State == StateStopped && !(item.status.Temporary != nil && *item.status.Temporary && item.status.FinishedAt != nil) {
			stopped++
		}
		if item.status.State != StateStopped {
			visible = append(visible, item)
		}
	}
	parts := []string{fmt.Sprintf("%d running", running)}
	if transitioning > 0 {
		parts = append(parts, fmt.Sprintf("%d starting", transitioning))
	}
	noun := "problems"
	if problem == 1 {
		noun = "problem"
	}
	parts = append(parts, fmt.Sprintf("%d %s", problem, noun))
	if completed > 0 {
		parts = append(parts, fmt.Sprintf("%d completed", completed))
	}
	parts = append(parts, fmt.Sprintf("%d stopped", stopped))
	summary := strings.Join(parts, " · ")
	if len(visible) == 0 {
		return summary + "\n\nNo active servers."
	}
	width := 0
	for _, item := range visible {
		if n := utf8.RuneCountInString(item.name); n > width {
			width = n
		}
	}
	lines := make([]string, 0, len(visible))
	for _, item := range visible {
		lines = append(lines, compactLine(item, width))
	}
	return summary + "\n\n" + strings.Join(lines, "\n")
}

func compactLine(item namedServer, width int) string {
	name := item.name + strings.Repeat(" ", max(0, width-utf8.RuneCountInString(item.name)))
	port := "no port"
	if item.status.Port != nil {
		port = fmt.Sprintf(":%d", *item.status.Port)
	}
	switch item.status.State {
	case StateRunning:
		return fmt.Sprintf("%s %s  %s", stateGlyph(item.status), name, port)
	case StateStarting, StateRestarting:
		return fmt.Sprintf("%s %s  %s  %s", stateGlyph(item.status), name, port, item.status.State)
	case StateUnhealthy, StateFailed:
		err := ""
		if item.status.LastError != nil {
			normalized := strings.Join(strings.Fields(*item.status.LastError), " ")
			if len(normalized) > 100 {
				normalized = normalized[:97] + "…"
			}
			if normalized != "" {
				err = " — " + normalized
			}
		}
		return fmt.Sprintf("%s %s  %s  %s%s", stateGlyph(item.status), name, port, item.status.State, err)
	default:
		return fmt.Sprintf("%s %s  %s  stopped", stateGlyph(item.status), name, port)
	}
}

func renderDetailed(status PortlyStatus) string {
	if len(status.Projects) == 0 && len(status.TemporaryServers) == 0 {
		return "Nothing running yet. Use 'portly temp' for small one-off work, or add a project for long-lived services."
	}
	var out []string
	for _, project := range status.Projects {
		limit := "off"
		if project.EffectiveMemoryLimitBytes != nil {
			limit = displayMemorySize(*project.EffectiveMemoryLimitBytes)
		}
		source := string(project.MemoryLimitMode)
		if project.MemoryLimitMode == MemoryInherit {
			source = "global"
		}
		out = append(out, fmt.Sprintf("%s  (%s)  memory-limit:%s [%s]", project.Name, project.ID, limit, source))
		if project.LastMemoryRestartAt != nil && project.LastMemoryRestartBytes != nil {
			out = append(out, fmt.Sprintf("  ↻ memory guard restarted at %s using %s", project.LastMemoryRestartAt.Time.Format(time.RFC822), displayMemorySize(*project.LastMemoryRestartBytes)))
		}
		if len(project.Servers) == 0 {
			out = append(out, "  no servers")
		} else {
			for _, server := range project.Servers {
				out = append(out, detailedLine(server))
			}
		}
		out = append(out, "")
	}
	if len(status.TemporaryServers) > 0 {
		out = append(out, "Temporary")
		for _, server := range status.TemporaryServers {
			out = append(out, detailedLine(server))
		}
	}
	return strings.TrimSpace(strings.Join(out, "\n"))
}

func detailedLine(s ServerStatus) string {
	port := ""
	if s.Port != nil {
		port = fmt.Sprintf(":%d", *s.Port)
	}
	duration := ""
	if s.StartedAt != nil {
		end := time.Now()
		label := "up"
		if s.FinishedAt != nil {
			end = s.FinishedAt.Time
			label = "duration"
		}
		duration = fmt.Sprintf(" %s %ds", label, int(end.Sub(s.StartedAt.Time).Seconds()))
	}
	restarts := ""
	if s.RestartCount > 0 {
		restarts = fmt.Sprintf(" restarts:%d", s.RestartCount)
	}
	cpu := ""
	if s.CPUPercent != nil {
		cpu = fmt.Sprintf(" cpu:%.1f%%", *s.CPUPercent)
	}
	memory := ""
	if s.MemoryBytes != nil {
		memory = fmt.Sprintf(" footprint:%s", displayMemorySize(*s.MemoryBytes))
	}
	resident := ""
	if s.ResidentMemoryBytes != nil {
		resident = fmt.Sprintf(" resident:%s", displayMemorySize(*s.ResidentMemoryBytes))
	}
	processes := ""
	if s.ProcessCount != nil {
		processes = fmt.Sprintf(" processes:%d", *s.ProcessCount)
	}
	outcome := string(s.State)
	if s.TimedOut != nil && *s.TimedOut {
		outcome = "timed-out"
	} else if s.Temporary != nil && *s.Temporary && s.FinishedAt != nil && s.LastExitCode != nil && *s.LastExitCode == 0 {
		outcome = "succeeded"
	}
	timeout := ""
	if s.TimeoutSeconds != nil {
		timeout = " timeout:" + displayTimeout(*s.TimeoutSeconds)
	}
	exit := ""
	if s.LastExitCode != nil {
		exit = fmt.Sprintf(" exit:%d", *s.LastExitCode)
	}
	return fmt.Sprintf("  %s %s%s  %s%s%s%s%s%s%s%s%s%s", stateGlyph(s), s.Name, port, outcome, duration, timeout, exit, cpu, memory, resident, processes, restarts, idleSummary(s))
}

func idleSummary(s ServerStatus) string {
	if s.State == StateStopped && s.IdleStoppedAt != nil {
		return " idle-stopped:" + s.IdleStoppedAt.Time.Format("15:04")
	}
	if s.IdleTimeoutSeconds == nil {
		return ""
	}
	quiet := ""
	if s.LastActivityAt != nil {
		quiet = " quiet:" + displayTimeout(max(0, int(time.Since(s.LastActivityAt.Time).Seconds())))
	}
	return " idle-stop:" + displayTimeout(*s.IdleTimeoutSeconds) + quiet
}

func renderIdleTimeouts(status PortlyStatus) string {
	global := "off"
	if status.GlobalIdleTimeoutSeconds != nil {
		global = displayTimeout(*status.GlobalIdleTimeoutSeconds)
	}
	lines := []string{"Global: " + global}
	for _, project := range status.Projects {
		for _, server := range project.Servers {
			effective := "off"
			if server.IdleTimeoutSeconds != nil {
				effective = displayTimeout(*server.IdleTimeoutSeconds)
			}
			lines = append(lines, fmt.Sprintf("%s/%s: %s", project.Name, server.Name, effective))
		}
	}
	return strings.Join(lines, "\n")
}

func renderMemoryLimits(status PortlyStatus) string {
	global := "off"
	if status.GlobalMemoryLimitBytes != nil {
		global = displayMemorySize(*status.GlobalMemoryLimitBytes)
	}
	lines := []string{"Global: " + global}
	for _, project := range status.Projects {
		effective := "off"
		if project.EffectiveMemoryLimitBytes != nil {
			effective = displayMemorySize(*project.EffectiveMemoryLimitBytes)
		}
		policy := "inherit"
		switch project.MemoryLimitMode {
		case MemoryDisabled:
			policy = "off"
		case MemoryCustom:
			if project.MemoryLimitBytes != nil {
				policy = displayMemorySize(*project.MemoryLimitBytes)
			} else {
				policy = "invalid"
			}
		}
		lines = append(lines, fmt.Sprintf("%s: %s → %s", project.Name, policy, effective))
	}
	return strings.Join(lines, "\n")
}

func jobSummary(job TemporaryJobStatus) string {
	elapsed := "unknown duration"
	if sec := job.elapsedSeconds(); sec != nil {
		elapsed = fmt.Sprintf("%.1fs", *sec)
	}
	exit := ""
	if job.ExitCode != nil {
		exit = fmt.Sprintf(" · exit %d", *job.ExitCode)
	}
	switch job.State {
	case JobSucceeded:
		return fmt.Sprintf("✓ %s succeeded · %s%s", job.ID, elapsed, exit)
	case JobFailed:
		return fmt.Sprintf("✕ %s failed · %s%s", job.ID, elapsed, exit)
	case JobTimedOut:
		return fmt.Sprintf("✕ %s timed out after %s", job.ID, displayTimeout(job.TimeoutSeconds))
	case JobStopped:
		return fmt.Sprintf("○ %s stopped · %s", job.ID, elapsed)
	default:
		return fmt.Sprintf("◐ %s running", job.ID)
	}
}
