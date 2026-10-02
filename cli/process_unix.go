//go:build !windows

package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"syscall"

	"github.com/creack/pty"
)

type childProcess struct {
	cmd  *exec.Cmd
	pty  *os.File
	pgid int
}

func loginShell(command string) (string, []string) {
	if sh := os.Getenv("SHELL"); filepath.IsAbs(sh) {
		if info, err := os.Stat(sh); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return sh, []string{"-lc", command}
		}
	}
	if info, err := os.Stat("/bin/bash"); err == nil && !info.IsDir() {
		return "/bin/bash", []string{"-lc", command}
	}
	return "/bin/sh", []string{"-lc", command}
}

func startChild(command, dir string, env []string) (*childProcess, io.Reader, error) {
	if child, reader, err := startChildPTY(command, dir, env); err == nil {
		return child, reader, nil
	}
	return startChildPiped(command, dir, env)
}

func newShellCommand(command, dir string, env []string) *exec.Cmd {
	shell, args := loginShell(command)
	cmd := exec.Command(shell, args...)
	cmd.Dir = dir
	cmd.Env = env
	return cmd
}

func startChildPTY(command, dir string, env []string) (*childProcess, io.Reader, error) {
	cmd := newShellCommand(command, dir, env)
	ptmx, err := pty.Start(cmd)
	if err != nil {
		return nil, nil, err
	}
	if cmd.Process == nil {
		_ = ptmx.Close()
		return nil, nil, fmt.Errorf("process did not start")
	}
	return &childProcess{cmd: cmd, pty: ptmx, pgid: cmd.Process.Pid}, ptmx, nil
}

func startChildPiped(command, dir string, env []string) (*childProcess, io.Reader, error) {
	cmd := newShellCommand(command, dir, env)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, nil, err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return nil, nil, err
	}
	return &childProcess{cmd: cmd, pgid: cmd.Process.Pid}, stdout, nil
}

func (c *childProcess) signalGroup(sig syscall.Signal) {
	if c == nil || c.pgid <= 0 {
		return
	}
	_ = syscall.Kill(-c.pgid, sig)
	_ = syscall.Kill(c.pgid, sig)
}

func (c *childProcess) wait() error {
	if c == nil || c.cmd == nil {
		return nil
	}
	err := c.cmd.Wait()
	if c.pty != nil {
		_ = c.pty.Close()
	}
	return err
}

// terminatePID asks an external listener to stop.
func terminatePID(pid int) error { return syscall.Kill(pid, syscall.SIGTERM) }

// killProcessTree force-kills a managed child and its process group.
func killProcessTree(pid int) { _ = syscall.Kill(-pid, syscall.SIGKILL) }

func hiddenCommand(name string, args ...string) *exec.Cmd { return exec.Command(name, args...) }

func startDetached(cmd *exec.Cmd) error {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	return cmd.Start()
}

func listProcesses() []procRecord {
	if runtime.GOOS == "linux" {
		if recs := listLinuxProcesses(); len(recs) > 0 {
			return recs
		}
	}
	return listPSProcesses()
}

func processName(pid int) string { return commandForPID(pid) }
