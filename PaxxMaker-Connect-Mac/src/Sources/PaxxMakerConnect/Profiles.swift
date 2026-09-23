import Foundation

// Orca profile resolver. User presets are thin overlays with `inherits`; the
// CLI wants complete JSON. This indexes the system and user profiles of an
// Orca install and flattens an inheritance chain into one dictionary.
// Behaves like the GUI's drop-downs: user presets always, system filaments
// only when ticked in the wizard, system printers only when used before.

struct OrcaApp {
    let key: String          // "snapmaker_orca" / "orca"
    let dataDir: URL
    let confName: String

    static let all: [OrcaApp] = {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return [
            OrcaApp(key: "snapmaker_orca", dataDir: base.appendingPathComponent("Snapmaker_Orca"), confName: "Snapmaker_Orca.conf"),
            OrcaApp(key: "orca", dataDir: base.appendingPathComponent("OrcaSlicer"), confName: "OrcaSlicer.conf"),
        ]
    }()
    static var installed: [OrcaApp] { all.filter { FileManager.default.fileExists(atPath: $0.dataDir.path) } }
    static func named(_ key: String) -> OrcaApp? { installed.first { $0.key == key } }
}

typealias JSONObject = [String: Any]

final class ProfileIndex {
    static let kinds = ["machine", "process", "filament"]
    let app: OrcaApp
    /// kind → name → (dict, origin "user"/"system")
    private var byName: [String: [String: (JSONObject, String)]] = ["machine": [:], "process": [:], "filament": [:]]

    init(app: OrcaApp) {
        self.app = app
        scan()
    }

    private func add(kind: String, url: URL, origin: String) {
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? JSONObject else { return }
        let name = obj["name"] as? String ?? url.deletingPathExtension().lastPathComponent
        if byName[kind]?[name] == nil { byName[kind]?[name] = (obj, origin) }
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
                for kind in Self.kinds {
                    for f in jsonFiles(under: vendor.appendingPathComponent(kind)) { add(kind: kind, url: f, origin: "system") }
                }
            }
        }
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
    func resolve(kind: String, name: String, depth: Int = 0) -> Resolved? {
        guard depth < 20, let (d, origin) = byName[kind]?[name] else { return nil }
        var out: JSONObject = [:]
        var missing: String? = nil
        if let parent = d["inherits"] as? String, !parent.isEmpty {
            if let base = resolve(kind: kind, name: parent, depth: depth + 1) {
                out = base.dict
                missing = base.missingParent
            } else {
                missing = parent
            }
        }
        for (k, v) in d where k != "inherits" { out[k] = v }
        out["name"] = name
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
    func effectiveCompatible(kind: String, name: String) -> [String]? {
        var cur = name
        for _ in 0..<20 {
            guard let (d, _) = byName[kind]?[cur] else { return nil }
            if let c = d["compatible_printers"] as? [String] { return c }
            guard let p = d["inherits"] as? String, !p.isEmpty else { return nil }
            cur = p
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
