package main

import (
	"os"
	"strings"
	"sync"
	"time"
)

type logStore struct {
	mu           sync.Mutex
	serverID     string
	maxLines     int
	maxBytes     int
	lines        []string
	partial      []byte
	bytesWritten int
	file         *os.File
}

func newLogStore(serverID string, maxLines, maxMB int) *logStore {
	s := &logStore{
		serverID: serverID,
		maxLines: max(100, maxLines),
		maxBytes: max(1, maxMB) * 1_000_000,
	}
	s.openFile()
	return s
}

func (s *logStore) appendBytes(chunk []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ingest(string(chunk))
}

// closeFile releases the log handle; Windows cannot delete a file held open.
func (s *logStore) closeFile() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.file != nil {
		_ = s.file.Close()
		s.file = nil
	}
}

func (s *logStore) note(message string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ingest("[portly] " + message + "\n")
}

func (s *logStore) ingest(chunk string) {
	s.partial = append(s.partial, chunk...)
	for {
		idx := indexByte(s.partial, '\n')
		if idx < 0 {
			break
		}
		line := s.partial[:idx]
		if len(line) > 0 && line[len(line)-1] == '\r' {
			line = line[:len(line)-1]
		}
		s.emit(sanitizeLog(string(line)))
		s.partial = s.partial[idx+1:]
	}
	if len(s.partial) > 8000 {
		s.emit(sanitizeLog(string(s.partial)))
		s.partial = nil
	}
}

func (s *logStore) emit(line string) {
	s.lines = append(s.lines, line)
	if len(s.lines) > s.maxLines {
		s.lines = append([]string{}, s.lines[len(s.lines)-s.maxLines:]...)
	}
	s.writeToFile(line)
}

func (s *logStore) tail(count int) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if count < 1 {
		count = 1
	}
	if count > len(s.lines) {
		count = len(s.lines)
	}
	out := make([]string, count)
	copy(out, s.lines[len(s.lines)-count:])
	return out
}

func (s *logStore) updateLimits(maxLines, maxMB int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.maxLines = max(100, maxLines)
	s.maxBytes = max(1, maxMB) * 1_000_000
	if len(s.lines) > s.maxLines {
		s.lines = append([]string{}, s.lines[len(s.lines)-s.maxLines:]...)
	}
}

func (s *logStore) openFile() {
	_ = ensureDirs()
	path := logFile(s.serverID)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	info, _ := f.Stat()
	if info != nil {
		s.bytesWritten = int(info.Size())
	}
	s.file = f
}

func (s *logStore) writeToFile(line string) {
	if s.file == nil {
		return
	}
	stamped := time.Now().Format("15:04:05") + " " + line + "\n"
	n, err := s.file.WriteString(stamped)
	if err == nil {
		s.bytesWritten += n
	}
	if s.bytesWritten > s.maxBytes {
		s.rotate()
	}
}

func (s *logStore) rotate() {
	if s.file != nil {
		_ = s.file.Close()
		s.file = nil
	}
	path := logFile(s.serverID)
	previous := strings.TrimSuffix(path, ".log") + ".1.log"
	_ = os.Remove(previous)
	_ = os.Rename(path, previous)
	s.bytesWritten = 0
	s.openFile()
}

func indexByte(b []byte, c byte) int {
	for i, v := range b {
		if v == c {
			return i
		}
	}
	return -1
}

func sanitizeLog(input string) string {
	var out []rune
	runes := []rune(input)
	for i := 0; i < len(runes); i++ {
		r := runes[i]
		if r == 0x1b {
			i++
			if i >= len(runes) {
				break
			}
			next := runes[i]
			switch next {
			case '[':
				i++
				for i < len(runes) && (runes[i] < 0x40 || runes[i] > 0x7e) {
					i++
				}
			case ']':
				i++
				for i < len(runes) {
					if runes[i] == 0x07 {
						break
					}
					if runes[i] == 0x1b && i+1 < len(runes) && runes[i+1] == '\\' {
						i++
						break
					}
					i++
				}
			}
			continue
		}
		if r == '\r' {
			out = out[:0]
			continue
		}
		if r == 0x07 || r == 0x08 {
			continue
		}
		out = append(out, r)
	}
	return string(out)
}
