package main

// Where OrcaSlicer and its profile folders live on this machine.

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

// The folder that holds "OrcaSlicer" and "Snapmaker_Orca" data dirs:
// ~/.config on Linux (the AppImage and distro packages use it).
func orcaDataBase() string {
	if d := os.Getenv("PAXX_ORCA_DATA"); d != "" {
		return d
	}
	d, _ := os.UserConfigDir()
	return d
}

// OrcaSlicer's command line binary.
func orcaBinary() string {
	// AppImage in the usual places, then whatever is on PATH (distro
	// package, flatpak export, a ~/.local/bin link).
	home, _ := os.UserHomeDir()
	return findBinary("PAXX_ORCA",
		[]string{
			filepath.Join(home, "Applications", "OrcaSlicer.AppImage"),
			filepath.Join(home, ".local", "bin", "OrcaSlicer.AppImage"),
			"/opt/OrcaSlicer/OrcaSlicer.AppImage",
		},
		[]string{"orca-slicer", "OrcaSlicer", "io.github.softfever.OrcaSlicer"})
}

// Snapmaker Orca's AppImage. On Linux its CLI slices fine (unlike on the
// Mac), so a U1 can be sliced with the same program and profiles as on the
// desktop.
func snapmakerOrcaBinary() string {
	home, _ := os.UserHomeDir()
	return findBinary("PAXX_SNAPMAKER_ORCA",
		[]string{
			filepath.Join(home, "Applications", "SnapmakerOrca.AppImage"),
			filepath.Join(home, "Applications", "Snapmaker_Orca.AppImage"),
			filepath.Join(home, ".local", "bin", "SnapmakerOrca.AppImage"),
		},
		[]string{"snapmaker-orca", "SnapmakerOrca"})
}

// The env override, else the first of paths, else the first of names on PATH.
func findBinary(env string, paths, names []string) string {
	if p := os.Getenv(env); p != "" && fileExists(p) {
		return p
	}
	for _, c := range paths {
		if fileExists(c) {
			return c
		}
	}
	for _, n := range names {
		if p, err := exec.LookPath(n); err == nil {
			return p
		}
	}
	return ""
}

// The program that slices for a profile source: Snapmaker Orca's profiles
// go to Snapmaker Orca, everything else to OrcaSlicer.
func slicerFor(appKey string) string {
	if appKey == "snapmaker_orca" {
		return snapmakerOrcaBinary()
	}
	return orcaBinary()
}

func orcaInstalled() bool { return slicerFor(defaultAppKey()) != "" }

// The vendor profiles an AppImage ships. Orca copies them to <data>/system
// only when its window has been opened; a headless box may never do that,
// so they are unpacked once into the state folder (again when the AppImage
// changes) and read as a fallback.
var bundledMu sync.Mutex

func bundledProfiles(appKey string) string {
	bin := slicerFor(appKey)
	fi, err := os.Stat(bin)
	if err != nil || !strings.HasSuffix(strings.ToLower(bin), ".appimage") || state == nil {
		return ""
	}
	bundledMu.Lock()
	defer bundledMu.Unlock()
	dir := filepath.Join(state.StateDir, "bundled", appKey)
	stamp := fmt.Sprintf("%s %d %d", bin, fi.Size(), fi.ModTime().Unix())
	profiles := filepath.Join(dir, "squashfs-root", "resources", "profiles")
	if b, err := os.ReadFile(filepath.Join(dir, "stamp")); err == nil && string(b) == stamp {
		return profiles
	}
	_ = os.RemoveAll(dir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return ""
	}
	cmd := exec.Command(bin, "--appimage-extract", "resources/profiles/*")
	cmd.Dir = dir
	if err := cmd.Run(); err != nil || !fileExists(profiles) {
		state.Log.Add("AppImage profiles: " + fmt.Sprint(err))
		return ""
	}
	_ = os.WriteFile(filepath.Join(dir, "stamp"), []byte(stamp), 0o644)
	return profiles
}

// Snapmaker Orca's command line slices on Linux (unlike up to 2.4.0 on the
// Mac). Should it fail, the job falls back to OrcaSlicer (SliceRunner.Run).
func snapmakerCLIUsable() bool { return snapmakerOrcaBinary() != "" }

// Linux reports no version without starting the program.
func snapmakerOrcaVersion() string { return "" }

// The program that slices one job: Snapmaker Orca for its own profiles where
// its command line works, else OrcaSlicer.
type slicerEngine struct {
	Bin, Name, Version string
	Snapmaker          bool
	// OrcaSlicer 2.5+: .opc caches, CLI resolves inherits, statistics,
	// repair and colour mixing.
	Modern bool
}

func engineFor(appKey string, forceOrca bool) (slicerEngine, bool) {
	if appKey == "snapmaker_orca" && !forceOrca && snapmakerCLIUsable() {
		return slicerEngine{Bin: snapmakerOrcaBinary(), Name: "Snapmaker Orca", Version: snapmakerOrcaVersion(), Snapmaker: true}, true
	}
	bin := orcaBinary()
	if bin == "" {
		return slicerEngine{}, false
	}
	return slicerEngine{Bin: bin, Name: "OrcaSlicer", Version: orcaVersion(), Modern: orcaResolvesInherits()}, true
}

func (e slicerEngine) Label() string { return strings.TrimSpace(e.Name + " " + e.Version) }

func (e slicerEngine) Features() []string {
	f := []string{"fuzzy", "ranges", "filament_ids"}
	if e.Modern {
		f = append(f, "stats", "repair", "mix")
	}
	return f
}

// "2.5+" when OrcaSlicer ships .opc caches, else "".
func orcaVersion() string {
	if len(orcaBundleCaches()) > 0 {
		return "2.5+"
	}
	return ""
}

// The <vendor>.opc preset caches OrcaSlicer 2.5 ships: inside the AppImage
// (unpacked once, see bundledProfiles), or next to a distro/flatpak binary.
func orcaBundleCaches() []string {
	var dirs []string
	if p := bundledProfiles("orca"); p != "" {
		dirs = append(dirs, p)
	}
	if bin := orcaBinary(); bin != "" {
		if real, err := filepath.EvalSymlinks(bin); err == nil {
			bin = real
		}
		d := filepath.Dir(bin)
		dirs = append(dirs, filepath.Join(d, "resources", "profiles"), filepath.Join(d, "..", "share", "OrcaSlicer", "resources", "profiles"),
			filepath.Join(d, "..", "resources", "profiles"))
	}
	dirs = append(dirs, "/usr/share/OrcaSlicer/resources/profiles", "/opt/OrcaSlicer/resources/profiles")
	for _, d := range dirs {
		if m, _ := filepath.Glob(filepath.Join(d, "*.opc")); len(m) > 0 {
			return m
		}
	}
	return nil
}

// OrcaSlicer 2.5 and later resolve `inherits` themselves against their preset
// bundle — and refuse a parent they do not know (a user preset). They are the
// versions that ship .opc caches.
func orcaResolvesInherits() bool {
	if len(orcaBundleCaches()) > 0 {
		return true
	}
	for _, a := range installedOrcaApps() {
		if m, _ := filepath.Glob(filepath.Join(a.DataDir, "system", "*.opc")); len(m) > 0 {
			return true
		}
	}
	return false
}
