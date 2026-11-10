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
)

type JSONObject = map[string]any

type OrcaApp struct {
	Key      string // "orca"
	DataDir  string
	ConfName string
}

var profileKinds = []string{"machine", "process", "filament"}

// Two profile sources, one chosen on this PC (the status page's "Profiles
// from", like the Linux version's --slicer): OrcaSlicer, or Snapmaker Orca.
// One source at a time — reading both at once split the presets (a Snapmaker
// printer took its profiles from one folder, the filaments saved in the other
// were missing). The other app's system profiles only fill in parents.
func allOrcaApps() []OrcaApp {
	base := orcaDataBase()
	return []OrcaApp{
		{Key: "orca", DataDir: filepath.Join(base, "OrcaSlicer"), ConfName: "OrcaSlicer.conf"},
		{Key: "snapmaker_orca", DataDir: filepath.Join(base, "Snapmaker_Orca"), ConfName: "Snapmaker_Orca.conf"},
	}
}

func (a OrcaApp) DisplayName() string {
	if a.Key == "snapmaker_orca" {
		return "Snapmaker Orca"
	}
	return "OrcaSlicer"
}

// The source used when the phone does not name one: PAXX_APP, else the choice
// saved in the state folder ("slicer", as the Linux version), else OrcaSlicer.
func defaultAppKey() string {
	apps := installedOrcaApps()
	want := os.Getenv("PAXX_APP")
	if want == "" && state != nil {
		if b, err := os.ReadFile(filepath.Join(state.StateDir, "slicer")); err == nil {
			want = strings.TrimSpace(string(b))
		}
	}
	if want == "" {
		want = "orca"
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

func setDefaultAppKey(key string) error {
	if state == nil {
		return os.ErrInvalid
	}
	return os.WriteFile(filepath.Join(state.StateDir, "slicer"), []byte(key+"\n"), 0o644)
}

// Installed sources, the chosen one first (the app takes the first).
func orderedOrcaApps() []OrcaApp {
	def := defaultAppKey()
	var first, rest []OrcaApp
	for _, a := range installedOrcaApps() {
		if a.Key == def {
			first = append(first, a)
		} else {
			rest = append(rest, a)
		}
	}
	return append(first, rest...)
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
	// User presets: their parent's setting_id from Orca's .info file, and the
	// vendor that parent belongs to (set in linkUserVendors).
	baseID string
	vendor string
}

type ProfileIndex struct {
	App    OrcaApp
	byName map[string]map[string]presetEntry // kind → name → entry
	// System presets by vendor as well: kind → name → vendor → dict. Vendors
	// reuse names for different presets (Creality and OrcaFilamentLibrary both
	// define "fdm_filament_pla", with different values) — a parent is looked up
	// at its child's vendor first, as Orca does.
	system       map[string]map[string]map[string]JSONObject
	bundleLoaded bool
}

func NewProfileIndex(app OrcaApp) *ProfileIndex {
	idx := &ProfileIndex{App: app, byName: map[string]map[string]presetEntry{},
		system: map[string]map[string]map[string]JSONObject{}}
	for _, k := range profileKinds {
		idx.byName[k] = map[string]presetEntry{}
		idx.system[k] = map[string]map[string]JSONObject{}
	}
	idx.scan()
	return idx
}

func (idx *ProfileIndex) add(kind, path, origin, vendor string) {
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
	if origin == "system" {
		idx.addSystem(kind, name, obj, vendor)
	}
	e := presetEntry{dict: obj, origin: origin}
	if origin == "user" {
		e.baseID = infoBaseID(path)
	}
	if _, dup := idx.byName[kind][name]; !dup {
		idx.byName[kind][name] = e
	}
}

// The base_id line of the .info file Orca keeps next to a user preset: the
// setting_id of the system preset it inherits from.
func infoBaseID(path string) string {
	info, err := os.ReadFile(strings.TrimSuffix(path, filepath.Ext(path)) + ".info")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(info), "\n") {
		if k, v, ok := strings.Cut(line, "="); ok && strings.TrimSpace(k) == "base_id" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// Names repeat across vendors ("Generic PETG" is in BBL and in Snapmaker),
// so a user preset's parent is the system preset with its name AND the
// setting_id its .info names — the way Orca links them. Without that a U1
// filament could resolve to Bambu's preset and be hidden as Bambu-only.
// (Thanks to Megarushing, PR #3.)
func (idx *ProfileIndex) linkUserVendors() {
	for kind, m := range idx.byName {
		for name, e := range m {
			if e.origin != "user" || e.baseID == "" {
				continue
			}
			parent, _ := e.dict["inherits"].(string)
			all := idx.system[kind][parent]
			vendors := make([]string, 0, len(all))
			for v := range all {
				vendors = append(vendors, v)
			}
			sort.Strings(vendors)
			for _, v := range vendors {
				if id, _ := all[v]["setting_id"].(string); id == e.baseID {
					e.vendor = v
					m[name] = e
					break
				}
			}
		}
	}
}

func (idx *ProfileIndex) addSystem(kind, name string, obj JSONObject, vendor string) {
	m := idx.system[kind][name]
	if m == nil {
		m = map[string]JSONObject{}
		idx.system[kind][name] = m
	}
	if _, ok := m[vendor]; !ok {
		m[vendor] = obj
	}
}

// A system preset for `name`, preferring the given vendor, then Orca's own
// filament library, then any vendor (in a fixed order).
func (idx *ProfileIndex) systemEntry(kind, name, vendor string) (JSONObject, string, bool) {
	all := idx.system[kind][name]
	if len(all) == 0 {
		return nil, "", false
	}
	if vendor != "" {
		if d, ok := all[vendor]; ok {
			return d, vendor, true
		}
	}
	if d, ok := all["OrcaFilamentLibrary"]; ok {
		return d, "OrcaFilamentLibrary", true
	}
	keys := make([]string, 0, len(all))
	for k := range all {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return all[keys[0]], keys[0], true
}

// The presets of one OrcaSlicer 2.5 cache file (<vendor>.opc), as their JSON
// would read.
func (idx *ProfileIndex) addCache(path string) {
	entries := readOPC(path)
	vendor := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	for _, e := range entries {
		obj := e.Values
		obj["name"] = e.Name
		obj["from"] = "system"
		if e.Inherits != "" {
			obj["inherits"] = e.Inherits
		}
		if len(e.Includes) > 0 {
			inc := make([]any, len(e.Includes))
			for i, s := range e.Includes {
				inc[i] = s
			}
			obj["include"] = inc
		}
		if e.Instantiation != "" {
			obj["instantiation"] = e.Instantiation
		}
		if e.SettingID != "" {
			obj["setting_id"] = e.SettingID
		}
		if e.FilamentID != "" {
			obj["filament_id"] = e.FilamentID
		}
		if idx.byName[e.Kind] == nil {
			continue
		}
		idx.addSystem(e.Kind, e.Name, obj, vendor)
		if _, dup := idx.byName[e.Kind][e.Name]; !dup {
			idx.byName[e.Kind][e.Name] = presetEntry{dict: obj, origin: "system"}
		}
	}
}

// Caches shipped inside OrcaSlicer itself — only read when a chain reaches a
// vendor the data folder does not carry.
func (idx *ProfileIndex) loadBundleCaches() {
	if idx.bundleLoaded {
		return
	}
	idx.bundleLoaded = true
	for _, f := range orcaBundleCaches() {
		idx.addCache(f)
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
			if !v.IsDir() && strings.EqualFold(filepath.Ext(v.Name()), ".opc") {
				idx.addCache(filepath.Join(sysRoot, v.Name()))
				continue
			}
			for _, kind := range profileKinds {
				for _, f := range jsonFilesUnder(filepath.Join(sysRoot, v.Name(), kind)) {
					idx.add(kind, f, "system", v.Name())
				}
			}
		}
	}
	idx.linkUserVendors()
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
	return idx.resolve(kind, name, 0, "")
}

func (idx *ProfileIndex) resolve(kind, name string, depth int, vendor string) (Resolved, bool) {
	if _, ok := idx.byName[kind][name]; !ok && depth > 0 {
		idx.loadBundleCaches()
	}
	if depth >= 20 {
		return Resolved{}, false
	}
	// A user preset by that name wins at the top; parents are system presets,
	// taken from the child's vendor where it has one.
	var d JSONObject
	var origin, myVendor string
	if e, ok := idx.byName[kind][name]; ok && depth == 0 && e.origin == "user" {
		d, origin, myVendor = e.dict, e.origin, e.vendor
	} else if sd, v, ok := idx.systemEntry(kind, name, vendor); ok {
		d, origin, myVendor = sd, "system", v
	} else if e, ok := idx.byName[kind][name]; ok {
		d, origin, myVendor = e.dict, e.origin, e.vendor
	} else {
		return Resolved{}, false
	}
	parentVendor := myVendor
	if parentVendor == "" {
		parentVendor = vendor
	}
	out := JSONObject{}
	missing := ""
	if parent, _ := d["inherits"].(string); parent != "" {
		if base, ok := idx.resolve(kind, parent, depth+1, parentVendor); ok {
			out = base.Dict
			missing = base.MissingParent
		} else {
			missing = parent
		}
	}
	// Presets an OrcaSlicer 2.5 profile includes lie under its own values.
	for _, inc := range toStringSlice(d["include"]) {
		if i, ok := idx.resolve(kind, inc, depth+1, parentVendor); ok {
			for k, v := range i.Dict {
				switch k {
				case "name", "inherits", "from", "instantiation", "setting_id", "filament_id", "include", "type":
					continue
				}
				out[k] = v
			}
		}
	}
	for k, v := range d {
		if k != "inherits" && k != "include" {
			out[k] = v
		}
	}
	out["name"] = name
	// The preset kind — system JSONs carried it, the 2.5 caches do not, and
	// the CLI refuses a file without it.
	out["type"] = kind
	if origin == "system" {
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
// Once a user preset's vendor is known, the chain stays inside it.
func (idx *ProfileIndex) effectiveCompatible(kind, name string) []string {
	e, ok := idx.byName[kind][name]
	if !ok {
		return nil
	}
	d, vendor := e.dict, e.vendor
	for i := 0; i < 20; i++ {
		if c, ok := d["compatible_printers"]; ok {
			if _, isList := c.([]any); isList {
				return toStringSlice(c)
			}
		}
		p, _ := d["inherits"].(string)
		if p == "" {
			return nil
		}
		if pe, ok := idx.byName[kind][p]; ok && pe.origin == "user" {
			d = pe.dict
			if pe.vendor != "" {
				vendor = pe.vendor
			}
			continue
		}
		if vendor != "" {
			if sd, v, ok := idx.systemEntry(kind, p, vendor); ok {
				d, vendor = sd, v
				continue
			}
		}
		pe, ok := idx.byName[kind][p]
		if !ok {
			return nil
		}
		d = pe.dict
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
	if l, ok := v.([]string); ok {
		return l
	}
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
