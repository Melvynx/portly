package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type dockerContainer struct {
	ID             string
	Name           string
	ComposeProject string
	ComposeService string
}

func (c dockerContainer) displayName() string {
	if c.ComposeProject != "" && c.ComposeService != "" {
		return c.ComposeProject + " / " + c.ComposeService
	}
	return c.Name
}

func dockerExecutable() string {
	home, _ := os.UserHomeDir()
	candidates := []string{
		"docker",
		"/usr/bin/docker",
		"/usr/local/bin/docker",
		"/opt/homebrew/bin/docker",
		filepath.Join(home, ".docker", "bin", "docker"),
	}
	for _, candidate := range candidates {
		if candidate == "docker" {
			if path, err := exec.LookPath("docker"); err == nil {
				return path
			}
			continue
		}
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return candidate
		}
	}
	return ""
}

func dockerContainerPublishing(port int) *dockerContainer {
	exe := dockerExecutable()
	if exe == "" {
		return nil
	}
	listed, err := hiddenCommand(exe, "ps", "--filter", fmt.Sprintf("publish=%d", port), "--format", "{{.ID}}").Output()
	if err != nil {
		return nil
	}
	ids := strings.Fields(string(listed))
	if len(ids) == 0 {
		return nil
	}
	args := append([]string{"inspect"}, ids...)
	inspected, err := hiddenCommand(exe, args...).Output()
	if err != nil {
		return nil
	}
	return parseDockerInspect(inspected, port)
}

func parseDockerInspect(data []byte, port int) *dockerContainer {
	var containers []struct {
		ID     string `json:"Id"`
		Name   string `json:"Name"`
		Config struct {
			Labels map[string]string `json:"Labels"`
		} `json:"Config"`
		NetworkSettings struct {
			Ports map[string][]struct {
				HostPort string `json:"HostPort"`
			} `json:"Ports"`
		} `json:"NetworkSettings"`
	}
	if err := json.Unmarshal(data, &containers); err != nil {
		return nil
	}
	want := fmt.Sprintf("%d", port)
	for _, container := range containers {
		publishes := false
		for _, bindings := range container.NetworkSettings.Ports {
			for _, binding := range bindings {
				if binding.HostPort == want {
					publishes = true
				}
			}
		}
		if !publishes {
			continue
		}
		name := strings.TrimPrefix(container.Name, "/")
		labels := container.Config.Labels
		return &dockerContainer{
			ID:             container.ID,
			Name:           name,
			ComposeProject: labels["com.docker.compose.project"],
			ComposeService: labels["com.docker.compose.service"],
		}
	}
	return nil
}

func stopDockerContainer(container dockerContainer) error {
	exe := dockerExecutable()
	if exe == "" {
		return fmt.Errorf("Docker CLI is unavailable, so Portly cannot identify the container safely")
	}
	out, err := hiddenCommand(exe, "stop", "--time", "10", container.ID).CombinedOutput()
	if err != nil {
		detail := strings.TrimSpace(string(out))
		if detail == "" {
			detail = fmt.Sprintf("Docker could not stop %s.", container.displayName())
		}
		return fmt.Errorf("%s", detail)
	}
	return nil
}

func isDockerDaemonCommand(command string) bool {
	lower := strings.ToLower(command)
	return strings.Contains(lower, "dockerd") || strings.Contains(lower, "com.docker.backend") || strings.Contains(lower, "wslrelay")
}
