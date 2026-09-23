package main

// Runs one slicing job: resolves the profiles, writes the plate as 3MF, calls
// OrcaSlicer headless and reads the result off the G-code footer. (Port of
// Slicer.swift — same flags, same fixes for the CLI's quirks.)

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type SliceJob struct {
	ID        string
	Spec      JSONObject
	State     string // queued / running / done / failed
	Progress  float64
	Stage     string
	Error     string
	ErrorCode *int
	Result    JSONObject
	Dir       string
	Created   time.Time
	mu        sync.Mutex
}

func NewSliceJob(spec JSONObject, jobsDir string) *SliceJob {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	id := hex.EncodeToString(b)
	j := &SliceJob{ID: id, Spec: spec, State: "queued", Dir: filepath.Join(jobsDir, id), Created: time.Now()}
	_ = os.MkdirAll(j.Dir, 0o755)
	return j
}

func (j *SliceJob) set(f func()) {
	j.mu.Lock()
	f()
	j.mu.Unlock()
}

func (j *SliceJob) JSON() JSONObject {
	j.mu.Lock()
	defer j.mu.Unlock()
	out := JSONObject{"id": j.ID, "state": j.State, "progress": j.Progress, "stage": j.Stage, "error": nil, "error_code": nil, "result": nil}
	if j.Error != "" {
		out["error"] = j.Error
	}
	if j.ErrorCode != nil {
		out["error_code"] = *j.ErrorCode
	}
	if j.Result != nil {
		out["result"] = j.Result
	}
	return out
}

// JobList: newest first, capped, safe for the API and the page.
type JobList struct {
	mu   sync.Mutex
	jobs []*SliceJob
}

func NewJobList() *JobList { return &JobList{} }

func (l *JobList) Add(j *SliceJob) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.jobs = append([]*SliceJob{j}, l.jobs...)
	if len(l.jobs) > 20 {
		l.jobs = l.jobs[:20]
	}
}

func (l *JobList) Get(id string) *SliceJob {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, j := range l.jobs {
		if j.ID == id {
			return j
		}
	}
	return nil
}

func (l *JobList) All() []*SliceJob {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]*SliceJob, len(l.jobs))
	copy(out, l.jobs)
	return out
}

type SliceRunner struct {
	ModelsDir string
}

// Quick settings the app may send; each becomes an Orca CLI flag
// (`--key-with-dashes=value`). Numbers, bools and enum strings as in
// Orca's own JSON; percentages get their sign.
type overrideKind int

const (
	ovNum overrideKind = iota
	ovInt
	ovPercent
	ovBool
	ovStr
)

var overrides = []struct {
	key  string
	flag string
	kind overrideKind
}{
	{"layer_height", "layer-height", ovNum},
	{"initial_layer_print_height", "initial-layer-print-height", ovNum},
	{"seam_position", "seam-position", ovStr},
	{"wall_loops", "wall-loops", ovInt},
	{"top_shell_layers", "top-shell-layers", ovInt},
	{"bottom_shell_layers", "bottom-shell-layers", ovInt},
	{"sparse_infill_density", "sparse-infill-density", ovPercent},
	{"sparse_infill_pattern", "sparse-infill-pattern", ovStr},
	{"enable_support", "enable-support", ovBool},
	{"support_type", "support-type", ovStr},
	{"support_on_build_plate_only", "support-on-build-plate-only", ovBool},
	{"support_threshold_angle", "support-threshold-angle", ovInt},
	{"brim_type", "brim-type", ovStr},
	{"brim_width", "brim-width", ovNum},
	{"brim_object_gap", "brim-object-gap", ovNum},
	{"skirt_loops", "skirt-loops", ovInt},
	{"spiral_mode", "spiral-mode", ovBool},
	{"print_sequence", "print-sequence", ovStr},
}

func numOf(v any) (float64, bool) {
	switch x := v.(type) {
	case float64:
		return x, true
	case int:
		return float64(x), true
	case string:
		f, err := strconv.ParseFloat(x, 64)
		return f, err == nil
	case bool:
		if x {
			return 1, true
		}
		return 0, true
	}
	return 0, false
}

func overrideFlag(key string, kind overrideKind, v any) string {
	switch kind {
	case ovNum:
		if f, ok := numOf(v); ok {
			return fmt.Sprintf("--%s=%s", key, strconv.FormatFloat(f, 'f', -1, 64))
		}
	case ovInt:
		if f, ok := numOf(v); ok {
			return fmt.Sprintf("--%s=%d", key, int(math.Round(f)))
		}
	case ovPercent:
		if f, ok := numOf(v); ok {
			return fmt.Sprintf("--%s=%d%%", key, int(math.Round(f)))
		}
	case ovBool:
		if b, ok := v.(bool); ok {
			if b {
				return "--" + key + "=1"
			}
			return "--" + key + "=0"
		}
		if f, ok := numOf(v); ok {
			if f != 0 {
				return "--" + key + "=1"
			}
			return "--" + key + "=0"
		}
	case ovStr:
		if s, ok := v.(string); ok && s != "" {
			return "--" + key + "=" + s
		}
	}
	return ""
}

func (r *SliceRunner) Run(job *SliceJob, logf func(string)) {
	job.set(func() { job.State = "running"; job.Stage = "prepare"; job.Progress = 0.05 })
	err := r.run(job)
	if err != nil {
		job.set(func() { job.State = "failed"; job.Error = err.Error(); job.Stage = "failed" })
		logf(fmt.Sprintf("Job %s %s: %s", job.ID, L("fehlgeschlagen", "failed"), err.Error()))
		return
	}
	logf(fmt.Sprintf("Job %s %s: %v g, %v s", job.ID, L("fertig", "done"), job.Result["filament_g"], job.Result["time_s"]))
}

func (r *SliceRunner) run(job *SliceJob) error {
	spec := job.Spec
	bin := orcaBinary()
	if bin == "" {
		return errors.New(L("OrcaSlicer nicht gefunden – bitte OrcaSlicer installieren", "OrcaSlicer not found – please install OrcaSlicer"))
	}
	appKey, _ := spec["app"].(string)
	if appKey == "" {
		appKey = "orca"
	}
	app, ok := orcaAppNamed(appKey)
	if !ok {
		return errors.New(L("Orca-Datenordner nicht gefunden", "Orca data folder not found"))
	}
	idx := NewProfileIndex(app)
	machineName, _ := spec["machine"].(string)
	processName, _ := spec["process"].(string)
	machine, ok1 := idx.Resolve("machine", machineName)
	process, ok2 := idx.Resolve("process", processName)
	if machineName == "" || processName == "" || !ok1 || !ok2 {
		return errors.New(L("Profil nicht gefunden", "Profile not found"))
	}
	var filaments []Resolved
	for _, name := range toStringSlice(spec["filaments"]) {
		f, ok := idx.Resolve("filament", name)
		if !ok {
			return errors.New(L("Filamentprofil nicht gefunden: ", "Filament profile not found: ") + name)
		}
		filaments = append(filaments, f)
	}
	if len(filaments) == 0 {
		return errors.New(L("Kein Filamentprofil gewählt", "No filament profile chosen"))
	}
	for _, res := range append([]Resolved{machine, process}, filaments...) {
		if res.MissingParent != "" {
			return fmt.Errorf(L("Profil \"%v\" erbt von \"%s\", das nicht gefunden wurde", "Profile \"%v\" inherits from \"%s\", which was not found"), res.Dict["name"], res.MissingParent)
		}
	}
	// Make process/filaments compatible with a user-renamed machine.
	machineNames := []string{machineName}
	if inh, _ := machine.Dict["inherits"].(string); inh != "" {
		machineNames = append(machineNames, inh)
	}
	process.Dict["compatible_printers"] = unionStrings(toStringSlice(process.Dict["compatible_printers"]), machineNames)
	for i := range filaments {
		filaments[i].Dict["compatible_printers"] = unionStrings(toStringSlice(filaments[i].Dict["compatible_printers"]), machineNames)
	}
	machine.Dict["thumbnails"] = []string{} // no OpenGL headless
	harmonise(filaments, toStringSlice(spec["filament_colours"]))

	writeJSON := func(obj JSONObject, name string) (string, error) {
		p := filepath.Join(job.Dir, name)
		b, err := json.Marshal(obj)
		if err != nil {
			return "", err
		}
		return p, os.WriteFile(p, b, 0o644)
	}
	job.set(func() { job.Stage = "model"; job.Progress = 0.1 })
	modelPath := filepath.Join(job.Dir, "input.3mf")
	var objs []ThreeMFObject
	if list, ok := spec["objects"].([]any); ok {
		for _, e := range list {
			o, ok := e.(JSONObject)
			if !ok {
				continue
			}
			mid, _ := o["model"].(string)
			if mid == "" {
				continue
			}
			stl, err := os.ReadFile(filepath.Join(r.ModelsDir, filepath.Base(mid)))
			if err != nil {
				return errors.New(L("Modell fehlt: ", "Model missing: ") + mid)
			}
			paint := map[int]string{}
			if pm, ok := o["paint"].(JSONObject); ok {
				for k, v := range pm {
					if i, err := strconv.Atoi(k); err == nil {
						if s, ok := v.(string); ok {
							paint[i] = s
						}
					}
				}
			}
			settings := map[string]string{}
			if sm, ok := o["settings"].(JSONObject); ok {
				for k, v := range sm {
					switch x := v.(type) {
					case string:
						settings[k] = x
					case float64:
						settings[k] = strconv.FormatFloat(x, 'f', -1, 64)
					case bool:
						if x {
							settings[k] = "1"
						} else {
							settings[k] = "0"
						}
					}
				}
			}
			name, _ := o["name"].(string)
			if name == "" {
				name = "object"
			}
			var transform []float64
			if tl, ok := o["transform"].([]any); ok {
				for _, t := range tl {
					if f, ok := t.(float64); ok {
						transform = append(transform, f)
					}
				}
			}
			ext := 0
			if f, ok := numOf(o["extruder"]); ok {
				ext = int(f)
			}
			objs = append(objs, ThreeMFObject{Name: name, STL: stl, Transform: transform, Extruder: ext, Paint: paint, Settings: settings})
		}
	}
	if len(objs) == 0 {
		return errors.New(L("Keine Objekte", "No objects"))
	}
	threeMF, err := buildThreeMF(objs)
	if err != nil {
		return err
	}
	if err := os.WriteFile(modelPath, threeMF, 0o644); err != nil {
		return err
	}
	multi, _ := spec["multi"].(bool)
	if multi {
		// The tower where the phone shows it; else the first free corner.
		if t, ok := spec["wipe_tower"].([]any); ok && len(t) == 2 {
			x, _ := numOf(t[0])
			y, _ := numOf(t[1])
			process.Dict["wipe_tower_x"] = []string{fmt.Sprintf("%.1f", x)}
			process.Dict["wipe_tower_y"] = []string{fmt.Sprintf("%.1f", y)}
		} else {
			placePrimeTower(&process, machine.Dict, objs)
		}
	}

	machinePath, err := writeJSON(machine.Dict, "machine.json")
	if err != nil {
		return err
	}
	processPath, err := writeJSON(process.Dict, "process.json")
	if err != nil {
		return err
	}
	var filPaths []string
	for i, f := range filaments {
		p, err := writeJSON(f.Dict, fmt.Sprintf("filament_%d.json", i))
		if err != nil {
			return err
		}
		filPaths = append(filPaths, p)
	}
	logPath := filepath.Join(job.Dir, "orca.log")
	args := []string{modelPath,
		"--load-settings", machinePath + ";" + processPath,
		"--load-filaments", strings.Join(filPaths, ";"),
		"--arrange", "0", "--slice", "0",
		"--outputdir", job.Dir, "--debug", "2", "--logfile", logPath}
	if ov, ok := spec["overrides"].(JSONObject); ok {
		for _, o := range overrides {
			if v, ok := ov[o.key]; ok {
				if a := overrideFlag(o.flag, o.kind, v); a != "" {
					args = append(args, a)
				}
			}
		}
	}
	// One head: the plate is sliced for T0 and the G-code rewritten to
	// the chosen head afterwards (the U1 toolkit's route). Several
	// heads (objects or painted faces): four filaments in head order,
	// Orca does the tool changes itself — no rewrite.
	head := 1
	if !multi {
		if f, ok := numOf(spec["head"]); ok {
			head = int(math.Max(1, math.Min(4, f)))
		}
	}
	_ = os.WriteFile(filepath.Join(job.Dir, "cmd.txt"), []byte(bin+" "+strings.Join(args, " ")), 0o644)

	job.set(func() { job.Stage = "slice"; job.Progress = 0.2 })
	cmd := exec.Command(bin, args...)
	cmd.Dir = job.Dir
	hideConsole(cmd)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("OrcaSlicer: %w", err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	stages := []struct {
		marker string
		v      float64
	}{{"Slicing", 0.3}, {"Generating perimeters", 0.45}, {"Infilling", 0.6}, {"Generating support", 0.7}, {"Generating G-code", 0.85}, {"export_gcode finished", 0.95}}
	var waitErr error
loop:
	for {
		select {
		case waitErr = <-done:
			break loop
		case <-time.After(400 * time.Millisecond):
			if txt := tailOfFile(logPath, 20000); txt != "" {
				for _, s := range stages {
					if strings.Contains(txt, s.marker) {
						job.set(func() {
							if s.v > job.Progress {
								job.Progress = s.v
							}
						})
					}
				}
			}
		}
	}
	gcode := ""
	if entries, err := os.ReadDir(job.Dir); err == nil {
		for _, e := range entries {
			if strings.EqualFold(filepath.Ext(e.Name()), ".gcode") {
				gcode = filepath.Join(job.Dir, e.Name())
				break
			}
		}
	}
	code := 0
	if waitErr != nil {
		var ee *exec.ExitError
		if errors.As(waitErr, &ee) {
			code = normaliseExit(ee.ExitCode())
		} else {
			return fmt.Errorf("OrcaSlicer: %w", waitErr)
		}
	}
	if code != 0 || gcode == "" {
		if code == 0 {
			code = 1
		}
		c := code
		job.set(func() { job.ErrorCode = &c })
		msg := fmt.Sprintf("Orca Exit %d", code)
		if known := exitText(code); known != "" {
			msg += " – " + known
		} else if txt := tailOfFile(logPath, 200000); txt != "" {
			var errs []string
			for _, line := range strings.Split(txt, "\n") {
				if strings.Contains(strings.ToLower(line), "error") {
					if len(line) > 160 {
						line = line[len(line)-160:]
					}
					errs = append(errs, line)
				}
			}
			if len(errs) > 3 {
				errs = errs[len(errs)-3:]
			}
			if len(errs) > 0 {
				msg += ": " + strings.Join(errs, " | ")
			}
		}
		return errors.New(msg)
	}
	if head > 1 {
		if err := rewriteTool(gcode, head-1); err != nil {
			return err
		}
	}
	summary := summaryOf(gcode)
	summary["gcode"] = filepath.Base(gcode)
	if fi, err := os.Stat(gcode); err == nil {
		summary["size"] = fi.Size()
	} else {
		summary["size"] = 0
	}
	job.set(func() { job.Result = summary; job.State = "done"; job.Progress = 1; job.Stage = "done" })
	return nil
}

// Orca's CLI returns the negative codes from Utils.hpp. A Mac shell shows
// them as 256 + code, Windows as a 32-bit wrap-around; the phone expects
// the Mac form, so both are folded into it.
func normaliseExit(code int) int {
	if code > 0x7fffffff {
		code -= 0x100000000
	}
	if code < 0 {
		return 256 + code
	}
	return code
}

func tailOfFile(path string, max int64) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return ""
	}
	if fi.Size() > max {
		_, _ = f.Seek(fi.Size()-max, io.SeekStart)
	}
	b, _ := io.ReadAll(f)
	return string(b)
}

func unionStrings(a, b []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range append(append([]string{}, a...), b...) {
		if s != "" && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	if out == nil {
		out = []string{}
	}
	return out
}

// Orca's CLI exit codes that a phone user can actually do something about.
func exitText(code int) string {
	switch code - 256 {
	case -101:
		return L("Druckpfade überschneiden sich: Objekte liegen zu nah beieinander oder ein Objekt kollidiert mit dem Reinigungsturm. Objekte weiter auseinander schieben.",
			"Print paths overlap: objects are too close together or one collides with the prime tower. Move the objects apart.")
	case -102:
		return L("Druckpfade liegen außerhalb des Druckbereichs. Objekt weiter zur Mitte schieben.", "Print paths leave the printable area. Move the object towards the centre.")
	case -100:
		return L("Slicing fehlgeschlagen. Modell in OrcaSlicer prüfen (Geometrie defekt?).", "Slicing failed. Check the model in OrcaSlicer (broken geometry?).")
	case -52:
		return L("Ein Objekt ragt aus dem Druckraum. Objekt verschieben oder verkleinern.", "An object sticks out of the build volume. Move or shrink it.")
	case -50:
		return L("Kein druckbares Objekt auf der Platte.", "No printable object on the plate.")
	case -17:
		return L("Prozessprofil passt nicht zum Drucker. Anderes Profil wählen.", "The process profile does not fit the printer. Choose another one.")
	case -66:
		return L("Filamente konnten den Köpfen nicht zugeordnet werden.", "Filaments could not be assigned to the heads.")
	case -67:
		return L("Nur ein TPU-Filament je Druck möglich.", "Only one TPU filament per print is possible.")
	case -62:
		return L("Filamente mit unterschiedlicher Betttemperatur in einem Druck.", "Filaments with different bed temperatures in one print.")
	case -14:
		return L("OrcaSlicer hat keinen Speicher mehr.", "OrcaSlicer ran out of memory.")
	case -5:
		return L("Profil konnte nicht geladen werden.", "Profile could not be loaded.")
	}
	return ""
}

// Multi-material: Orca puts the prime tower at a fixed default (15, 220)
// — a model there makes the slice fail with "path conflicts" — so the
// tower goes to the first corner nothing occupies.
func placePrimeTower(process *Resolved, machine JSONObject, objects []ThreeMFObject) {
	xs, ys := printableArea(machine)
	if len(xs) == 0 {
		return
	}
	bx0, bx1, by0, by1 := minF(xs), maxF(xs), minF(ys), maxF(ys)
	if bx1-bx0 <= 60 || by1-by0 <= 60 {
		return
	}
	// Footprints on the bed: mesh bounds through the placement, plus a
	// margin for brim and the tower's own brim.
	type box struct{ x0, y0, x1, y1 float64 }
	var boxes []box
	for _, o := range objects {
		verts, _ := readSTL(o.STL)
		if len(verts) == 0 || len(o.Transform) != 16 {
			continue
		}
		m := o.Transform
		lo := [2]float64{math.Inf(1), math.Inf(1)}
		hi := [2]float64{math.Inf(-1), math.Inf(-1)}
		for _, v := range verts {
			x := m[0]*float64(v.X) + m[4]*float64(v.Y) + m[8]*float64(v.Z) + m[12]
			y := m[1]*float64(v.X) + m[5]*float64(v.Y) + m[9]*float64(v.Z) + m[13]
			lo[0], lo[1] = math.Min(lo[0], x), math.Min(lo[1], y)
			hi[0], hi[1] = math.Max(hi[0], x), math.Max(hi[1], y)
		}
		boxes = append(boxes, box{lo[0] - 12, lo[1] - 12, hi[0] + 12, hi[1] + 12})
	}
	width := 30.0
	if s, ok := process.Dict["prime_tower_width"].(string); ok {
		if w, err := strconv.ParseFloat(s, 64); err == nil {
			width = w
		}
	}
	depth, inset := 50.0, 12.0 // grows with the purges; Orca's default leaves this much
	candidates := [][2]float64{{bx0 + inset, by1 - inset - depth}, {bx1 - inset - width, by1 - inset - depth},
		{bx0 + inset, by0 + inset}, {bx1 - inset - width, by0 + inset}}
	for y := by1 - inset - depth; y >= by0+inset; y -= 20 {
		for x := bx0 + inset; x <= bx1-inset-width; x += 20 {
			candidates = append(candidates, [2]float64{x, y})
		}
	}
	for _, c := range candidates {
		x, y := c[0], c[1]
		free := true
		for _, b := range boxes {
			if x < b.x1 && x+width > b.x0 && y < b.y1 && y+depth > b.y0 {
				free = false
				break
			}
		}
		if free {
			process.Dict["wipe_tower_x"] = []string{fmt.Sprintf("%.1f", x)}
			process.Dict["wipe_tower_y"] = []string{fmt.Sprintf("%.1f", y)}
			return
		}
	}
}

// What Orca's CLI needs from several filament profiles at once, found the
// hard way: (1) it takes the number of extruders from the length of the
// merged `filament_colour` vector, and user presets usually carry no
// colour (it lives in the project) — so every profile gets one, the
// printer's own where known; (2) profiles from different inheritance
// chains have different key sets, which trips "ConfigOptionVector:
// invalid size" — so every key present anywhere is present everywhere,
// gaps filled from the first profile that has it.
func harmonise(filaments []Resolved, colours []string) {
	palette := []string{"#F2754E", "#4A90D9", "#5DBB63", "#E6C229"}
	for i := range filaments {
		own := ""
		if c := toStringSlice(filaments[i].Dict["filament_colour"]); len(c) > 0 {
			own = c[0]
		}
		given := ""
		if i < len(colours) {
			given = colours[i]
			if given != "" && !strings.HasPrefix(given, "#") {
				given = "#" + given
			}
		}
		colour := palette[i%len(palette)]
		if len(given) == 7 {
			colour = given
		} else if len(own) == 7 {
			colour = own
		}
		filaments[i].Dict["filament_colour"] = []string{colour}
	}
	if len(filaments) < 2 {
		return
	}
	var keys []string
	seen := map[string]bool{}
	for _, f := range filaments {
		var own []string
		for k := range f.Dict {
			own = append(own, k)
		}
		sort.Strings(own)
		for _, k := range own {
			if !seen[k] {
				seen[k] = true
				keys = append(keys, k)
			}
		}
	}
	for _, k := range keys {
		var donor any
		for _, f := range filaments {
			if v, ok := f.Dict[k]; ok {
				donor = v
				break
			}
		}
		for i := range filaments {
			if _, ok := filaments[i].Dict[k]; !ok {
				filaments[i].Dict[k] = donor
			}
		}
	}
}

var toolRe = regexp.MustCompile(`(^|[^A-Za-z_0-9])T0([^0-9]|$)`)

// T0 → Tn in every command line (comments untouched): tool selects,
// M104/M109 temperatures with a T parameter, and the header's own
// extruder bookkeeping.
func rewriteTool(path string, tool int) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	text := string(b)
	lines := strings.Split(text, "\n")
	repl := fmt.Sprintf("${1}T%d${2}", tool)
	for i, line := range lines {
		if line == "" || strings.HasPrefix(line, ";") {
			continue
		}
		// A line can hold several T0 tokens (rare); loop until stable.
		for {
			n := toolRe.ReplaceAllString(line, repl)
			if n == line {
				break
			}
			line = n
		}
		lines[i] = line
	}
	return os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0o644)
}

// Time, filament and cost from the footer Orca writes.
func summaryOf(path string) JSONObject {
	out := JSONObject{}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	head := make([]byte, 4096)
	n, _ := f.Read(head)
	headS := string(head[:n])
	fi, _ := f.Stat()
	tailS := ""
	if fi != nil {
		start := int64(0)
		if fi.Size() > 262144 {
			start = fi.Size() - 262144
		}
		_, _ = f.Seek(start, io.SeekStart)
		var sb strings.Builder
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1024*1024), 1024*1024)
		for sc.Scan() {
			sb.WriteString(sc.Text())
			sb.WriteByte('\n')
		}
		tailS = sb.String()
	}
	grab := func(pattern, s string) string {
		re := regexp.MustCompile("(?m)" + pattern)
		m := re.FindStringSubmatch(s)
		if len(m) < 2 {
			return ""
		}
		return strings.TrimSpace(m[1])
	}
	if t := grab(`^; estimated printing time \(normal mode\) = (.+)$`, tailS); t != "" {
		secs := 0
		re := regexp.MustCompile(`(\d+)([dhms])`)
		units := map[string]int{"d": 86400, "h": 3600, "m": 60, "s": 1}
		for _, m := range re.FindAllStringSubmatch(t, -1) {
			n, _ := strconv.Atoi(m[1])
			secs += n * units[m[2]]
		}
		out["time_s"] = secs
	}
	parseList := func(s string) []float64 {
		var v []float64
		for _, p := range strings.Split(s, ",") {
			if f, err := strconv.ParseFloat(strings.TrimSpace(p), 64); err == nil {
				v = append(v, f)
			}
		}
		return v
	}
	if g := grab(`^; filament used \[g\] = (.+)$`, tailS); g != "" {
		out["filament_g_tools"] = parseList(g)
	}
	if g := grab(`^; total filament used \[g\] = ([\d.]+)`, tailS); g != "" {
		if v, err := strconv.ParseFloat(g, 64); err == nil {
			out["filament_g"] = v
		}
	}
	if mm := grab(`^; filament used \[mm\] = (.+)$`, tailS); mm != "" {
		sum := 0.0
		for _, v := range parseList(mm) {
			sum += v
		}
		out["filament_mm"] = sum
	}
	if c := grab(`^; total filament cost = ([\d.]+)`, tailS); c != "" {
		if v, err := strconv.ParseFloat(c, 64); err == nil {
			out["cost"] = v
		}
	}
	if l := grab(`^; total layer number: (\d+)`, headS); l != "" {
		if v, err := strconv.Atoi(l); err == nil {
			out["layers"] = v
		}
	}
	if h := grab(`^; max_z_height: ([\d.]+)`, headS); h != "" {
		if v, err := strconv.ParseFloat(h, 64); err == nil {
			out["height_mm"] = v
		}
	}
	sup := map[string]string{}
	for _, key := range []string{"enable_support", "support_type", "support_style", "support_on_build_plate_only"} {
		if v := grab(`^; `+key+` = (.+)$`, tailS); v != "" {
			sup[key] = v
		}
	}
	if len(sup) > 0 {
		out["support"] = sup
	}
	return out
}
