// PaxxMaker-Connect for Windows — the link between the PaxxMaker app on the
// phone and OrcaSlicer on this PC. Runs as a tray icon, serves the same
// HTTP API as the Mac version (port 8765, Bonjour _paxxconnect._tcp, pairing
// by code) and lets the installed OrcaSlicer slice headless. The pairing
// window is a local web page (http://127.0.0.1:8765/) that opens in the
// browser; the tray menu brings it back.
//
// Builds on macOS/Linux too (without the tray) so the pipeline can be tested
// against a local OrcaSlicer: PAXX_STATE_DIR / PAXX_ORCA override the paths.
package main

import (
	"crypto/rand"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

const (
	appName = "PaxxMaker-Connect"
	version = "1.3"
)

var listenPort = 8765

// state is what the tray, the web page and the API share.
var state *ConnectState

type ConnectState struct {
	Token     string
	StateDir  string
	JobsDir   string
	ModelsDir string
	Runner    *SliceRunner
	Jobs      *JobList
	Log       *LogBuffer
	StartedAt time.Time
}

func main() {
	showWindow := flag.Bool("show-window", false, "open the pairing page (default unless --background)")
	background := flag.Bool("background", false, "start without the page (used by the autostart entry)")
	loginItem := flag.String("login-item", "", "on|off: start with Windows (registry Run key)")
	uninstall := flag.Bool("uninstall", false, "remove the login item and quit")
	port := flag.Int("port", 8765, "TCP port of the service")
	flag.Parse()
	listenPort = *port

	if *loginItem != "" {
		if err := setLaunchAtLogin(*loginItem == "on"); err != nil {
			log.Println("login item:", err)
		}
	}
	if *uninstall {
		_ = setLaunchAtLogin(false)
		return
	}

	// Double-clicking the exe while it is already running should raise the
	// program, not die on the occupied port.
	if raiseRunningInstance() {
		return
	}
	// Keep the autostart entry pointing at this exe and carrying --background,
	// so an entry written by an older version does not pop the window at login.
	if launchAtLogin() {
		_ = setLaunchAtLogin(true)
	}

	st, err := newState()
	if err != nil {
		log.Fatal(err)
	}
	state = st
	go func() {
		if err := serve(listenPort); err != nil {
			st.Log.Add(L("Start fehlgeschlagen: ", "Start failed: ") + err.Error())
			log.Println("serve:", err)
		}
	}()
	go advertise(listenPort)
	st.Log.Add(fmt.Sprintf(L("Dienst gestartet auf Port %d", "Service started on port %d"), listenPort))

	// Starting the program shows the pairing page — only the autostart entry
	// stays quiet in the tray.
	if !fileExists(filepath.Join(st.StateDir, "welcomed")) {
		_ = os.WriteFile(filepath.Join(st.StateDir, "welcomed"), []byte("1"), 0o644)
	}
	if *showWindow || !*background {
		go func() { time.Sleep(600 * time.Millisecond); showPairing() }()
	}
	runTray() // blocks; on non-Windows builds it just waits forever
}

func newState() (*ConnectState, error) {
	dir := os.Getenv("PAXX_STATE_DIR")
	if dir == "" {
		base, err := os.UserConfigDir() // Windows: %AppData%
		if err != nil {
			return nil, err
		}
		dir = filepath.Join(base, appName)
	}
	jobs := filepath.Join(dir, "jobs")
	models := filepath.Join(dir, "models")
	for _, d := range []string{dir, jobs, models} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return nil, err
		}
	}
	token := readToken(filepath.Join(dir, "token"))
	st := &ConnectState{Token: token, StateDir: dir, JobsDir: jobs, ModelsDir: models,
		Jobs: NewJobList(), Log: NewLogBuffer(200), StartedAt: time.Now()}
	st.Runner = &SliceRunner{ModelsDir: models}
	cleanupOldJobs(jobs)
	return st, nil
}

// Six characters without look-alikes, kept across restarts.
func readToken(path string) string {
	if b, err := os.ReadFile(path); err == nil {
		t := strings.TrimSpace(string(b))
		if len(t) == 6 {
			return t
		}
	}
	const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	buf := make([]byte, 6)
	_, _ = rand.Read(buf)
	t := make([]byte, 6)
	for i, b := range buf {
		t[i] = chars[int(b)%len(chars)]
	}
	_ = os.WriteFile(path, t, 0o600)
	return string(t)
}

// Jobs older than a day go — the G-code lives on the printer.
func cleanupOldJobs(dir string) {
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if info, err := e.Info(); err == nil && time.Since(info.ModTime()) > 24*time.Hour {
			_ = os.RemoveAll(filepath.Join(dir, e.Name()))
		}
	}
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func hostName() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "PC"
	}
	return h
}

// What the phone should dial: the PC's LAN IPv4 (Wi-Fi/Ethernet before
// virtual adapters), else the host name.
func reachableHost() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return hostName()
	}
	best, fallback := "", ""
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		name := strings.ToLower(ifc.Name)
		virtual := strings.Contains(name, "vmware") || strings.Contains(name, "virtualbox") || strings.Contains(name, "vethernet") ||
			strings.Contains(name, "hyper-v") || strings.Contains(name, "wsl") || strings.Contains(name, "docker") || strings.Contains(name, "tailscale") ||
			strings.Contains(name, "loopback") || strings.HasPrefix(name, "utun") || strings.HasPrefix(name, "bridge")
		addrs, _ := ifc.Addrs()
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip4 := ipn.IP.To4()
			if ip4 == nil || ip4.IsLinkLocalUnicast() {
				continue
			}
			if !virtual && best == "" {
				best = ip4.String()
			}
			if fallback == "" {
				fallback = ip4.String()
			}
		}
	}
	if best != "" {
		return best
	}
	if fallback != "" {
		return fallback
	}
	return hostName()
}

func pairingURL() string { return fmt.Sprintf("http://127.0.0.1:%d/", listenPort) }

// raiseRunningInstance asks a copy that is already serving to show the pairing
// page and reports whether there was one. The version check keeps us from
// mistaking some other program on the port for ourselves.
func raiseRunningInstance() bool {
	c := &http.Client{Timeout: 1500 * time.Millisecond}
	resp, err := c.Get(fmt.Sprintf("http://127.0.0.1:%d/ui/state", listenPort))
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	var s struct {
		Version string `json:"version"`
	}
	if json.NewDecoder(resp.Body).Decode(&s) != nil || s.Version == "" {
		return false
	}
	r, err := c.Post(fmt.Sprintf("http://127.0.0.1:%d/ui/show", listenPort), "text/plain", nil)
	if err == nil {
		r.Body.Close()
	}
	return true
}

func openBrowser(url string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	case "darwin":
		cmd = exec.Command("open", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	hideConsole(cmd)
	_ = cmd.Start()
}

// LogBuffer keeps the last lines for the status page.
type LogBuffer struct {
	mu    sync.Mutex
	lines []string
	max   int
}

func NewLogBuffer(max int) *LogBuffer { return &LogBuffer{max: max} }

func (l *LogBuffer) Add(s string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.lines = append(l.lines, time.Now().Format("15:04:05")+"  "+s)
	if len(l.lines) > l.max {
		l.lines = l.lines[len(l.lines)-l.max:]
	}
}

func (l *LogBuffer) Lines() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]string, len(l.lines))
	copy(out, l.lines)
	return out
}
