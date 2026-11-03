package main

import (
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

const createNoWindow = 0x08000000

type childProcess struct {
	cmd  *exec.Cmd
	mu   sync.Mutex // guards job against stop racing wait
	job  windows.Handle
	done bool
	pgid int
}

func newShellCommand(command, dir string, env []string) *exec.Cmd {
	comspec := os.Getenv("ComSpec")
	if comspec == "" {
		comspec = `C:\Windows\System32\cmd.exe`
	}
	cmd := exec.Command(comspec)
	// cmd.exe does not follow argv quoting rules: pass the raw line.
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CmdLine:       `/d /s /c "` + command + `"`,
		CreationFlags: createNoWindow,
		HideWindow:    true,
	}
	cmd.Dir = dir
	cmd.Env = env
	return cmd
}

func startChild(command, dir string, env []string) (*childProcess, io.Reader, error) {
	cmd := newShellCommand(command, dir, env)
	reader, writer, err := os.Pipe()
	if err != nil {
		return nil, nil, err
	}
	cmd.Stdout = writer
	cmd.Stderr = writer
	job, err := newKillOnCloseJob()
	if err != nil {
		reader.Close()
		writer.Close()
		return nil, nil, err
	}
	if err := cmd.Start(); err != nil {
		reader.Close()
		writer.Close()
		windows.CloseHandle(job)
		return nil, nil, err
	}
	writer.Close()
	// ponytail: the process is assigned right after Start, so a grandchild spawned in
	// that microsecond window escapes the job. Use CREATE_SUSPENDED + resume if it ever matters.
	if !assignToJob(job, cmd.Process.Pid) {
		windows.CloseHandle(job)
		job = 0 // signalGroup falls back to terminatePID
	}
	return &childProcess{cmd: cmd, job: job, pgid: cmd.Process.Pid}, reader, nil
}

// newKillOnCloseJob returns a job whose whole process tree dies when the handle
// closes, including when the daemon itself crashes.
func newKillOnCloseJob() (windows.Handle, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return 0, err
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{
		BasicLimitInformation: windows.JOBOBJECT_BASIC_LIMIT_INFORMATION{
			LimitFlags: windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
		},
	}
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
		windows.CloseHandle(job)
		return 0, err
	}
	return job, nil
}

// signalGroup ends the whole job. The daemon has no console, so Windows offers no
// graceful Ctrl+C equivalent to deliver: SIGTERM and SIGKILL both terminate.
// ponytail: no graceful shutdown on Windows; dev servers tolerate it.
func (c *childProcess) signalGroup(sig syscall.Signal) {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.job != 0 {
		_ = windows.TerminateJobObject(c.job, 1)
	} else if !c.done {
		killProcessTree(c.pgid)
	}
}

func (c *childProcess) wait() error {
	if c == nil || c.cmd == nil {
		return nil
	}
	err := c.cmd.Wait()
	c.mu.Lock()
	defer c.mu.Unlock()
	c.done = true
	if c.job != 0 {
		// Closing the job also kills anything the shell left running.
		windows.CloseHandle(c.job)
		c.job = 0
	}
	return err
}

// terminatePID force-kills pid and its descendants (Windows has no SIGTERM for
// another console process). Win32 calls, because taskkill takes seconds.
func terminatePID(pid int) error {
	children := map[int][]int{}
	eachProcess(func(e *windows.ProcessEntry32) {
		children[int(e.ParentProcessID)] = append(children[int(e.ParentProcessID)], int(e.ProcessID))
	})
	var err error
	var kill func(p int, depth int)
	kill = func(p int, depth int) {
		if depth < 64 { // guards against PID reuse cycles
			for _, child := range children[p] {
				kill(child, depth+1)
			}
		}
		h, openErr := windows.OpenProcess(windows.PROCESS_TERMINATE, false, uint32(p))
		if openErr != nil {
			if p == pid {
				err = openErr
			}
			return
		}
		defer windows.CloseHandle(h)
		if termErr := windows.TerminateProcess(h, 1); termErr != nil && p == pid {
			err = termErr
		}
	}
	kill(pid, 0)
	return err
}

func processName(pid int) string {
	name := "unknown"
	eachProcess(func(e *windows.ProcessEntry32) {
		if int(e.ProcessID) == pid {
			name = windows.UTF16ToString(e.ExeFile[:])
		}
	})
	return name
}

func eachProcess(fn func(e *windows.ProcessEntry32)) {
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return
	}
	defer windows.CloseHandle(snap)
	var entry windows.ProcessEntry32
	entry.Size = uint32(unsafe.Sizeof(entry))
	for err = windows.Process32First(snap, &entry); err == nil; err = windows.Process32Next(snap, &entry) {
		fn(&entry)
	}
}
func killProcessTree(pid int) { _ = terminatePID(pid) }

func assignToJob(job windows.Handle, pid int) bool {
	h, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(pid))
	if err != nil {
		return false
	}
	defer windows.CloseHandle(h)
	return windows.AssignProcessToJobObject(job, h) == nil
}

// hiddenCommand runs a console tool without flashing a window.
func hiddenCommand(name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow, HideWindow: true}
	return cmd
}

// startDetached gives the daemon its own hidden console, so the tools it runs
// never open windows, and escapes the caller's job (terminals and IDEs often
// kill their job on exit) when the job allows it.
func startDetached(cmd *exec.Cmd) error {
	flags := uint32(createNoWindow | windows.CREATE_NEW_PROCESS_GROUP)
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: flags | windows.CREATE_BREAKAWAY_FROM_JOB, HideWindow: true}
	if err := cmd.Start(); err == nil {
		return nil
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: flags, HideWindow: true}
	return cmd.Start()
}
