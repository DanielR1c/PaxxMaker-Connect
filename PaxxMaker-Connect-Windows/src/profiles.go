package main

// Orca profile resolver. User presets are thin overlays with `inherits`; the
// CLI wants complete JSON. This indexes the system and user profiles of an
// Orca install and flattens an inheritance chain into one dictionary.
// Behaves like the GUI's drop-downs: user presets always, system filaments
// only when ticked in the wizard, system printers only when used before.
// (Same logic as Profiles.swift of the Mac version.)

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type JSONObject = map[string]any

type OrcaApp struct {
	Key      string // "snapmaker_orca" / "orca"
	DataDir  string
	ConfName string
}

var profileKinds = []string{"machine", "process", "filament"}

// The two Orca flavours that can be installed side by side; only their
// profile folders are read, slicing always uses OrcaSlicer's own binary.
func allOrcaApps() []OrcaApp {
	base := orcaDataBase()
	return []OrcaApp{
		{Key: "snapmaker_orca", DataDir: filepath.Join(base, "Snapmaker_Orca"), ConfName: "Snapmaker_Orca.conf"},
		{Key: "orca", DataDir: filepath.Join(base, "OrcaSlicer"), ConfName: "OrcaSlicer.conf"},
	}
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
}

type ProfileIndex struct {
	App    OrcaApp
	byName map[string]map[string]presetEntry // kind → name → entry
}

func NewProfileIndex(app OrcaApp) *ProfileIndex {
	idx := &ProfileIndex{App: app, byName: map[string]map[string]presetEntry{}}
	for _, k := range profileKinds {
		idx.byName[k] = map[string]presetEntry{}
	}
	idx.scan()
	return idx
}

func (idx *ProfileIndex) add(kind, path, origin string) {
	b, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var obj JSONObject
	if json.Unmarshal(b, &obj) != nil || obj == nil {
		return
	}
	name, _ := obj["name"].(string)
	if name == "" {
		name = strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	}
	if _, dup := idx.byName[kind][name]; !dup {
		idx.byName[kind][name] = presetEntry{dict: obj, origin: origin}
	}
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
					idx.add(kind, f, "user")
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
					idx.add(kind, f, "system")
				}
			}
		}
	}
}

// Orca's own config: which system filaments were ticked, which printers used.
func (idx *ProfileIndex) appConfig() (filaments map[string]bool, machines map[string]bool) {
	filaments, machines = map[string]bool{}, map[string]bool{}
	b, err := os.ReadFile(filepath.Join(idx.App.DataDir, idx.App.ConfName))
	if err != nil {
		return
	}
	var conf JSONObject
	if json.Unmarshal(b, &conf) != nil {
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
	return idx.resolve(kind, name, 0)
}

func (idx *ProfileIndex) resolve(kind, name string, depth int) (Resolved, bool) {
	if depth >= 20 {
		return Resolved{}, false
	}
	e, ok := idx.byName[kind][name]
	if !ok {
		return Resolved{}, false
	}
	out := JSONObject{}
	missing := ""
	if parent, _ := e.dict["inherits"].(string); parent != "" {
		if base, ok := idx.resolve(kind, parent, depth+1); ok {
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
	out["inherits"] = idx.systemAncestor(kind, name)
	return Resolved{Dict: out, MissingParent: missing}, true
}

func (idx *ProfileIndex) systemAncestor(kind, name string) string {
	cur := name
	for i := 0; i < 20; i++ {
		e, ok := idx.byName[kind][cur]
		if !ok {
			return ""
		}
		if e.origin == "system" {
			return cur
		}
		p, _ := e.dict["inherits"].(string)
		if p == "" {
			return ""
		}
		cur = p
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
	cur := name
	for i := 0; i < 20; i++ {
		e, ok := idx.byName[kind][cur]
		if !ok {
			return nil
		}
		if c, ok := e.dict["compatible_printers"]; ok {
			if _, isList := c.([]any); isList {
				return toStringSlice(c)
			}
		}
		p, _ := e.dict["inherits"].(string)
		if p == "" {
			return nil
		}
		cur = p
	}
	return nil
}

func (idx *ProfileIndex) Available() map[string][]Preset {
	enabledFilaments, usedMachines := idx.appConfig()
	res := map[string][]Preset{}
	for _, kind := range profileKinds {
		var items []Preset
		for name, e := range idx.byName[kind] {
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
					if e.origin == "system" && strings.EqualFold(inst, "true") {
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
