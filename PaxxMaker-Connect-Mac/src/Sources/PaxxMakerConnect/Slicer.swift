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

    /// OrcaSlicer 2.5 or newer: system profiles in .opc caches, and the CLI
    /// resolves `inherits` itself.
    static var resolvesInherits: Bool {
        let parts = (version ?? "").split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return parts[0] > 2 || (parts[0] == 2 && parts[1] >= 5)
    }
}

/// Snapmaker Orca (Snapmaker's OrcaSlicer fork, the U1's own slicer).
enum SnapmakerOrca {
    static let bundleID = "com.snapmaker.snapmaker-orca"
    static var appURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["/Applications/Snapmaker Orca.app", "\(home)/Applications/Snapmaker Orca.app"].map { URL(fileURLWithPath: $0) }
        if let ls = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { candidates.append(ls) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("Contents/MacOS/Snapmaker_Orca").path) }
    }
    /// PAXX_SNAPMAKER_ORCA overrides the binary (as in the Linux version).
    static var binary: String? {
        if let p = ProcessInfo.processInfo.environment["PAXX_SNAPMAKER_ORCA"], FileManager.default.isExecutableFile(atPath: p) { return p }
        return appURL?.appendingPathComponent("Contents/MacOS/Snapmaker_Orca").path
    }
    static var version: String? {
        guard let u = appURL, let d = NSDictionary(contentsOf: u.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return d["CFBundleShortVersionString"] as? String
    }
    /// Its command line slices from 2.4.1 on (2.3/2.4.0 crashed at once on
    /// the Mac, exit 254).
    static var cliWorks: Bool {
        let p = (version ?? "").split(separator: ".").compactMap { Int($0) }
        guard p.count >= 3 else { return false }
        return (p[0], p[1], p[2]) >= (2, 4, 1)
    }
}

/// The program that slices one job: Snapmaker Orca for its own profiles
/// where its command line works, else OrcaSlicer.
struct SlicerEngine {
    let binary: String
    let name: String
    let version: String
    let snapmaker: Bool
    /// OrcaSlicer 2.5+: .opc caches, CLI resolves inherits, statistics,
    /// repair and colour mixing.
    let modern: Bool

    static func forApp(_ key: String, forceOrca: Bool = false) -> SlicerEngine? {
        if key == "snapmaker_orca", !forceOrca, SnapmakerOrca.cliWorks, let b = SnapmakerOrca.binary {
            return SlicerEngine(binary: b, name: "Snapmaker Orca", version: SnapmakerOrca.version ?? "", snapmaker: true, modern: false)
        }
        guard Orca.installed else { return nil }
        return SlicerEngine(binary: Orca.binary, name: "OrcaSlicer", version: Orca.version ?? "", snapmaker: false, modern: Orca.resolvesInherits)
    }
    var features: [String] { ["fuzzy", "ranges", "filament_ids"] + (modern ? ["stats", "repair", "mix"] : []) }
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

    func run(_ job: SliceJob, log: @escaping (String) -> Void, forceOrca: Bool = false) {
        job.state = "running"; job.stage = "prepare"; job.progress = 0.05
        job.error = nil; job.errorCode = nil
        var triedSnapmaker = false
        do {
            let spec = job.spec
            guard let app = OrcaApp.named(spec["app"] as? String ?? OrcaApp.defaultKey) else { throw SliceError.message(L("Orca-Datenordner nicht gefunden", "Orca data folder not found")) }
            guard let engine = SlicerEngine.forApp(app.key, forceOrca: forceOrca) else { throw SliceError.message(L("OrcaSlicer nicht gefunden – bitte OrcaSlicer in den Programme-Ordner installieren", "OrcaSlicer not found – please install OrcaSlicer in the Applications folder")) }
            triedSnapmaker = engine.snapmaker
            log("Job \(job.id): " + L("Profile aus ", "profiles from ") + app.displayName + ", " + L("slicen mit ", "slicing with ") + "\(engine.name) \(engine.version)")
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
            // Several filaments at once: every per-extruder list has to have
            // one entry per filament. A key missing from all of them keeps
            // Orca's single default and the slice dies with
            // "filament_is_support's count 1 not equal to filament_colour's
            // size 4" (exit 251). So the gaps are filled from a system
            // filament of this printer.
            if filaments.count > 1 {
                let ref = idx.referenceFilamentValues(for: Set(machineNames))
                for (k, v) in ref where k != "filament_colour" && k != "compatible_printers" {
                    for i in filaments.indices where filaments[i].dict[k] == nil { filaments[i].dict[k] = v }
                }
            }

            // Temperatures the phone sends along: they replace the filament's
            // own values. The bed temperature belongs to the plate type, so it
            // is written to the keys of the plate this printer uses.
            let bedType = (machine.dict["default_bed_type"] as? String) ?? "Textured PEI Plate"
            let nozzles = (spec["nozzle_temps"] as? [Any])?.map { Int(($0 as? NSNumber)?.doubleValue ?? 0) } ?? []
            for (i, t) in nozzles.enumerated() where t > 0 && i < filaments.count {
                filaments[i].dict["nozzle_temperature"] = ["\(t)"]
                filaments[i].dict["nozzle_temperature_initial_layer"] = ["\(t)"]
            }
            if let bed = (spec["bed_temp"] as? NSNumber)?.intValue, bed > 0 {
                let key = Self.plateTempKey(bedType)
                for i in filaments.indices {
                    filaments[i].dict[key] = ["\(bed)"]
                    filaments[i].dict[key + "_initial_layer"] = ["\(bed)"]
                }
            }

            // Colour mixing (OrcaSlicer 2.5): one more filament slot that is
            // not a head of its own but two heads taking turns — layer by layer
            // or in sub-layers, at a fixed ratio or as a gradient from bottom
            // to top. The slot needs a filament entry of its own (a copy of its
            // first component) and the process carries the blend.
            // Several blends (one per mixed object group) become one slot each,
            // after the physical filaments. "mix" (one blend) still works.
            var mixSlot = 0                       // first mixed slot, 0 = none
            var objectSlot: [Int: Int] = [:]      // object index → its mixed slot
            var mixSpecs = spec["mixes"] as? [JSONObject] ?? []
            if mixSpecs.isEmpty, let one = spec["mix"] as? JSONObject { mixSpecs = [one] }
            if engine.modern, !mixSpecs.isEmpty {
                let physical = filaments.count
                var comps: [String] = [], ratios: [String] = [], grad: [String] = [], ranges: [String] = []
                var sublayer = false
                for mix in mixSpecs {
                    guard let c = mix["components"] as? [Int], c.count >= 2,
                          c.allSatisfy({ $0 >= 1 && $0 <= physical }) else { continue }
                    var slot = filaments[c[0] - 1]
                    if let col = mix["colour"] as? String, col.count >= 6 {
                        slot.dict["filament_colour"] = [col.hasPrefix("#") ? col : "#" + col]
                    }
                    filaments.append(slot)
                    let n = filaments.count
                    if mixSlot == 0 { mixSlot = n }
                    for oi in mix["objects"] as? [Int] ?? [] { objectSlot[oi] = n }
                    let r = (mix["ratios"] as? [Double]) ?? Array(repeating: 1.0 / Double(c.count), count: c.count)
                    let sum = max(r.reduce(0, +), 0.0001)
                    let gradient = mix["gradient"] as? Bool ?? false
                    let range = (mix["range"] as? [Double]) ?? [0.1, 0.9]
                    comps.append(c.map(String.init).joined(separator: ","))
                    ratios.append(r.map { String(format: "%.4f", $0 / sum) }.joined(separator: ","))
                    grad.append(gradient ? "1" : "0")
                    ranges.append(gradient ? range.map { String(format: "%.2f", $0) }.joined(separator: ",") : "")
                    // OrcaSlicer 2.5 applies a gradient only in sub-layer mode;
                    // alternating whole layers it falls back to the fixed ratio
                    // (50/50 for a gradient) — tested.
                    if mix["sublayer"] as? Bool ?? false || gradient { sublayer = true }
                }
                let m = comps.count
                if m > 0 {
                    func list(_ mixed: [String], _ others: String) -> [String] { Array(repeating: others, count: physical) + mixed }
                    process.dict["filament_is_mixed"] = list(Array(repeating: "1", count: m), "0")
                    process.dict["filament_mixed_components"] = list(comps, "")
                    process.dict["filament_mixed_sublayer_ratios"] = list(ratios, "")
                    process.dict["filament_mixed_gradient"] = list(grad, "0")
                    process.dict["filament_mixed_gradient_range"] = list(ranges, "")
                    process.dict["filament_mixed_gradient_curve"] = list(Array(repeating: "", count: m), "")
                    process.dict["filament_mixed_gradient_per_part"] = list(Array(repeating: "0", count: m), "0")
                    if sublayer { process.dict["enable_mixed_color_sublayer"] = "1" }
                }
            }

            func write(_ obj: JSONObject, _ name: String) throws -> URL {
                let u = job.dir.appendingPathComponent(name)
                try JSONSerialization.data(withJSONObject: obj).write(to: u)
                return u
            }
            job.stage = "model"; job.progress = 0.1
            let modelURL = job.dir.appendingPathComponent("input.3mf")
            let objects = spec["objects"] as? [JSONObject] ?? []
            var objs: [ThreeMF.Object] = []
            for (oi, o) in objects.enumerated() {
                guard let mid = o["model"] as? String else { continue }
                let src = modelsDir.appendingPathComponent(mid)
                guard let stl = try? Data(contentsOf: src) else { throw SliceError.message(L("Modell fehlt: ", "Model missing: ") + mid) }
                var paint: [Int: String] = [:]
                for (k, v) in o["paint"] as? [String: String] ?? [:] { if let i = Int(k) { paint[i] = v } }
                var fuzzy: [Int: String] = [:]
                for (k, v) in o["fuzzy"] as? [String: String] ?? [:] { if let i = Int(k) { fuzzy[i] = v } }
                var ranges: [(Double, Double, Int)] = []
                for r in o["ranges"] as? [[Double]] ?? [] where r.count == 3 { ranges.append((r[0], r[1], Int(r[2]))) }
                var settings: [String: String] = [:]
                for (k, v) in o["settings"] as? [String: Any] ?? [:] { settings[k] = (v as? String) ?? (v as? NSNumber)?.stringValue }
                objs.append(ThreeMF.Object(name: o["name"] as? String ?? "object", stl: stl,
                                           transform: o["transform"] as? [Double] ?? [],
                                           extruder: objectSlot[oi] ?? o["extruder"] as? Int, paint: paint,
                                           fuzzy: fuzzy, ranges: ranges, settings: settings))
            }
            guard !objs.isEmpty else { throw SliceError.message(L("Keine Objekte", "No objects")) }
            try ThreeMF.build(objs, rangeLayerHeight: (spec["range_layer_height"] as? Double) ?? 0.2).write(to: modelURL)
            if spec["multi"] as? Bool ?? false {
                // The tower where the phone shows it; else the first free corner.
                if let t = spec["wipe_tower"] as? [Double], t.count == 2 {
                    process.dict["wipe_tower_x"] = [String(format: "%.1f", t[0])]
                    process.dict["wipe_tower_y"] = [String(format: "%.1f", t[1])]
                } else {
                    Self.placePrimeTower(process: &process, machine: machine.dict, objects: objs)
                }
            }

            // The files are complete already. OrcaSlicer 2.5 would resolve an
            // `inherits` once more against its own preset bundle — and stops
            // where a user preset's parent is not in it ("Preset was not found
            // in the loaded bundle"). Without the field it takes the file as is.
            // Older versions keep it: their CLI checks process/printer
            // compatibility against the printer's system name in it.
            if engine.modern {
                machine.dict["inherits"] = ""
                process.dict["inherits"] = ""
                for i in filaments.indices { filaments[i].dict["inherits"] = "" }
            }
            // Snapmaker Orca's CLI crashes on an explicit prime-tower filament
            // (its normalize_fdm() reads nozzle_diameter from the process
            // config — found by the Linux version); without it: auto.
            if engine.snapmaker { process.dict.removeValue(forKey: "wipe_tower_filament") }
            let machineURL = try write(machine.dict, "machine.json")
            let processURL = try write(process.dict, "process.json")
            var filURLs: [URL] = []
            for (i, f) in filaments.enumerated() { filURLs.append(try write(f.dict, "filament_\(i).json")) }

            // The bed type is a project setting in Orca's GUI; the CLI falls
            // back to "Cool Plate", and most filaments have 0 °C for that —
            // the printer then warns about a cold bed. So the printer's own
            // default plate (see above) is passed explicitly.
            // --datadir: OrcaSlicer 2.5 resolves `inherits` itself and looks
            // the parent up in this folder; without it the CLI stops ("can not
            // resolve preset … system").
            var args = [modelURL.path,
                        "--load-settings", "\(machineURL.path);\(processURL.path)",
                        "--load-filaments", filURLs.map(\.path).joined(separator: ";"),
                        "--arrange", "0", "--slice", "0",
                        "--outputdir", job.dir.path, "--debug", "2",
                        "--curr-bed-type=\(bedType)"]
            if engine.snapmaker {
                // Snapmaker Orca has no --logfile; its console goes to orca.log below.
            } else {
                // OrcaSlicer's own data folder — its preset bundle, whichever
                // source the profiles came from.
                args.insert(contentsOf: ["--datadir", (OrcaApp.named("orca") ?? app).dataDir.path], at: 1)
                args += ["--logfile", job.dir.appendingPathComponent("orca.log").path]
            }
            // OrcaSlicer 2.5: the plate's statistics as JSON (per head: model,
            // tower, flush; per feature) and, when asked, its "Fix Model" repair.
            if engine.modern {
                args.append("--export-statistics")
                if spec["repair"] as? Bool ?? false { args.insert("--repair", at: 1) }
            }
            let given = (spec["overrides"] as? JSONObject) ?? [:]
            for (key, fn) in Self.overrides {
                if let v = given[key], let a = fn(v) { args.append(a) }
            }
            // Settings the app added on its own (its editor offers every key
            // OrcaSlicer knows). The CLI takes any config key as an option, so
            // these go through unchanged — only the key is checked, so nothing
            // but a setting can end up in the argument list.
            for (key, v) in given where Self.overrides[key] == nil {
                guard key.range(of: "^[a-z][a-z0-9_]{1,60}$", options: .regularExpression) != nil else { continue }
                let value: String
                switch v {
                case let b as Bool: value = b ? "1" : "0"
                case let n as NSNumber: value = n.stringValue
                case let s as String: value = s
                default: continue
                }
                guard !value.isEmpty, !value.contains("\n") else { continue }
                args.append("--" + key.replacingOccurrences(of: "_", with: "-") + "=" + value)
            }
            // One head: the plate is sliced for T0 and the G-code rewritten to
            // the chosen head afterwards (the U1 toolkit's route). Several
            // heads (objects or painted faces): four filaments in head order,
            // Orca does the tool changes itself — no rewrite.
            let multi = spec["multi"] as? Bool ?? false
            let head = multi ? 1 : max(1, min(4, spec["head"] as? Int ?? 1))
            try? (engine.binary + " " + args.joined(separator: " ")).write(to: job.dir.appendingPathComponent("cmd.txt"), atomically: true, encoding: .utf8)

            job.stage = "slice"; job.progress = 0.2
            let logURL = job.dir.appendingPathComponent("orca.log")
            var gcodeFound: URL? = nil
            // A tower that does not fit (colour mixing makes it ~100 mm deep:
            // a head change on every layer) is moved towards the front and the
            // slice repeated — up to three times.
            for attempt in 0..<4 {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: engine.binary)
                p.arguments = args
                p.currentDirectoryURL = job.dir
                if engine.snapmaker, FileManager.default.createFile(atPath: logURL.path, contents: nil),
                   let fh = try? FileHandle(forWritingTo: logURL) {
                    p.standardOutput = fh
                    p.standardError = fh
                } else {
                    p.standardOutput = FileHandle.nullDevice
                    p.standardError = FileHandle.nullDevice
                }
                try p.run()
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
                if p.terminationStatus == 0, let gcode { gcodeFound = gcode; break }
                let code = Int(p.terminationStatus)
                let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                if attempt < 3, logText.contains("Prime tower is partially outside"),
                   let moved = Self.moveTowerIn(process: &process, machine: machine.dict) {
                    _ = try write(process.dict, "process.json")
                    log("Job \(job.id): " + L("Reinigungsturm passt nicht — verschoben nach ", "prime tower does not fit — moved to ") + moved)
                    job.progress = 0.2
                    continue
                }
                job.errorCode = code
                var msg = "Orca Exit \(code)"
                if let reason = Self.validateReason(logText) { msg += " – " + reason }
                else if let known = Self.exitText(code) { msg += " – " + known }
                else {
                    let errs = logText.split(separator: "\n").filter { $0.lowercased().contains("error") }.suffix(3)
                    if !errs.isEmpty { msg += ": " + errs.map { String($0.suffix(160)) }.joined(separator: " | ") }
                }
                throw SliceError.message(msg)
            }
            guard let gcode = gcodeFound else { throw SliceError.message(L("Kein G-Code erzeugt", "No G-code produced")) }
            if head > 1 { try Self.rewriteTool(gcode, to: head - 1) }
            var summary = Self.summary(of: gcode)
            summary["gcode"] = gcode.lastPathComponent
            summary["slicer"] = "\(engine.name) \(engine.version)"
            summary["source"] = app.key
            summary["size"] = (try? FileManager.default.attributesOfItem(atPath: gcode.path)[.size] as? Int) ?? 0
            let statsURL = job.dir.appendingPathComponent(gcode.deletingPathExtension().lastPathComponent + ".statistics.json")
            if var st = Self.statistics(statsURL, head: head, mixSlot: mixSlot) {
                st["changes"] = Self.toolChanges(gcode)
                summary["stats"] = st
            }
            if spec["repair"] as? Bool ?? false, let txt = try? String(contentsOf: logURL, encoding: .utf8) {
                // Orca logs a failed repair as a warning; a successful one is silent at this level.
                summary["repair_failed"] = txt.split(separator: "\n").filter { $0.contains("repair of") && $0.contains("failed") }.count
            }
            job.result = summary
            job.state = "done"; job.progress = 1; job.stage = "done"
            log("Job \(job.id) " + L("fertig", "done") + ": \(summary["filament_g"] ?? 0) g, \(summary["time_s"] ?? 0) s")
        } catch {
            // Snapmaker Orca's command line is young (it crashed outright up to
            // 2.4.0 on the Mac): when it fails, OrcaSlicer slices the same
            // profiles instead.
            if triedSnapmaker, Orca.installed {
                log("Job \(job.id): Snapmaker Orca " + L("fehlgeschlagen (", "failed (") + error.localizedDescription.prefix(120) + L(") — slice mit OrcaSlicer", ") — slicing with OrcaSlicer"))
                run(job, log: log, forceOrca: true)
                return
            }
            job.state = "failed"; job.error = error.localizedDescription; job.stage = "failed"
            log("Job \(job.id) " + L("fehlgeschlagen", "failed") + ": \(error.localizedDescription)")
        }
    }

    /// Which filament key holds the bed temperature depends on the plate the
    /// printer uses.
    static func plateTempKey(_ bedType: String) -> String {
        let t = bedType.lowercased()
        if t.contains("textured") { return "textured_plate_temp" }
        if t.contains("engineering") { return "eng_plate_temp" }
        if t.contains("high temp") { return "hot_plate_temp" }
        if t.contains("supertack") || t.contains("cool") { return "cool_plate_temp" }
        return "hot_plate_temp"
    }

    /// Orca's CLI exit codes are negative (Utils.hpp); the shell shows them as
    /// 256 + code. The ones a phone user can actually do something about.
    /// Moves the prime tower 50 mm towards the front (and inside on X);
    /// nil when it is at the front already.
    static func moveTowerIn(process: inout ProfileIndex.Resolved, machine: JSONObject) -> String? {
        func first(_ k: String) -> Double? {
            if let a = process.dict[k] as? [String] { return a.first.flatMap(Double.init) }
            if let v = process.dict[k] as? String { return Double(v) }
            return (process.dict[k] as? NSNumber)?.doubleValue
        }
        guard var y = first("wipe_tower_y"), var x = first("wipe_tower_x") else { return nil }
        let pts = (machine["printable_area"] as? [String] ?? []).compactMap { p -> (Double, Double)? in
            let c = p.split(separator: "x").compactMap { Double($0) }
            return c.count == 2 ? (c[0], c[1]) : nil
        }
        let maxX = pts.map(\.0).max() ?? 270, minY = pts.map(\.1).min() ?? 0
        let w = (Double(process.dict["prime_tower_width"] as? String ?? "") ?? 35) + 2 * (Double(process.dict["prime_tower_brim_width"] as? String ?? "") ?? 3)
        guard y > minY + 6 else { return nil }
        y = max(minY + 5, y - 50)
        x = min(x, maxX - w - 5)
        process.dict["wipe_tower_x"] = [String(format: "%.1f", x)]
        process.dict["wipe_tower_y"] = [String(format: "%.1f", y)]
        return String(format: "%.0f / %.0f", x, y)
    }

    /// OrcaSlicer's own check ("got error when validate: …") in plain words.
    static func validateReason(_ log: String) -> String? {
        guard let r = log.range(of: "got error when validate: ") else { return nil }
        let line = String(log[r.upperBound...].prefix { $0 != "\n" })
        if line.contains("Prime tower is partially outside") {
            return L("Der Reinigungsturm passt nicht auf das Druckbett — mit Farbmischung wird er sehr tief (ca. 10 cm). Objekte nach hinten schieben, damit vorne Platz ist, oder kleiner drucken.",
                     "The prime tower does not fit on the bed — with colour mixing it gets very deep (about 10 cm). Move the objects back to make room at the front, or print smaller.")
        }
        return L("OrcaSlicer-Prüfung: ", "OrcaSlicer check: ") + line
    }

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
        case -69:  return L("Farbmischung ungültig: Beide Köpfe brauchen dasselbe Material.", "Colour mix invalid: both heads need the same material.")
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

    /// The part of OrcaSlicer's plate_N.statistics.json the app shows: totals,
    /// per head (model / prime tower / flush / support) and per feature.
    /// Orca numbers filaments from 1; a one-head slice ran as filament 1 and
    /// is reported for the head it was rewritten to.
    static func statistics(_ url: URL, head: Int, mixSlot: Int) -> JSONObject? {
        guard let d = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: d) as? JSONObject,
              let sum = root["summary"] as? JSONObject else { return nil }
        func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
        func r(_ v: Double, _ p: Double = 100) -> Double { (v * p).rounded() / p }
        func weight(_ o: Any?) -> Double { r(num((o as? JSONObject)?["weight"])) }
        var out: JSONObject = ["time_s": Int(num(sum["time"]).rounded()),
                               "prepare_s": Int(num(sum["prepare_time"]).rounded()),
                               "travel_s": Int(num(sum["travel_time"]).rounded()),
                               "layers": Int(num(sum["layer_count"])),
                               "weight_g": r(num(sum["weight"])),
                               "cost": r(num(sum["filament_cost"])),
                               "changes": Int(num(sum["filament_changes"]))]
        var heads: [JSONObject] = []
        for f in sum["filaments"] as? [JSONObject] ?? [] {
            let id = Int(num(f["id"]))
            heads.append(["head": head > 1 && id == 1 ? head : id,
                          "length_m": r(num(f["length"]) / 1000),
                          "weight_g": r(num(f["weight"])), "cost": r(num(f["cost"])),
                          "model_g": weight(f["model"]), "tower_g": weight(f["prime_tower"]),
                          "flush_g": weight(f["flush"]), "support_g": weight(f["support"])])
        }
        out["heads"] = heads
        var feats: [JSONObject] = []
        for (name, v) in sum["features"] as? JSONObject ?? [:] {
            guard let o = v as? JSONObject else { continue }
            feats.append(["name": name, "time_s": Int(num(o["time"]).rounded()), "weight_g": r(num(o["weight"]))])
        }
        out["features"] = feats.sorted { ($0["time_s"] as? Int ?? 0) > ($1["time_s"] as? Int ?? 0) }
        if mixSlot > 0 { out["mix_slot"] = mixSlot }
        return out
    }

    /// Tool changes in a G-code: lines that are just "Tn", after the first.
    /// (Orca's own statistics count only changes within a nozzle.)
    static func toolChanges(_ url: URL) -> Int {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return 0 }
        var n = 0, last = -1
        d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            var i = 0
            let c = b.count
            while i + 2 < c {
                // start of a line: "T" digit(s) end of line
                if b[i] == 0x54, i == 0 || b[i - 1] == 0x0A {
                    var j = i + 1, v = 0
                    while j < c, b[j] >= 0x30, b[j] <= 0x39 { v = v * 10 + Int(b[j] - 0x30); j += 1 }
                    if j > i + 1, j < c, b[j] == 0x0A || b[j] == 0x0D {
                        if last >= 0 && v != last { n += 1 }
                        last = v
                    }
                    i = j
                } else { i += 1 }
            }
        }
        return n
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
