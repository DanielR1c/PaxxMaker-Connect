//go:build !windows

package main

func setLaunchAtLogin(on bool) error { return nil }
func launchAtLogin() bool            { return false }
