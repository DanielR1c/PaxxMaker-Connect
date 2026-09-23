package main

// The HTTP API the phone talks to (same routes as the Mac version) plus the
// local status page with the pairing code.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func serve(port int) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/info", handleInfo)
	mux.HandleFunc("/v1/profiles", withToken(handleProfiles))
	mux.HandleFunc("/v1/profile", withToken(handleProfile))
	mux.HandleFunc("/v1/models", withToken(handleModels))
	mux.HandleFunc("/v1/jobs", withToken(handleJobs))
	mux.HandleFunc("/v1/jobs/", withToken(handleJob))
	mux.HandleFunc("/", localOnly(handlePage))
	mux.HandleFunc("/qr.png", localOnly(handleQR))
	mux.HandleFunc("/favicon.ico", localOnly(handleFavicon))
	mux.HandleFunc("/ui/state", localOnly(handleUIState))
	mux.HandleFunc("/ui/autostart", localOnly(handleAutostart))
	mux.HandleFunc("/ui/show", localOnly(handleShow))
	mux.HandleFunc("/ui/quit", localOnly(handleQuit))
	srv := &http.Server{Addr: fmt.Sprintf(":%d", port), Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	return srv.ListenAndServe()
}

func withToken(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Paxx-Token") != state.Token {
			writeJSON(w, 401, JSONObject{"error": "token"})
			return
		}
		h(w, r)
	}
}

// The pairing page shows the code — only for a browser on this PC.
func localOnly(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil || !net.ParseIP(host).IsLoopback() {
			http.Error(w, "local only", 403)
			return
		}
		h(w, r)
	}
}

func handleInfo(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, 404, JSONObject{"error": "path"})
		return
	}
	apps := []string{}
	for _, a := range installedOrcaApps() {
		apps = append(apps, a.Key)
	}
	writeJSON(w, 200, JSONObject{"name": appName, "version": version, "host": hostName(), "orca": orcaInstalled(), "apps": apps})
}

func appFromQuery(r *http.Request) (OrcaApp, bool) {
	key := r.URL.Query().Get("app")
	if key == "" {
		key = "orca"
	}
	return orcaAppNamed(key)
}

func handleProfiles(w http.ResponseWriter, r *http.Request) {
	app, ok := appFromQuery(r)
	if !ok {
		writeJSON(w, 404, JSONObject{"error": "app"})
		return
	}
	idx := NewProfileIndex(app)
	av := idx.Available()
	out := JSONObject{}
	for _, kind := range profileKinds {
		list := []JSONObject{}
		for _, p := range av[kind] {
			d := JSONObject{"name": p.Name, "origin": p.Origin, "inherits": p.Inherits}
			if p.Compatible != nil {
				d["compatible_printers"] = p.Compatible
			} else {
				d["compatible_printers"] = nil
			}
			if kind == "machine" {
				for k, v := range idx.MachineInfo(p.Name) {
					d[k] = v
				}
			}
			list = append(list, d)
		}
		out[kind] = list
	}
	writeJSON(w, 200, out)
}

// One preset flattened through its inheritance chain — the app shows
// its values as the starting point of the quick settings.
func handleProfile(w http.ResponseWriter, r *http.Request) {
	app, ok := appFromQuery(r)
	if !ok {
		writeJSON(w, 404, JSONObject{"error": "app"})
		return
	}
	kind := r.URL.Query().Get("kind")
	if kind == "" {
		kind = "process"
	}
	name := r.URL.Query().Get("name")
	valid := false
	for _, k := range profileKinds {
		if k == kind {
			valid = true
		}
	}
	if !valid || name == "" {
		writeJSON(w, 404, JSONObject{"error": "preset"})
		return
	}
	res, ok := NewProfileIndex(app).Resolve(kind, name)
	if !ok {
		writeJSON(w, 404, JSONObject{"error": "preset"})
		return
	}
	writeJSON(w, 200, res.Dict)
}

func handleModels(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, 404, JSONObject{"error": "path"})
		return
	}
	ext := strings.ToLower(strings.Trim(r.Header.Get("X-Paxx-Ext"), "."))
	if ext == "" {
		ext = "stl"
	}
	if ext != "stl" {
		writeJSON(w, 400, JSONObject{"error": "ext"})
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 512<<20))
	if err != nil {
		writeJSON(w, 400, JSONObject{"error": "body"})
		return
	}
	sum := sha256.Sum256(body)
	id := hex.EncodeToString(sum[:])[:24] + "." + ext
	_ = os.WriteFile(filepath.Join(state.ModelsDir, id), body, 0o644)
	writeJSON(w, 200, JSONObject{"model": id, "bytes": len(body)})
}

func handleJobs(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, 404, JSONObject{"error": "path"})
		return
	}
	var spec JSONObject
	if err := json.NewDecoder(io.LimitReader(r.Body, 64<<20)).Decode(&spec); err != nil || spec == nil {
		writeJSON(w, 400, JSONObject{"error": "json"})
		return
	}
	job := NewSliceJob(spec, state.JobsDir)
	state.Jobs.Add(job)
	state.Log.Add(fmt.Sprintf("Job %s: %v %s %v", job.ID, spec["process"], L("auf", "on"), spec["machine"]))
	go state.Runner.Run(job, state.Log.Add)
	writeJSON(w, 202, job.JSON())
}

func handleJob(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/v1/jobs/")
	parts := strings.Split(strings.Trim(rest, "/"), "/")
	if len(parts) == 0 || parts[0] == "" {
		writeJSON(w, 404, JSONObject{"error": "job"})
		return
	}
	job := state.Jobs.Get(parts[0])
	if job == nil {
		writeJSON(w, 404, JSONObject{"error": "job"})
		return
	}
	if len(parts) == 2 && parts[1] == "gcode" {
		j := job.JSON()
		res, _ := j["result"].(JSONObject)
		name, _ := res["gcode"].(string)
		if j["state"] != "done" || name == "" {
			writeJSON(w, 409, JSONObject{"error": "not done"})
			return
		}
		data, err := os.ReadFile(filepath.Join(job.Dir, filepath.Base(name)))
		if err != nil {
			writeJSON(w, 409, JSONObject{"error": "not done"})
			return
		}
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write(data)
		return
	}
	writeJSON(w, 200, job.JSON())
}

// ---- local status page ----

func pairingLink() string {
	name := strings.NewReplacer(" ", "%20", "&", "%26", "?", "%3F", "#", "%23").Replace(hostName())
	return fmt.Sprintf("paxxmaker://connect?host=%s&port=%d&code=%s&name=%s", reachableHost(), listenPort, state.Token, name)
}

func handleQR(w http.ResponseWriter, r *http.Request) {
	png, err := qrcode.Encode(pairingLink(), qrcode.Medium, 320)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(png)
}

func uiState() JSONObject {
	apps := []string{}
	for _, a := range installedOrcaApps() {
		if a.Key == "snapmaker_orca" {
			apps = append(apps, "Snapmaker Orca")
		} else {
			apps = append(apps, "OrcaSlicer")
		}
	}
	jobs := []JSONObject{}
	for i, j := range state.Jobs.All() {
		if i >= 6 {
			break
		}
		d := j.JSON()
		d["process"] = j.Spec["process"]
		jobs = append(jobs, d)
	}
	return JSONObject{"token": state.Token, "host": hostName(), "ip": reachableHost(), "port": listenPort,
		"orca": orcaInstalled(), "orca_path": orcaBinary(), "apps": apps, "autostart": launchAtLogin(),
		"jobs": jobs, "log": state.Log.Lines(), "version": version, "german": isGerman}
}

func handleUIState(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, uiState()) }

func handleAutostart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "post", 405)
		return
	}
	on := r.FormValue("on") == "1"
	if err := setLaunchAtLogin(on); err != nil {
		state.Log.Add(L("Autostart: ", "Autostart: ") + err.Error())
	}
	writeJSON(w, 200, JSONObject{"autostart": launchAtLogin()})
}

func handleQuit(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "post", 405)
		return
	}
	writeJSON(w, 200, JSONObject{"ok": true})
	go func() { time.Sleep(200 * time.Millisecond); quitApp() }()
}

// A second start of the exe lands here and brings the pairing page back up.
func handleShow(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "post", 405)
		return
	}
	writeJSON(w, 200, JSONObject{"ok": true})
	go showPairing()
}

// The same icon the tray uses — so the browser tab shows a real icon instead
// of a blank page symbol.
func handleFavicon(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "image/x-icon")
	w.Header().Set("Cache-Control", "max-age=86400")
	_, _ = w.Write(appIcon)
}

func handlePage(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(pageHTML()))
}
