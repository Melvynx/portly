package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

type listener struct {
	Port    int
	PID     int
	Command string
	User    string
}

type stopOutcome struct {
	Description     string
	ProcessID       *int
	DockerContainer *dockerContainer
}

func occupantOf(port int) *listener {
	if runtime.GOOS == "windows" {
		return occupantFromNetstat(port)
	}
	if occ := occupantFromProc(port); occ != nil {
		return occ
	}
	if occ := occupantFromSS(port); occ != nil {
		return occ
	}
	return occupantFromLsof(port)
}

func isListening(port int) bool { return occupantOf(port) != nil }

func stopOccupant(port int, expectedPID *int) (stopOutcome, error) {
	occ := occupantOf(port)
	if occ == nil {
		return stopOutcome{}, fmt.Errorf("The port is already free.")
	}
	if expectedPID != nil && occ.PID != *expectedPID {
		return stopOutcome{}, fmt.Errorf("The listener changed before Portly could stop it. Refresh and try again.")
	}
	if container := dockerContainerPublishing(port); container != nil {
		if err := stopDockerContainer(*container); err != nil {
			return stopOutcome{}, err
		}
		return stopOutcome{
			Description:     "Docker container " + container.displayName(),
			DockerContainer: container,
		}, nil
	}
	if isDockerDaemonCommand(occ.Command) {
		return stopOutcome{}, fmt.Errorf("Refusing to signal the Docker daemon. Stop the published container instead.")
	}
	if err := terminatePID(occ.PID); err != nil {
		return stopOutcome{}, fmt.Errorf("Process %d refused the stop request.", occ.PID)
	}
	pid := occ.PID
	return stopOutcome{
		Description: fmt.Sprintf("%s (pid %d)", occ.Command, occ.PID),
		ProcessID:   &pid,
	}, nil
}

func occupantFromProc(port int) *listener {
	if runtime.GOOS != "linux" {
		return nil
	}
	for _, table := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		if occ := scanProcNet(table, port); occ != nil {
			return occ
		}
	}
	return nil
}

func scanProcNet(path string, port int) *listener {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	if !scanner.Scan() {
		return nil
	}
	want := strings.ToUpper(fmt.Sprintf("%04X", port))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 10 {
			continue
		}
		local := fields[1]
		state := fields[3]
		inode := fields[9]
		if state != "0A" {
			continue
		}
		parts := strings.Split(local, ":")
		if len(parts) != 2 || !strings.EqualFold(parts[1], want) {
			continue
		}
		pid, cmd := pidForInode(inode)
		if pid == 0 {
			continue
		}
		return &listener{Port: port, PID: pid, Command: cmd, User: currentUser()}
	}
	return nil
}

func pidForInode(inode string) (int, string) {
	matches, _ := filepath.Glob("/proc/[0-9]*/fd/*")
	needle := "socket:[" + inode + "]"
	for _, fd := range matches {
		target, err := os.Readlink(fd)
		if err != nil || target != needle {
			continue
		}
		pid, _ := strconv.Atoi(strings.Split(fd, "/")[2])
		return pid, commandForPID(pid)
	}
	return 0, ""
}

func commandForPID(pid int) string {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/comm", pid))
	if err != nil {
		return "unknown"
	}
	return strings.TrimSpace(string(data))
}

func occupantFromSS(port int) *listener {
	out, err := exec.Command("ss", "-lptn", fmt.Sprintf("sport = :%d", port)).Output()
	if err != nil {
		return nil
	}
	for _, line := range strings.Split(string(out), "\n") {
		if !strings.Contains(line, "pid=") {
			continue
		}
		pid := extractAfter(line, "pid=")
		cmd := extractBetween(line, "users:((\"", "\"")
		if pid == 0 {
			continue
		}
		if cmd == "" {
			cmd = commandForPID(pid)
		}
		return &listener{Port: port, PID: pid, Command: cmd, User: currentUser()}
	}
	return nil
}

func occupantFromLsof(port int) *listener {
	out, err := exec.Command("lsof", "-nP", fmt.Sprintf("-iTCP:%d", port), "-sTCP:LISTEN", "-FpcLn").Output()
	if err != nil {
		return nil
	}
	var pid int
	command, user := "unknown", currentUser()
	for _, line := range strings.Split(string(out), "\n") {
		if line == "" {
			continue
		}
		switch line[0] {
		case 'p':
			if pid != 0 {
				return &listener{Port: port, PID: pid, Command: command, User: user}
			}
			pid, _ = strconv.Atoi(line[1:])
		case 'c':
			command = line[1:]
		case 'L':
			user = line[1:]
		}
	}
	if pid == 0 {
		return nil
	}
	return &listener{Port: port, PID: pid, Command: command, User: user}
}

func extractAfter(s, prefix string) int {
	i := strings.Index(s, prefix)
	if i < 0 {
		return 0
	}
	rest := s[i+len(prefix):]
	n := 0
	for _, r := range rest {
		if r < '0' || r > '9' {
			break
		}
		n = n*10 + int(r-'0')
	}
	return n
}

func extractBetween(s, start, end string) string {
	i := strings.Index(s, start)
	if i < 0 {
		return ""
	}
	rest := s[i+len(start):]
	j := strings.Index(rest, end)
	if j < 0 {
		return ""
	}
	return rest[:j]
}

func currentUser() string {
	if u := os.Getenv("USER"); u != "" {
		return u
	}
	if u := os.Getenv("USERNAME"); u != "" {
		return u
	}
	return ""
}

func occupantFromNetstat(port int) *listener {
	out, err := hiddenCommand("netstat", "-ano", "-p", "TCP").Output()
	if err != nil {
		return nil
	}
	v6, _ := hiddenCommand("netstat", "-ano", "-p", "TCPv6").Output()
	pid := parseNetstatListener(string(out)+string(v6), port)
	if pid == 0 {
		return nil
	}
	return &listener{Port: port, PID: pid, Command: processName(pid), User: currentUser()}
}

// parseNetstatListener finds the PID listening on port. The state column is
// localized, so a listener is recognized by its unbound remote address instead.
func parseNetstatListener(out string, port int) int {
	suffix := ":" + strconv.Itoa(port)
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) != 5 || !strings.HasPrefix(f[0], "TCP") || !strings.HasSuffix(f[1], suffix) {
			continue
		}
		if f[2] != "0.0.0.0:0" && f[2] != "[::]:0" {
			continue
		}
		if pid, err := strconv.Atoi(f[4]); err == nil && pid > 0 {
			return pid
		}
	}
	return 0
}
