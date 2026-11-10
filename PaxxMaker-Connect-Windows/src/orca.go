package main

// Where OrcaSlicer and its profile folders live on this machine.

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
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

// Snapmaker Orca (Snapmaker's OrcaSlicer fork). PAXX_SNAPMAKER_ORCA overrides
// the path, as in the Linux version.
func snapmakerOrcaBinary() string {
	if p := os.Getenv("PAXX_SNAPMAKER_ORCA"); p != "" && fileExists(p) {
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
			for _, d := range []string{"Snapmaker_Orca", "Snapmaker Orca", "SnapmakerOrca"} {
				candidates = append(candidates, filepath.Join(r, d, "snapmaker-orca.exe"))
			}
		}
	case "darwin":
		home, _ := os.UserHomeDir()
		candidates = []string{
			"/Applications/Snapmaker Orca.app/Contents/MacOS/Snapmaker_Orca",
			filepath.Join(home, "Applications", "Snapmaker Orca.app", "Contents", "MacOS", "Snapmaker_Orca"),
		}
	}
	for _, c := range candidates {
		if fileExists(c) {
			return c
		}
	}
	return ""
}

// Version from the Mac bundle's Info.plist; "" where it cannot be read.
func snapmakerOrcaVersion() string {
	bin := snapmakerOrcaBinary()
	if runtime.GOOS != "darwin" || bin == "" {
		return ""
	}
	b, err := os.ReadFile(filepath.Join(filepath.Dir(filepath.Dir(bin)), "Info.plist"))
	if err != nil {
		return ""
	}
	m := regexp.MustCompile(`<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>`).FindSubmatch(b)
	if m == nil {
		return ""
	}
	return string(m[1])
}

// Its command line slices from 2.4.1 on (it crashed outright up to 2.4.0 on
// the Mac). Where the version is unknown (Windows) it is tried — a failed
// slice falls back to OrcaSlicer (see SliceRunner.Run).
func snapmakerCLIUsable() bool {
	if snapmakerOrcaBinary() == "" {
		return false
	}
	v := snapmakerOrcaVersion()
	if v == "" {
		return runtime.GOOS != "darwin"
	}
	var a, b, c int
	fmt.Sscanf(v, "%d.%d.%d", &a, &b, &c)
	return a > 2 || (a == 2 && (b > 4 || (b == 4 && c >= 1)))
}

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

// OrcaSlicer's version: the Mac bundle's Info.plist; on Windows "2.5+" when it
// ships .opc caches, else "".
func orcaVersion() string {
	bin := orcaBinary()
	if runtime.GOOS == "darwin" && bin != "" {
		if b, err := os.ReadFile(filepath.Join(filepath.Dir(filepath.Dir(bin)), "Info.plist")); err == nil {
			if m := regexp.MustCompile(`<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>`).FindSubmatch(b); m != nil {
				return string(m[1])
			}
		}
	}
	if len(orcaBundleCaches()) > 0 {
		return "2.5+"
	}
	return ""
}

// The <vendor>.opc preset caches OrcaSlicer 2.5 ships next to its binary
// (Windows: <install>\resources\profiles, Mac: OrcaSlicer.app/Contents/Resources/profiles).
func orcaBundleCaches() []string {
	bin := orcaBinary()
	if bin == "" {
		return nil
	}
	dir := filepath.Dir(bin)
	var out []string
	for _, d := range []string{filepath.Join(dir, "resources", "profiles"), filepath.Join(filepath.Dir(dir), "Resources", "profiles")} {
		m, _ := filepath.Glob(filepath.Join(d, "*.opc"))
		out = append(out, m...)
		if len(m) > 0 {
			break
		}
	}
	return out
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
