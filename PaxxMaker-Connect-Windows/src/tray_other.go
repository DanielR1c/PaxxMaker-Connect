//go:build !windows

package main

// No tray on other platforms (used for testing the pipeline on a Mac):
// the process just keeps serving until it is killed or /ui/quit is hit.

import (
	"os"
	"os/signal"
	"syscall"
)

func runTray() {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
}

func quitApp() { os.Exit(0) }
