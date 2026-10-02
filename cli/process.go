package main

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

func (c *childProcess) pid() int {
	if c == nil || c.cmd == nil || c.cmd.Process == nil {
		return 0
	}
	return c.cmd.Process.Pid
}

func exitCodeFromWait(err error) int {
	if err == nil {
		return 0
	}
	if exit, ok := err.(*exec.ExitError); ok {
		if status, ok := exit.Sys().(syscall.WaitStatus); ok {
			if status.Signaled() {
				return 128 + int(status.Signal())
			}
			return status.ExitStatus()
		}
		return exit.ExitCode()
	}
	return 1
}

func childEnv(base map[string]string, server string, port *int, extra map[string]string) []string {
	envMap := map[string]string{}
	for _, kv := range os.Environ() {
		if i := indexByte([]byte(kv), '='); i > 0 {
			envMap[kv[:i]] = kv[i+1:]
		}
	}
	delete(envMap, "NO_COLOR")
	envMap["TERM"] = "xterm-256color"
	envMap["COLORTERM"] = "truecolor"
	envMap["FORCE_COLOR"] = "1"
	envMap["CLICOLOR"] = "1"
	envMap["CLICOLOR_FORCE"] = "1"
	envMap["TERM_PROGRAM"] = "Portly"
	envMap["PORTLY"] = "1"
	envMap["PORTLY_SERVER"] = server
	if port != nil {
		envMap["PORT"] = fmt.Sprintf("%d", *port)
	}
	for k, v := range extra {
		envMap[k] = v
	}
	out := make([]string, 0, len(envMap))
	for k, v := range envMap {
		out = append(out, k+"="+v)
	}
	return out
}
