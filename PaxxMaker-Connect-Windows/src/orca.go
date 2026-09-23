package main

// Where OrcaSlicer and its profile folders live on this machine.

import (
	"os"
	"path/filepath"
	"runtime"
)

// The folder that holds "OrcaSlicer" and "Snapmaker_Orca" data dirs:
// %AppData% on Windows, ~/Library/Application Support on a Mac (testing).
func orcaDataBase() string {
	if d := os.Getenv("PAXX_ORCA_DATA"); d != "" {
		return d
	}
	if runtime.GOOS == "windows" {
		if d := os.Getenv("APPDATA"); d != "" {
			return d
		}
	}
	if runtime.GOOS == "darwin" {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, "Library", "Application Support")
	}
	d, _ := os.UserConfigDir()
	return d
}

// OrcaSlicer's command line binary. Windows ships a console flavour next
// to the GUI exe; the GUI exe accepts the same arguments as a fallback.
// Snapmaker Orca is never used — its CLI cannot slice.
func orcaBinary() string {
	if p := os.Getenv("PAXX_ORCA"); p != "" && fileExists(p) {
		return p
	}
	var candidates []string
	switch runtime.GOOS {
	case "windows":
		roots := []string{os.Getenv("ProgramFiles"), os.Getenv("ProgramW6432"), filepath.Join(os.Getenv("LOCALAPPDATA"), "Programs"), os.Getenv("ProgramFiles(x86)")}
		for _, r := range roots {
			if r == "" {
				continue
			}
			candidates = append(candidates,
				filepath.Join(r, "OrcaSlicer", "orca-slicer-console.exe"),
				filepath.Join(r, "OrcaSlicer", "orca-slicer.exe"))
		}
	case "darwin":
		home, _ := os.UserHomeDir()
		candidates = []string{
			"/Applications/OrcaSlicer.app/Contents/MacOS/OrcaSlicer",
			filepath.Join(home, "Applications", "OrcaSlicer.app", "Contents", "MacOS", "OrcaSlicer"),
		}
	default:
		candidates = []string{"/usr/bin/orca-slicer", "/usr/local/bin/orca-slicer"}
	}
	for _, c := range candidates {
		if fileExists(c) {
			return c
		}
	}
	return ""
}

func orcaInstalled() bool { return orcaBinary() != "" }
