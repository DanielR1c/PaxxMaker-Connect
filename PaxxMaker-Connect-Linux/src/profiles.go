package main

// Orca profile resolver. User presets are thin overlays with `inherits`; the
// CLI wants complete JSON. This indexes the system and user profiles of an
// Orca install and flattens an inheritance chain into one dictionary.
// Behaves like the GUI's drop-downs: user presets always, system filaments
// only when ticked in the wizard, system printers only when used before.
// (Same logic as Profiles.swift of the Mac version.)

import (
	"bytes"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
)

type JSONObject = map[string]any

type OrcaApp struct {
	Key      string // "orca"
	DataDir  string
	ConfName string
}

var profileKinds = []string{"machine", "process", "filament"}

// Snapmaker Orca first when it is installed (it then is the default source
// and slicer), OrcaSlicer after it. --slicer / PAXX_APP pick the default.
func allOrcaApps() []OrcaApp {
	base := orcaDataBase()
	var out []OrcaApp
	if snapmakerOrcaBinary() != "" {
		out = append(out, OrcaApp{Key: "snapmaker_orca", DataDir: filepath.Join(base, "Snapmaker_Orca"), ConfName: "Snapmaker_Orca.conf"})
	}
	return append(out, OrcaApp{Key: "orca", DataDir: filepath.Join(base, "OrcaSlicer"), ConfName: "OrcaSlicer.conf"})
}

// The source used when the phone does not name one: PAXX_APP, else the
// choice saved with --slicer, else the first installed.
func defaultAppKey() string {
	apps := installedOrcaApps()
	want := os.Getenv("PAXX_APP")
	if want == "" && state != nil {
		if b, err := os.ReadFile(filepath.Join(state.StateDir, "slicer")); err == nil {
			want = strings.TrimSpace(string(b))
		}
	}
	for _, a := range apps {
		if a.Key == want {
			return want
		}
	}
	if len(apps) > 0 {
		return apps[0].Key
	}
	return "orca"
}

func installedOrcaApps() []OrcaApp {
	var out []OrcaApp
	for _, a := range allOrcaApps() {
		if fileExists(a.DataDir) {
			out = append(out, a)
		}
	}
	return out
}

func orcaAppNamed(key string) (OrcaApp, bool) {
	for _, a := range installedOrcaApps() {
		if a.Key == key {
			return a, true
		}
	}
	return OrcaApp{}, false
}

type presetEntry struct {
	dict   JSONObject
	origin string // "user" / "system"
	hidden bool   // unpacked from an AppImage: resolves inherits, never listed
	vendor string // system vendor folder; parents resolve inside it first
	baseID string // user preset's .info base_id = its parent's setting_id
}

type ProfileIndex struct {
	App    OrcaApp
	byName map[string]map[string]presetEntry // kind → name → entry
	// Names are not unique across vendors ("Generic PETG" is in BBL and
	// Snapmaker), so parents are looked up the way Orca does: a user preset
	// by its .info base_id, a system preset inside its own vendor.
	byID     map[string]map[string]presetEntry // kind → setting_id+"/"+name → entry (ids repeat too)
	byVendor map[string]map[string]presetEntry // kind → vendor+"/"+name → entry
}

func NewProfileIndex(app OrcaApp) *ProfileIndex {
	idx := &ProfileIndex{App: app, byName: map[string]map[string]presetEntry{},
		byID: map[string]map[string]presetEntry{}, byVendor: map[string]map[string]presetEntry{}}
	for _, k := range profileKinds {
		idx.byName[k] = map[string]presetEntry{}
		idx.byID[k] = map[string]presetEntry{}
		idx.byVendor[k] = map[string]presetEntry{}
	}
	idx.scan()
	return idx
}

func (idx *ProfileIndex) add(kind, path, origin, vendor string) {
	if name, obj := readPreset(path); obj != nil {
		e := presetEntry{dict: obj, origin: origin, vendor: vendor}
		if origin == "user" {
			e.baseID = infoBaseID(strings.TrimSuffix(path, filepath.Ext(path)) + ".info")
		}
		idx.put(kind, name, e)
	}
}

func (idx *ProfileIndex) put(kind, name string, e presetEntry) {
	if _, dup := idx.byName[kind][name]; !dup {
		idx.byName[kind][name] = e
	}
	if e.origin != "system" {
		return
	}
	if id, _ := e.dict["setting_id"].(string); id != "" {
		if _, dup := idx.byID[kind][id+"/"+name]; !dup {
			idx.byID[kind][id+"/"+name] = e
		}
	}
	if e.vendor != "" {
		if _, dup := idx.byVendor[kind][e.vendor+"/"+name]; !dup {
			idx.byVendor[kind][e.vendor+"/"+name] = e
		}
	}
}

// Orca writes a "<preset>.info" next to each user preset; its base_id is
// the setting_id of the system preset it was derived from.
func infoBaseID(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		if k, v, ok := strings.Cut(line, "="); ok && strings.TrimSpace(k) == "base_id" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// The entry a preset inherits from, or ok=false when it has no parent.
// found=false means the parent is named but missing.
func (idx *ProfileIndex) parent(kind string, e presetEntry) (p presetEntry, name string, ok, found bool) {
	name, _ = e.dict["inherits"].(string)
	if name == "" {
		return presetEntry{}, "", false, false
	}
	if e.baseID != "" {
		if b, hit := idx.byID[kind][e.baseID+"/"+name]; hit {
			return b, name, true, true
		}
	}
	if e.vendor != "" {
		if b, hit := idx.byVendor[kind][e.vendor+"/"+name]; hit {
			return b, name, true, true
		}
	}
	b, hit := idx.byName[kind][name]
	return b, name, true, hit
}

func readPreset(path string) (string, JSONObject) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", nil
	}
	var obj JSONObject
	if json.Unmarshal(b, &obj) != nil || obj == nil {
		return "", nil
	}
	name, _ := obj["name"].(string)
	if name == "" {
		name = strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	}
	return name, obj
}

// The AppImage vendor trees hold ~10,000 presets each and never change for
// one AppImage, so they are parsed once per folder and kept (kind → name).
var (
	bundledIdxMu sync.Mutex
	bundledIdx   = map[string]map[string][]bundledPreset{}
)

type bundledPreset struct {
	name, vendor string
	obj          JSONObject
}

func bundledPresets(root string) map[string][]bundledPreset {
	bundledIdxMu.Lock()
	defer bundledIdxMu.Unlock()
	// Keyed by the folder's time too: a new AppImage is unpacked afresh.
	key := root
	if fi, err := os.Stat(root); err == nil {
		key += fi.ModTime().String()
	}
	if m, ok := bundledIdx[key]; ok {
		return m
	}
	m := map[string][]bundledPreset{}
	vendors, _ := os.ReadDir(root)
	for _, v := range vendors {
		for _, kind := range profileKinds {
			for _, f := range jsonFilesUnder(filepath.Join(root, v.Name(), kind)) {
				if name, obj := readPreset(f); obj != nil {
					m[kind] = append(m[kind], bundledPreset{name, v.Name(), obj})
				}
			}
		}
	}
	bundledIdx[key] = m
	return m
}

func jsonFilesUnder(dir string) []string {
	var out []string
	_ = filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() && strings.EqualFold(filepath.Ext(p), ".json") {
			out = append(out, p)
		}
		return nil
	})
	sort.Strings(out)
	return out
}

func (idx *ProfileIndex) scan() {
	// User presets first so they win over a same-named system one.
	userRoot := filepath.Join(idx.App.DataDir, "user")
	if dirs, err := os.ReadDir(userRoot); err == nil {
		for _, d := range dirs {
			for _, kind := range profileKinds {
				for _, f := range jsonFilesUnder(filepath.Join(userRoot, d.Name(), kind)) {
					idx.add(kind, f, "user", "")
				}
			}
		}
	}
	// System: own app first, then the other Orca's as a fallback for chains
	// that reach a vendor only it ships (an Ender profile saved in
	// Snapmaker Orca inherits Creality's).
	apps := []OrcaApp{idx.App}
	for _, a := range installedOrcaApps() {
		if a.Key != idx.App.Key {
			apps = append(apps, a)
		}
	}
	for _, a := range apps {
		sysRoot := filepath.Join(a.DataDir, "system")
		vendors, err := os.ReadDir(sysRoot)
		if err != nil {
			continue
		}
		for _, v := range vendors {
			for _, kind := range profileKinds {
				for _, f := range jsonFilesUnder(filepath.Join(sysRoot, v.Name(), kind)) {
					idx.add(kind, f, "system", v.Name())
				}
			}
		}
	}
	// The AppImage copies come last, so they never shadow a listed preset.
	for _, a := range apps {
		if root := bundledProfiles(a.Key); root != "" {
			for kind, list := range bundledPresets(root) {
				for _, b := range list {
					idx.put(kind, b.name, presetEntry{dict: b.obj, origin: "system", hidden: true, vendor: b.vendor})
				}
			}
		}
	}
}

// Orca's own config: which system filaments were ticked, which printers used.
func (idx *ProfileIndex) appConfig() (filaments map[string]bool, machines map[string]bool) {
	filaments, machines = map[string]bool{}, map[string]bool{}
	path := filepath.Join(idx.App.DataDir, idx.App.ConfName)
	b, err := os.ReadFile(path)
	if err != nil {
		return
	}
	// Orca appends a "# MD5 checksum …" line after the closing brace, which
	// makes the file invalid JSON. Cut it off before parsing — otherwise the
	// config never parses and both filters below stay empty, so the app offers
	// every bundled printer and filament instead of the ones actually in use.
	if i := bytes.LastIndexByte(b, '}'); i >= 0 {
		b = b[:i+1]
	}
	var conf JSONObject
	if err := json.Unmarshal(b, &conf); err != nil {
		if state != nil {
			state.Log.Add(L("Orca-Konfiguration nicht lesbar: ", "Cannot read Orca config: ") + err.Error())
		}
		return
	}
	for _, f := range toStringSlice(conf["filaments"]) {
		filaments[f] = true
	}
	if presets, ok := conf["orca_presets"].([]any); ok {
		for _, e := range presets {
			if m, ok := e.(JSONObject); ok {
				if name, ok := m["machine"].(string); ok {
					machines[strings.ReplaceAll(name, "(.3mf)", "")] = true
				}
			}
		}
	}
	if p, ok := conf["presets"].(JSONObject); ok {
		if cur, ok := p["machine"].(string); ok {
			machines[cur] = true
		}
	}
	return
}

type Resolved struct {
	Dict          JSONObject
	MissingParent string
}

// Flattened dict: base chain first, own keys last. `inherits` keeps the
// nearest SYSTEM ancestor — the CLI derives the printer's system name
// from it for its process/printer compatibility check.
func (idx *ProfileIndex) Resolve(kind, name string) (Resolved, bool) {
	e, ok := idx.byName[kind][name]
	if !ok {
		return Resolved{}, false
	}
	return idx.resolve(kind, name, e, 0)
}

func (idx *ProfileIndex) resolve(kind, name string, e presetEntry, depth int) (Resolved, bool) {
	if depth >= 20 {
		return Resolved{}, false
	}
	out := JSONObject{}
	missing := ""
	if pe, parent, has, found := idx.parent(kind, e); has {
		if !found {
			missing = parent
		} else if base, ok := idx.resolve(kind, parent, pe, depth+1); ok {
			out = base.Dict
			missing = base.MissingParent
		} else {
			missing = parent
		}
	}
	for k, v := range e.dict {
		if k != "inherits" {
			out[k] = v
		}
	}
	out["name"] = name
	if e.origin == "system" {
		out["from"] = "system"
	} else {
		out["from"] = "User"
	}
	out["inherits"] = idx.systemAncestor(kind, name, e)
	return Resolved{Dict: out, MissingParent: missing}, true
}

func (idx *ProfileIndex) systemAncestor(kind, name string, e presetEntry) string {
	for i := 0; i < 20; i++ {
		if e.origin == "system" {
			return name
		}
		pe, p, has, found := idx.parent(kind, e)
		if !has || !found {
			return ""
		}
		e, name = pe, p
	}
	return ""
}

type Preset struct {
	Name       string
	Origin     string
	Inherits   string
	Compatible []string // nil = not set anywhere in the chain
	Dict       JSONObject
}

// `compatible_printers` as Orca sees it: the preset's own value, else the
// nearest ancestor's (user presets store only their diff).
func (idx *ProfileIndex) effectiveCompatible(kind, name string) []string {
	e, ok := idx.byName[kind][name]
	if !ok {
		return nil
	}
	for i := 0; i < 20; i++ {
		if c, ok := e.dict["compatible_printers"]; ok {
			if _, isList := c.([]any); isList {
				return toStringSlice(c)
			}
		}
		pe, _, has, found := idx.parent(kind, e)
		if !has || !found {
			return nil
		}
		e = pe
	}
	return nil
}

func (idx *ProfileIndex) Available() map[string][]Preset {
	enabledFilaments, usedMachines := idx.appConfig()
	res := map[string][]Preset{}
	for _, kind := range profileKinds {
		var items []Preset
		for name, e := range idx.byName[kind] {
			if e.hidden {
				continue
			}
			ok := e.origin == "user"
			if e.origin == "system" {
				inst, _ := e.dict["instantiation"].(string)
				sys := strings.EqualFold(inst, "true")
				if kind == "filament" && len(enabledFilaments) > 0 {
					sys = sys && enabledFilaments[name]
				}
				if kind == "machine" && len(usedMachines) > 0 {
					sys = sys && usedMachines[name]
				}
				ok = sys
			}
			if ok {
				inh, _ := e.dict["inherits"].(string)
				items = append(items, Preset{Name: name, Origin: e.origin, Inherits: inh,
					Compatible: idx.effectiveCompatible(kind, name), Dict: e.dict})
			}
		}
		if kind == "machine" && len(usedMachines) > 0 {
			hasSystem := false
			for _, it := range items {
				if it.Origin == "system" {
					hasSystem = true
					break
				}
			}
			if !hasSystem {
				for name, e := range idx.byName[kind] {
					inst, _ := e.dict["instantiation"].(string)
					if e.origin == "system" && !e.hidden && strings.EqualFold(inst, "true") {
						inh, _ := e.dict["inherits"].(string)
						var comp []string
						if _, isList := e.dict["compatible_printers"].([]any); isList {
							comp = toStringSlice(e.dict["compatible_printers"])
						}
						items = append(items, Preset{Name: name, Origin: e.origin, Inherits: inh, Compatible: comp, Dict: e.dict})
					}
				}
			}
		}
		sort.Slice(items, func(a, b int) bool {
			ua, ub := items[a].Origin == "user", items[b].Origin == "user"
			if ua != ub {
				return ua
			}
			return strings.ToLower(items[a].Name) < strings.ToLower(items[b].Name)
		})
		res[kind] = items
	}
	return res
}

// Per-extruder values collected from this printer's own system filaments.
// Thin user presets often lack keys (ramming, cooling, filament_is_support …)
// that Orca needs once several filaments are loaded at once — and no single
// system preset carries them all, so the union of them is used.
func (idx *ProfileIndex) ReferenceFilamentValues(machineNames map[string]bool) JSONObject {
	out := JSONObject{}
	var names []string
	for name, e := range idx.byName["filament"] {
		inst, _ := e.dict["instantiation"].(string)
		if e.origin == "system" && strings.EqualFold(inst, "true") {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	for _, name := range names {
		hit := false
		for _, c := range idx.effectiveCompatible("filament", name) {
			if machineNames[c] {
				hit = true
				break
			}
		}
		if !hit {
			continue
		}
		r, ok := idx.Resolve("filament", name)
		if !ok {
			continue
		}
		for k, v := range r.Dict {
			if !strings.HasPrefix(k, "filament_") {
				continue
			}
			if _, isList := v.([]any); !isList {
				continue
			}
			if _, have := out[k]; !have {
				out[k] = v
			}
		}
	}
	return out
}

// Bed and head count from a machine preset's printable_area.
func (idx *ProfileIndex) MachineInfo(name string) JSONObject {
	out := JSONObject{"name": name}
	r, ok := idx.Resolve("machine", name)
	if !ok {
		return out
	}
	m := r.Dict
	xs, ys := printableArea(m)
	if len(xs) > 0 {
		out["bed_x"] = round1(maxF(xs) - minF(xs))
		out["bed_y"] = round1(maxF(ys) - minF(ys))
	}
	switch h := m["printable_height"].(type) {
	case string:
		if v, err := strconv.ParseFloat(h, 64); err == nil {
			out["bed_z"] = v
		}
	case float64:
		out["bed_z"] = h
	}
	if nd, ok := m["nozzle_diameter"].([]any); ok {
		out["extruders"] = len(nd)
	} else {
		out["extruders"] = 1
	}
	if pm, ok := m["printer_model"].(string); ok {
		out["printer_model"] = pm
	}
	if gf, ok := m["gcode_flavor"].(string); ok {
		out["gcode_flavor"] = gf
	}
	return out
}

// "0x0", "270x0", … → the x and y values of a printable_area.
func printableArea(m JSONObject) (xs, ys []float64) {
	for _, pt := range toStringSlice(m["printable_area"]) {
		p := strings.Split(pt, "x")
		if len(p) != 2 {
			continue
		}
		x, e1 := strconv.ParseFloat(p[0], 64)
		y, e2 := strconv.ParseFloat(p[1], 64)
		if e1 == nil && e2 == nil {
			xs = append(xs, x)
			ys = append(ys, y)
		}
	}
	return
}

func toStringSlice(v any) []string {
	list, ok := v.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(list))
	for _, e := range list {
		if s, ok := e.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func minF(v []float64) float64 {
	m := v[0]
	for _, x := range v {
		if x < m {
			m = x
		}
	}
	return m
}

func maxF(v []float64) float64 {
	m := v[0]
	for _, x := range v {
		if x > m {
			m = x
		}
	}
	return m
}

func round1(v float64) float64 { return math.Round(v*10) / 10 }
