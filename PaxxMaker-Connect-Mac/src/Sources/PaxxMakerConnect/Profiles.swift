import Foundation

// Orca profile resolver. User presets are thin overlays with `inherits`; the
// CLI wants complete JSON. This indexes the system and user profiles of an
// Orca install and flattens an inheritance chain into one dictionary.
// System profiles come as JSON files (OrcaSlicer up to 2.4) or packed into
// <vendor>.opc preset caches (OrcaSlicer 2.5, see OrcaPresetCache).
// Behaves like the GUI's drop-downs: user presets always, system filaments
// only when ticked in the wizard, system printers only when used before.

struct OrcaApp {
    let key: String          // "snapmaker_orca" / "orca"
    let dataDir: URL
    let confName: String

    // Two profile sources, one chosen on the computer (menu "Profiles from",
    // like the Linux version's --slicer): OrcaSlicer, or Snapmaker Orca. One
    // source at a time — reading both at once split the presets (the U1 took
    // its profiles from one folder, the filaments saved in the other were
    // missing). The other app's system profiles only fill in parents.
    static let all: [OrcaApp] = {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return [OrcaApp(key: "orca", dataDir: base.appendingPathComponent("OrcaSlicer"), confName: "OrcaSlicer.conf"),
                OrcaApp(key: "snapmaker_orca", dataDir: base.appendingPathComponent("Snapmaker_Orca"), confName: "Snapmaker_Orca.conf")]
    }()
    static var installed: [OrcaApp] { all.filter { FileManager.default.fileExists(atPath: $0.dataDir.path) } }
    static func named(_ key: String) -> OrcaApp? { installed.first { $0.key == key } }

    var displayName: String { key == "snapmaker_orca" ? "Snapmaker Orca" : "OrcaSlicer" }

    /// The source chosen on the computer; OrcaSlicer unless changed.
    static var defaultKey: String {
        get {
            let want = UserDefaults.standard.string(forKey: "profile_source") ?? "orca"
            let keys = installed.map(\.key)
            return keys.contains(want) ? want : (keys.first ?? "orca")
        }
        set { UserDefaults.standard.set(newValue, forKey: "profile_source") }
    }
    /// Installed sources, the chosen one first (the app takes the first).
    static var ordered: [OrcaApp] {
        let d = defaultKey
        return installed.filter { $0.key == d } + installed.filter { $0.key != d }
    }
}

typealias JSONObject = [String: Any]

final class ProfileIndex {
    static let kinds = ["machine", "process", "filament"]
    let app: OrcaApp
    /// kind → name → (dict, origin "user"/"system")
    private var byName: [String: [String: (JSONObject, String)]] = ["machine": [:], "process": [:], "filament": [:]]
    /// System presets by vendor as well: kind → name → vendor → dict. Vendors
    /// ship base presets under the same name (Creality and the
    /// OrcaFilamentLibrary both have "fdm_filament_pla", with different
    /// values) — a parent is looked up at its child's vendor first, as Orca does.
    private var system: [String: [String: [String: JSONObject]]] = ["machine": [:], "process": [:], "filament": [:]]
    /// User presets: the setting_id of their parent from Orca's .info file,
    /// and the vendor that parent belongs to (kind → name → …).
    private var userBaseID: [String: [String: String]] = [:]
    private var userVendor: [String: [String: String]] = [:]

    init(app: OrcaApp) {
        self.app = app
        scan()
    }

    private func add(kind: String, url: URL, origin: String, vendor: String = "") {
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? JSONObject else { return }
        let name = obj["name"] as? String ?? url.deletingPathExtension().lastPathComponent
        if origin == "system" { addSystem(kind: kind, name: name, obj: obj, vendor: vendor) }
        if byName[kind]?[name] == nil {
            byName[kind]?[name] = (obj, origin)
            if origin == "user", let id = Self.infoBaseID(url) { userBaseID[kind, default: [:]][name] = id }
        }
    }

    /// The base_id line of the .info file Orca keeps next to a user preset:
    /// the setting_id of the system preset it inherits from.
    private static func infoBaseID(_ url: URL) -> String? {
        guard let info = try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("info"), encoding: .utf8)
        else { return nil }
        for line in info.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "base_id" {
                let v = parts[1].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// Names repeat across vendors ("Generic PETG" is in BBL and in
    /// Snapmaker), so a user preset's parent is the system preset with its
    /// name AND the setting_id its .info names — the way Orca links them.
    /// Without that a U1 filament could resolve to Bambu's preset and be
    /// hidden as Bambu-only. (Thanks to Megarushing, PR #3.)
    private func linkUserVendors() {
        for (kind, ids) in userBaseID {
            for (name, id) in ids {
                guard let parent = byName[kind]?[name]?.0["inherits"] as? String,
                      let all = system[kind]?[parent] else { continue }
                if let v = all.keys.sorted().first(where: { all[$0]?["setting_id"] as? String == id }) {
                    userVendor[kind, default: [:]][name] = v
                }
            }
        }
    }

    private func addSystem(kind: String, name: String, obj: JSONObject, vendor: String) {
        if system[kind]?[name]?[vendor] == nil { system[kind, default: [:]][name, default: [:]][vendor] = obj }
    }

    /// A system preset for `name`, preferring the given vendor, then Orca's
    /// own filament library, then any vendor (in a fixed order).
    private func systemEntry(kind: String, name: String, vendor: String?) -> (JSONObject, String)? {
        guard let all = system[kind]?[name], !all.isEmpty else { return nil }
        if let v = vendor, let d = all[v] { return (d, v) }
        if let d = all["OrcaFilamentLibrary"] { return (d, "OrcaFilamentLibrary") }
        let v = all.keys.sorted()[0]
        return (all[v]!, v)
    }

    /// The presets of one OrcaSlicer 2.5 cache file, as their JSON would read.
    private func addCache(_ url: URL) {
        guard let entries = OrcaPresetCache.read(url) else { return }
        let vendor = url.deletingPathExtension().lastPathComponent
        for e in entries {
            var obj = e.values
            obj["name"] = e.name
            obj["from"] = "system"
            if !e.inherits.isEmpty { obj["inherits"] = e.inherits }
            if !e.includes.isEmpty { obj["include"] = e.includes }
            if !e.instantiation.isEmpty { obj["instantiation"] = e.instantiation }
            if !e.settingID.isEmpty { obj["setting_id"] = e.settingID }
            if !e.filamentID.isEmpty { obj["filament_id"] = e.filamentID }
            addSystem(kind: e.kind, name: e.name, obj: obj, vendor: vendor)
            if byName[e.kind]?[e.name] == nil { byName[e.kind]?[e.name] = (obj, "system") }
        }
    }

    /// Caches shipped inside OrcaSlicer itself — only read when a chain
    /// reaches a vendor the data folder does not carry.
    private var bundleLoaded = false
    private func loadBundleCaches() {
        guard !bundleLoaded else { return }
        bundleLoaded = true
        let dir = URL(fileURLWithPath: Orca.binary).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/profiles")
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension.lowercased() == "opc" { addCache(f) }
    }

    private func jsonFiles(under dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "json" }
    }

    private func scan() {
        let fm = FileManager.default
        // User presets first so they win over a same-named system one.
        let userRoot = app.dataDir.appendingPathComponent("user")
        for userDir in (try? fm.contentsOfDirectory(at: userRoot, includingPropertiesForKeys: nil)) ?? [] {
            for kind in Self.kinds {
                for f in jsonFiles(under: userDir.appendingPathComponent(kind)) { add(kind: kind, url: f, origin: "user") }
            }
        }
        // System: own app first, then the other Orca's as a fallback for chains
        // that reach a vendor only it ships (an Ender profile saved in
        // Snapmaker Orca inherits Creality's).
        for a in [app] + OrcaApp.installed.filter({ $0.key != app.key }) {
            let sysRoot = a.dataDir.appendingPathComponent("system")
            for vendor in (try? fm.contentsOfDirectory(at: sysRoot, includingPropertiesForKeys: nil)) ?? [] {
                if vendor.pathExtension.lowercased() == "opc" { addCache(vendor); continue }
                for kind in Self.kinds {
                    for f in jsonFiles(under: vendor.appendingPathComponent(kind)) {
                        add(kind: kind, url: f, origin: "system", vendor: vendor.lastPathComponent)
                    }
                }
            }
        }
        linkUserVendors()
    }

    /// Orca's own config: which system filaments were ticked, which printers used.
    private func appConfig() -> (filaments: Set<String>, machines: Set<String>) {
        let url = app.dataDir.appendingPathComponent(app.confName)
        guard let d = try? Data(contentsOf: url), let conf = try? JSONSerialization.jsonObject(with: d) as? JSONObject
        else { return ([], []) }
        let fil = Set(conf["filaments"] as? [String] ?? [])
        var machines = Set<String>()
        for e in conf["orca_presets"] as? [JSONObject] ?? [] {
            if let m = e["machine"] as? String { machines.insert(m.replacingOccurrences(of: "(.3mf)", with: "")) }
        }
        if let cur = (conf["presets"] as? JSONObject)?["machine"] as? String { machines.insert(cur) }
        return (fil, machines)
    }

    struct Resolved { var dict: JSONObject; var missingParent: String? }

    /// Flattened dict: base chain first, own keys last. `inherits` keeps the
    /// nearest SYSTEM ancestor — the CLI derives the printer's system name
    /// from it for its process/printer compatibility check.
    func resolve(kind: String, name: String, depth: Int = 0, vendor: String? = nil) -> Resolved? {
        if byName[kind]?[name] == nil, depth > 0 { loadBundleCaches() }
        guard depth < 20 else { return nil }
        // A user preset by that name wins at the top; parents are system
        // presets, taken from the child's vendor where it has one.
        let d: JSONObject, origin: String, myVendor: String?
        if depth == 0, let (u, o) = byName[kind]?[name], o == "user" {
            d = u; origin = o; myVendor = userVendor[kind]?[name]
        } else if let (sd, v) = systemEntry(kind: kind, name: name, vendor: vendor) {
            d = sd; origin = "system"; myVendor = v
        } else if let (u, o) = byName[kind]?[name] {
            d = u; origin = o; myVendor = userVendor[kind]?[name]
        } else {
            return nil
        }
        var out: JSONObject = [:]
        var missing: String? = nil
        if let parent = d["inherits"] as? String, !parent.isEmpty {
            if let base = resolve(kind: kind, name: parent, depth: depth + 1, vendor: myVendor ?? vendor) {
                out = base.dict
                missing = base.missingParent
            } else {
                missing = parent
            }
        }
        // Presets an OrcaSlicer 2.5 profile includes lie under its own values.
        for inc in d["include"] as? [String] ?? [] {
            if let i = resolve(kind: kind, name: inc, depth: depth + 1, vendor: myVendor ?? vendor) {
                for (k, v) in i.dict where !["name", "inherits", "from", "instantiation", "setting_id", "filament_id", "include"].contains(k) { out[k] = v }
            }
        }
        for (k, v) in d where k != "inherits" && k != "include" { out[k] = v }
        out["name"] = name
        // The preset kind — system JSONs carried it, the 2.5 caches do not,
        // and the CLI refuses a file without it.
        out["type"] = kind
        out["from"] = origin == "system" ? "system" : "User"
        out["inherits"] = systemAncestor(kind: kind, name: name) ?? ""
        return Resolved(dict: out, missingParent: missing)
    }

    func systemAncestor(kind: String, name: String) -> String? {
        var cur = name
        for _ in 0..<20 {
            guard let (d, origin) = byName[kind]?[cur] else { return nil }
            if origin == "system" { return cur }
            guard let p = d["inherits"] as? String, !p.isEmpty else { return nil }
            cur = p
        }
        return nil
    }

    struct Preset { let name: String; let origin: String; let inherits: String; let compatible: [String]?; let dict: JSONObject }

    /// `compatible_printers` as Orca sees it: the preset's own value, else the
    /// nearest ancestor's (user presets store only their diff).
    /// Once a user preset's vendor is known, the chain stays inside it.
    func effectiveCompatible(kind: String, name: String) -> [String]? {
        guard var d = byName[kind]?[name]?.0 else { return nil }
        var vendor = userVendor[kind]?[name]
        for _ in 0..<20 {
            if let c = d["compatible_printers"] as? [String] { return c }
            guard let p = d["inherits"] as? String, !p.isEmpty else { return nil }
            if let (u, o) = byName[kind]?[p], o == "user" {
                d = u
                if let v = userVendor[kind]?[p] { vendor = v }
                continue
            }
            if let v = vendor, let (sd, sv) = systemEntry(kind: kind, name: p, vendor: v) {
                d = sd; vendor = sv
                continue
            }
            guard let (pd, _) = byName[kind]?[p] else { return nil }
            d = pd
        }
        return nil
    }

    func available() -> [String: [Preset]] {
        let (enabledFilaments, usedMachines) = appConfig()
        var res: [String: [Preset]] = [:]
        for kind in Self.kinds {
            var items: [Preset] = []
            for (name, (d, origin)) in byName[kind] ?? [:] {
                var ok = origin == "user"
                if origin == "system" {
                    var sys = (d["instantiation"] as? String ?? "").lowercased() == "true"
                    // Exactly the filaments ticked in Orca's wizard — taking
                    // every filament the printer could use buries the handful
                    // that are actually loaded.
                    if kind == "filament", !enabledFilaments.isEmpty { sys = sys && enabledFilaments.contains(name) }
                    if kind == "machine", !usedMachines.isEmpty { sys = sys && usedMachines.contains(name) }
                    ok = sys
                }
                if ok {
                    items.append(Preset(name: name, origin: origin, inherits: d["inherits"] as? String ?? "",
                                        compatible: effectiveCompatible(kind: kind, name: name), dict: d))
                }
            }
            if kind == "machine", !usedMachines.isEmpty, !items.contains(where: { $0.origin == "system" }) {
                for (name, (d, origin)) in byName[kind] ?? [:] where origin == "system" && (d["instantiation"] as? String ?? "").lowercased() == "true" {
                    items.append(Preset(name: name, origin: origin, inherits: d["inherits"] as? String ?? "",
                                        compatible: d["compatible_printers"] as? [String], dict: d))
                }
            }
            items.sort { a, b in
                if (a.origin == "user") != (b.origin == "user") { return a.origin == "user" }
                return a.name.lowercased() < b.name.lowercased()
            }
            res[kind] = items
        }
        return res
    }

    /// Per-extruder values collected from this printer's own system
    /// filaments. Thin user presets often lack keys (ramming, cooling,
    /// `filament_is_support` …) that Orca needs once several filaments are
    /// loaded at once — and no single system preset carries them all, so the
    /// union of them is used.
    func referenceFilamentValues(for machineNames: Set<String>) -> JSONObject {
        var out: JSONObject = [:]
        let names = (byName["filament"] ?? [:]).filter { (_, e) in
            e.1 == "system" && (e.0["instantiation"] as? String ?? "").lowercased() == "true"
        }.keys.sorted()
        for name in names {
            let compat = Set(effectiveCompatible(kind: "filament", name: name) ?? [])
            guard !compat.isDisjoint(with: machineNames) else { continue }
            guard let d = resolve(kind: "filament", name: name)?.dict else { continue }
            for (k, v) in d where k.hasPrefix("filament_") && v is [Any] && out[k] == nil {
                out[k] = v
            }
        }
        return out
    }

    /// Bed and head count from a machine preset's printable_area.
    func machineInfo(_ name: String) -> JSONObject {
        let m = resolve(kind: "machine", name: name)?.dict ?? [:]
        var xs: [Double] = [], ys: [Double] = []
        for pt in m["printable_area"] as? [String] ?? [] {
            let p = pt.split(separator: "x")
            if p.count == 2, let x = Double(p[0]), let y = Double(p[1]) { xs.append(x); ys.append(y) }
        }
        var out: JSONObject = ["name": name]
        if let a = xs.min(), let b = xs.max() { out["bed_x"] = (b - a * 1).rounded(toPlaces: 1) }
        if let a = ys.min(), let b = ys.max() { out["bed_y"] = (b - a).rounded(toPlaces: 1) }
        if let h = m["printable_height"] as? String, let v = Double(h) { out["bed_z"] = v }
        else if let v = m["printable_height"] as? Double { out["bed_z"] = v }
        out["extruders"] = (m["nozzle_diameter"] as? [Any])?.count ?? 1
        if let pm = m["printer_model"] as? String { out["printer_model"] = pm }
        if let gf = m["gcode_flavor"] as? String { out["gcode_flavor"] = gf }
        return out
    }
}

extension Double {
    func rounded(toPlaces p: Int) -> Double { let f = pow(10.0, Double(p)); return (self * f).rounded() / f }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
