//go:build !windows

package main

import (
	"os"
	"os/signal"
	"syscall"
)

func installSignalNotify(ch chan<- os.Signal) {
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
}
