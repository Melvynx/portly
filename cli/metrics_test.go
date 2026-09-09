package main

import "testing"

func TestParseStatReadsCPUTicks(t *testing.T) {
	t.Parallel()
	// comm, then state ppid pgrp session tty tpgid flags minflt cminflt majflt cmajflt utime stime ... rss
	stat := "1234 (node) S 10 0 0 0 0 0 0 0 0 0 40 60 0 0 0 0 0 0 0 0 99"
	ppid, rss, ticks := parseStat(stat)
	if ppid != 10 || rss != 99 || ticks != 100 {
		t.Fatalf("parseStat() = ppid=%d rss=%d ticks=%d", ppid, rss, ticks)
	}
}
