package main

import (
	"os"
	"os/signal"
)

func installSignalNotify(ch chan<- os.Signal) {
	signal.Notify(ch, os.Interrupt)
}
