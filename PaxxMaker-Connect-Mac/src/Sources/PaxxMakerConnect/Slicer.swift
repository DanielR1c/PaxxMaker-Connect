import Foundation
import AppKit

// Runs one slicing job: resolves the profiles, writes the plate as 3MF, calls
// OrcaSlicer headless and reads the result off the G-code footer.

enum Orca {
    static let bundleID = "com.orcaslicer.OrcaSlicer"

    /// The installed OrcaSlicer.app: the usual folders first, then wherever
    /// Launch Services knows it by bundle id. Snapmaker Orca is never used —
    /// its command line cannot slice.
    static var appURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["/Applications/OrcaSlicer.app", "\(home)/Applications/OrcaSlicer.app"].map { URL(fileURLWithPath: $0) }
        if let ls = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { candidates.append(ls) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("Contents/MacOS/OrcaSlicer").path) }
    }
    static var binary: String { (appURL ?? URL(fileURLWithPath: "/Applications/OrcaSlicer.app")).appendingPathComponent("Contents/MacOS/OrcaSlicer").path }
    static var installed: Bool { appURL != nil }
    static var version: String? {
        guard let u = appURL, let d = NSDictionary(contentsOf: u.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return d["CFBundleShortVersionString"] as? String
    }
}

final class SliceJob {
    let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    let spec: JSONObject
    var state = "queued"          // queued / running / done / failed
    var progress = 0.0
    var stage = ""
    var error: String? = nil
    var errorCode: Int? = nil
    var result: JSONObject? = nil
    let dir: URL
    let created = Date()

    init(spec: JSONObject, jobsDir: URL) {
        self.spec = spec
        dir = jobsDir.appendingPathComponent(String(id))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    var json: JSONObject {
        ["id": String(id), "state": state, "progress": progress, "stage": stage,
         "error": error ?? NSNull(), "error_code": errorCode ?? NSNull(), "result": result ?? NSNull()]
    }
}

enum SliceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(m) = self { return m } ; return nil }
}

final class SliceRunner {
    /// Quick settings the app may send; each becomes an Orca CLI flag
    /// (`--key-with-dashes=value`). Numbers, bools and enum strings as in
    /// Orca's own JSON; percentages get their sign.
    static let overrides: [String: (Any) -> String?] = {
        func num(_ v: Any) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) ?? (v as? String).flatMap(Double.init) }
        func int(_ v: Any) -> Int? { num(v).map { Int($0.rounded()) } }
        func bool(_ v: Any) -> Bool? { (v as? Bool) ?? int(v).map { $0 != 0 } }
        func str(_ v: Any) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return [
            "layer_height":                { v in num(v).map { "--layer-height=\($0)" } },
            "initial_layer_print_height":  { v in num(v).map { "--initial-layer-print-height=\($0)" } },
            "seam_position":               { v in str(v).map { "--seam-position=\($0)" } },
            "wall_loops":                  { v in int(v).map { "--wall-loops=\($0)" } },
            "top_shell_layers":            { v in int(v).map { "--top-shell-layers=\($0)" } },
            "bottom_shell_layers":         { v in int(v).map { "--bottom-shell-layers=\($0)" } },
            "sparse_infill_density":       { v in int(v).map { "--sparse-infill-density=\($0)%" } },
            "sparse_infill_pattern":       { v in str(v).map { "--sparse-infill-pattern=\($0)" } },
            "enable_support":              { v in bool(v).map { "--enable-support=\($0 ? 1 : 0)" } },
            "support_type":                { v in str(v).map { "--support-type=\($0)" } },
            "support_on_build_plate_only": { v in bool(v).map { "--support-on-build-plate-only=\($0 ? 1 : 0)" } },
            "support_threshold_angle":     { v in int(v).map { "--support-threshold-angle=\($0)" } },
            "brim_type":                   { v in str(v).map { "--brim-type=\($0)" } },
            "brim_width":                  { v in num(v).map { "--brim-width=\($0)" } },
            "brim_object_gap":             { v in num(v).map { "--brim-object-gap=\($0)" } },
            "skirt_loops":                 { v in int(v).map { "--skirt-loops=\($0)" } },
            "spiral_mode":                 { v in bool(v).map { "--spiral-mode=\($0 ? 1 : 0)" } },
            "print_sequence":              { v in str(v).map { "--print-sequence=\($0)" } },
        ]
    }()

    let modelsDir: URL
    init(modelsDir: URL) { self.modelsDir = modelsDir }

    func run(_ job: SliceJob, log: @escaping (String) -> Void) {
        job.state = "running"; job.stage = "prepare"; job.progress = 0.05
        do {
            let spec = job.spec
            guard Orca.installed else { throw SliceError.message(L("OrcaSlicer nicht gefunden – bitte OrcaSlicer in den Programme-Ordner installieren", "OrcaSlicer not found – please install OrcaSlicer in the Applications folder")) }
            guard let app = OrcaApp.named(spec["app"] as? String ?? "orca") else { throw SliceError.message(L("Orca-Datenordner nicht gefunden", "Orca data folder not found")) }
            let idx = ProfileIndex(app: app)
            guard let machineName = spec["machine"] as? String, let processName = spec["process"] as? String,
                  var machine = idx.resolve(kind: "machine", name: machineName),
                  var process = idx.resolve(kind: "process", name: processName)
            else { throw SliceError.message(L("Profil nicht gefunden", "Profile not found")) }
            var filaments: [ProfileIndex.Resolved] = []
            for name in spec["filaments"] as? [String] ?? [] {
                guard let f = idx.resolve(kind: "filament", name: name) else { throw SliceError.message(L("Filamentprofil nicht gefunden: ", "Filament profile not found: ") + name) }
                filaments.append(f)
            }
            guard !filaments.isEmpty else { throw SliceError.message(L("Kein Filamentprofil gewählt", "No filament profile chosen")) }
            for r in [machine, process] + filaments {
                if let mp = r.missingParent { throw SliceError.message(L("Profil \"\(r.dict["name"] ?? "")\" erbt von \"\(mp)\", das nicht gefunden wurde", "Profile \"\(r.dict["name"] ?? "")\" inherits from \"\(mp)\", which was not found")) }
            }
            // Make process/filaments compatible with a user-renamed machine.
            let machineNames = [machineName, machine.dict["inherits"] as? String ?? ""].filter { !$0.isEmpty }
            process.dict["compatible_printers"] = Array(Set((process.dict["compatible_printers"] as? [String] ?? []) + machineNames))
            for i in filaments.indices {
                filaments[i].dict["compatible_printers"] = Array(Set((filaments[i].dict["compatible_printers"] as? [String] ?? []) + machineNames))
            }
            machine.dict["thumbnails"] = [String]()      // no OpenGL headless
            Self.harmonise(&filaments, colours: spec["filament_colours"] as? [String] ?? [])

            func write(_ obj: JSONObject, _ name: String) throws -> URL {
                let u = job.dir.appendingPathComponent(name)
                try JSONSerialization.data(withJSONObject: obj).write(to: u)
                return u
            }
            job.stage = "model"; job.progress = 0.1
            let modelURL = job.dir.appendingPathComponent("input.3mf")
            let objects = spec["objects"] as? [JSONObject] ?? []
            var objs: [ThreeMF.Object] = []
            for o in objects {
                guard let mid = o["model"] as? String else { continue }
                let src = modelsDir.appendingPathComponent(mid)
                guard let stl = try? Data(contentsOf: src) else { throw SliceError.message(L("Modell fehlt: ", "Model missing: ") + mid) }
                var paint: [Int: String] = [:]
                for (k, v) in o["paint"] as? [String: String] ?? [:] { if let i = Int(k) { paint[i] = v } }
                var settings: [String: String] = [:]
                for (k, v) in o["settings"] as? [String: Any] ?? [:] { settings[k] = (v as? String) ?? (v as? NSNumber)?.stringValue }
                objs.append(ThreeMF.Object(name: o["name"] as? String ?? "object", stl: stl,
                                           transform: o["transform"] as? [Double] ?? [], extruder: o["extruder"] as? Int, paint: paint,
                                           settings: settings))
            }
            guard !objs.isEmpty else { throw SliceError.message(L("Keine Objekte", "No objects")) }
            try ThreeMF.build(objs).write(to: modelURL)
            if spec["multi"] as? Bool ?? false {
                // The tower where the phone shows it; else the first free corner.
                if let t = spec["wipe_tower"] as? [Double], t.count == 2 {
                    process.dict["wipe_tower_x"] = [String(format: "%.1f", t[0])]
                    process.dict["wipe_tower_y"] = [String(format: "%.1f", t[1])]
                } else {
                    Self.placePrimeTower(process: &process, machine: machine.dict, objects: objs)
                }
            }

            let machineURL = try write(machine.dict, "machine.json")
            let processURL = try write(process.dict, "process.json")
            var filURLs: [URL] = []
            for (i, f) in filaments.enumerated() { filURLs.append(try write(f.dict, "filament_\(i).json")) }

            var args = [modelURL.path,
                        "--load-settings", "\(machineURL.path);\(processURL.path)",
                        "--load-filaments", filURLs.map(\.path).joined(separator: ";"),
                        "--arrange", "0", "--slice", "0",
                        "--outputdir", job.dir.path, "--debug", "2", "--logfile", job.dir.appendingPathComponent("orca.log").path]
            for (key, fn) in Self.overrides {
                if let v = (spec["overrides"] as? JSONObject)?[key], let a = fn(v) { args.append(a) }
            }
            // One head: the plate is sliced for T0 and the G-code rewritten to
            // the chosen head afterwards (the U1 toolkit's route). Several
            // heads (objects or painted faces): four filaments in head order,
            // Orca does the tool changes itself — no rewrite.
            let multi = spec["multi"] as? Bool ?? false
            let head = multi ? 1 : max(1, min(4, spec["head"] as? Int ?? 1))
            try? (Orca.binary + " " + args.joined(separator: " ")).write(to: job.dir.appendingPathComponent("cmd.txt"), atomically: true, encoding: .utf8)

            job.stage = "slice"; job.progress = 0.2
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Orca.binary)
            p.arguments = args
            p.currentDirectoryURL = job.dir
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            let logURL = job.dir.appendingPathComponent("orca.log")
            let stages: [(String, Double)] = [("Slicing", 0.3), ("Generating perimeters", 0.45), ("Infilling", 0.6),
                                              ("Generating support", 0.7), ("Generating G-code", 0.85), ("export_gcode finished", 0.95)]
            while p.isRunning {
                Thread.sleep(forTimeInterval: 0.4)
                if let txt = try? String(contentsOf: logURL, encoding: .utf8) {
                    let tail = String(txt.suffix(20000))
                    for (marker, v) in stages where tail.contains(marker) { job.progress = max(job.progress, v) }
                }
            }
            let gcode = (try? FileManager.default.contentsOfDirectory(at: job.dir, includingPropertiesForKeys: nil))?
                .first { $0.pathExtension == "gcode" }
            guard p.terminationStatus == 0, let gcode else {
                let code = Int(p.terminationStatus)
                job.errorCode = code
                var msg = "Orca Exit \(code)"
                if let known = Self.exitText(code) { msg += " – " + known }
                else if let txt = try? String(contentsOf: logURL, encoding: .utf8) {
                    let errs = txt.split(separator: "\n").filter { $0.lowercased().contains("error") }.suffix(3)
                    if !errs.isEmpty { msg += ": " + errs.map { String($0.suffix(160)) }.joined(separator: " | ") }
                }
                throw SliceError.message(msg)
            }
            if head > 1 { try Self.rewriteTool(gcode, to: head - 1) }
            var summary = Self.summary(of: gcode)
            summary["gcode"] = gcode.lastPathComponent
            summary["size"] = (try? FileManager.default.attributesOfItem(atPath: gcode.path)[.size] as? Int) ?? 0
            job.result = summary
            job.state = "done"; job.progress = 1; job.stage = "done"
            log("Job \(job.id) " + L("fertig", "done") + ": \(summary["filament_g"] ?? 0) g, \(summary["time_s"] ?? 0) s")
        } catch {
            job.state = "failed"; job.error = error.localizedDescription; job.stage = "failed"
            log("Job \(job.id) " + L("fehlgeschlagen", "failed") + ": \(error.localizedDescription)")
        }
    }

    /// Orca's CLI exit codes are negative (Utils.hpp); the shell shows them as
    /// 256 + code. The ones a phone user can actually do something about.
    static func exitText(_ code: Int) -> String? {
        switch code - 256 {
        case -101: return L("Druckpfade überschneiden sich: Objekte liegen zu nah beieinander oder ein Objekt kollidiert mit dem Reinigungsturm. Objekte weiter auseinander schieben.",
                            "Print paths overlap: objects are too close together or one collides with the prime tower. Move the objects apart.")
        case -102: return L("Druckpfade liegen außerhalb des Druckbereichs. Objekt weiter zur Mitte schieben.",
                            "Print paths leave the printable area. Move the object towards the centre.")
        case -100: return L("Slicing fehlgeschlagen. Modell in OrcaSlicer prüfen (Geometrie defekt?).",
                            "Slicing failed. Check the model in OrcaSlicer (broken geometry?).")
        case -52:  return L("Ein Objekt ragt aus dem Druckraum. Objekt verschieben oder verkleinern.",
                            "An object sticks out of the build volume. Move or shrink it.")
        case -50:  return L("Kein druckbares Objekt auf der Platte.", "No printable object on the plate.")
        case -17:  return L("Prozessprofil passt nicht zum Drucker. Anderes Profil wählen.", "The process profile does not fit the printer. Choose another one.")
        case -66:  return L("Filamente konnten den Köpfen nicht zugeordnet werden.", "Filaments could not be assigned to the heads.")
        case -67:  return L("Nur ein TPU-Filament je Druck möglich.", "Only one TPU filament per print is possible.")
        case -62:  return L("Filamente mit unterschiedlicher Betttemperatur in einem Druck.", "Filaments with different bed temperatures in one print.")
        case -14:  return L("OrcaSlicer hat keinen Speicher mehr.", "OrcaSlicer ran out of memory.")
        case -5:   return L("Profil konnte nicht geladen werden.", "Profile could not be loaded.")
        default:   return nil
        }
    }

    /// Multi-material: Orca puts the prime tower at a fixed default (15, 220)
    /// — a model there makes the slice fail with "path conflicts" — so the
    /// tower goes to the first corner nothing occupies.
    static func placePrimeTower(process: inout ProfileIndex.Resolved, machine: JSONObject, objects: [ThreeMF.Object]) {
        var xs: [Double] = [], ys: [Double] = []
        for pt in machine["printable_area"] as? [String] ?? [] {
            let p = pt.split(separator: "x")
            if p.count == 2, let x = Double(p[0]), let y = Double(p[1]) { xs.append(x); ys.append(y) }
        }
        guard let bx0 = xs.min(), let bx1 = xs.max(), let by0 = ys.min(), let by1 = ys.max(), bx1 - bx0 > 60, by1 - by0 > 60 else { return }
        // Footprints on the bed: mesh bounds through the placement, plus a margin
        // for brim and the tower's own brim.
        var boxes: [(Double, Double, Double, Double)] = []
        for o in objects {
            let (verts, _) = ThreeMF.readSTL(o.stl)
            guard !verts.isEmpty, o.transform.count == 16 else { continue }
            let m = o.transform
            var lo = (Double.infinity, Double.infinity), hi = (-Double.infinity, -Double.infinity)
            for v in verts {
                let x = m[0] * Double(v.x) + m[4] * Double(v.y) + m[8] * Double(v.z) + m[12]
                let y = m[1] * Double(v.x) + m[5] * Double(v.y) + m[9] * Double(v.z) + m[13]
                lo = (min(lo.0, x), min(lo.1, y)); hi = (max(hi.0, x), max(hi.1, y))
            }
            boxes.append((lo.0 - 12, lo.1 - 12, hi.0 + 12, hi.1 + 12))
        }
        let width = Double((process.dict["prime_tower_width"] as? String) ?? "") ?? 30
        let depth = 50.0                                       // grows with the purges; Orca's default leaves this much
        let inset = 12.0
        var candidates: [(Double, Double)] = [(bx0 + inset, by1 - inset - depth), (bx1 - inset - width, by1 - inset - depth),
                                              (bx0 + inset, by0 + inset), (bx1 - inset - width, by0 + inset)]
        var y = by1 - inset - depth
        while y >= by0 + inset { var x = bx0 + inset; while x <= bx1 - inset - width { candidates.append((x, y)); x += 20 }; y -= 20 }
        for (x, y) in candidates {
            let free = !boxes.contains { b in x < b.2 && x + width > b.0 && y < b.3 && y + depth > b.1 }
            if free {
                process.dict["wipe_tower_x"] = [String(format: "%.1f", x)]
                process.dict["wipe_tower_y"] = [String(format: "%.1f", y)]
                return
            }
        }
    }

    /// What Orca's CLI needs from several filament profiles at once, found the
    /// hard way: (1) it takes the number of extruders from the length of the
    /// merged `filament_colour` vector, and user presets usually carry no
    /// colour (it lives in the project) — so every profile gets one, the
    /// printer's own where known; (2) profiles from different inheritance
    /// chains (Snapmaker's "Generic PETG" vs OrcaSlicer's "eSUN PETG") have
    /// different key sets, which trips "ConfigOptionVector: invalid size" —
    /// so every key present anywhere is present everywhere, gaps filled from
    /// the first profile that has it.
    static func harmonise(_ filaments: inout [ProfileIndex.Resolved], colours: [String]) {
        let palette = ["#F2754E", "#4A90D9", "#5DBB63", "#E6C229"]
        for i in filaments.indices {
            let own = (filaments[i].dict["filament_colour"] as? [String])?.first ?? ""
            let given = colours[safe: i].map { $0.hasPrefix("#") ? $0 : "#" + $0 } ?? ""
            let colour = given.count == 7 ? given : (own.count == 7 ? own : palette[i % palette.count])
            filaments[i].dict["filament_colour"] = [colour]
        }
        guard filaments.count > 1 else { return }
        var keys: [String] = []
        var seen = Set<String>()
        for f in filaments { for k in f.dict.keys where seen.insert(k).inserted { keys.append(k) } }
        for k in keys {
            guard let donor = filaments.first(where: { $0.dict[k] != nil })?.dict[k] else { continue }
            for i in filaments.indices where filaments[i].dict[k] == nil { filaments[i].dict[k] = donor }
        }
    }

    /// T0 → Tn in every command line (comments untouched): tool selects,
    /// M104/M109 temperatures with a T parameter, and the header's own
    /// extruder bookkeeping.
    static func rewriteTool(_ url: URL, to tool: Int) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let re = try NSRegularExpression(pattern: "(?<![A-Za-z_0-9])T0(?![0-9])")
        var out = String(); out.reserveCapacity(text.count + 1024)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(";") || line.isEmpty { out += line; out += "\n"; continue }
            let s = String(line)
            let r = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "T\(tool)")
            out += r; out += "\n"
        }
        if out.hasSuffix("\n") && !text.hasSuffix("\n") { out.removeLast() }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Time, filament and cost from the footer Orca writes.
    static func summary(of url: URL) -> JSONObject {
        var out: JSONObject = [:]
        guard let fh = try? FileHandle(forReadingFrom: url) else { return out }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let head = { () -> String in
            try? fh.seek(toOffset: 0)
            return String(decoding: fh.readData(ofLength: 4096), as: UTF8.self)
        }()
        try? fh.seek(toOffset: size > 262144 ? size - 262144 : 0)
        let tail = String(decoding: fh.readDataToEndOfFile(), as: UTF8.self)
        func grab(_ pattern: String, in s: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: s) else { return nil }
            return String(s[r]).trimmingCharacters(in: .whitespaces)
        }
        if let t = grab("^; estimated printing time \\(normal mode\\) = (.+)$", in: tail) {
            var secs = 0
            let re = try! NSRegularExpression(pattern: "(\\d+)([dhms])")
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                let n = Int(t[Range(m.range(at: 1), in: t)!]) ?? 0
                let u = String(t[Range(m.range(at: 2), in: t)!])
                secs += n * ["d": 86400, "h": 3600, "m": 60, "s": 1][u]!
            }
            out["time_s"] = secs
        }
        if let g = grab("^; filament used \\[g\\] = (.+)$", in: tail) {
            out["filament_g_tools"] = g.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        if let g = grab("^; total filament used \\[g\\] = ([\\d.]+)", in: tail), let v = Double(g) { out["filament_g"] = v }
        if let mm = grab("^; filament used \\[mm\\] = (.+)$", in: tail) {
            out["filament_mm"] = mm.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.reduce(0, +)
        }
        if let c = grab("^; total filament cost = ([\\d.]+)", in: tail), let v = Double(c) { out["cost"] = v }
        if let l = grab("^; total layer number: (\\d+)", in: head), let v = Int(l) { out["layers"] = v }
        if let h = grab("^; max_z_height: ([\\d.]+)", in: head), let v = Double(h) { out["height_mm"] = v }
        var sup: [String: String] = [:]
        for key in ["enable_support", "support_type", "support_style", "support_on_build_plate_only"] {
            if let v = grab("^; \(key) = (.+)$", in: tail) { sup[key] = v }
        }
        if !sup.isEmpty { out["support"] = sup }
        return out
    }
}
