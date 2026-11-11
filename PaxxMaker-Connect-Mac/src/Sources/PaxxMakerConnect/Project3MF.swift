import Foundation

// A finished slicer project (3MF from Snapmaker Space and the like): model,
// painting, plate and every setting are in the file. It is sliced as it is —
// only the filaments are replaced by what is loaded in the printer's heads,
// and a few settings may be changed afterwards.

enum Project3MF {
    /// One entry of the archive (via /usr/bin/unzip, part of macOS).
    static func entry(_ name: String, of file: URL, limit: Int = 8_000_000) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", file.path, name]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty, data.count <= limit else { return nil }
        return data
    }

    /// The start of an entry (the model file is tens of MB; its metadata is at the top).
    static func head(_ name: String, of file: URL, bytes: Int = 6000) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", file.path, name]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readData(ofLength: bytes)
        p.terminate()
        return String(decoding: data, as: UTF8.self)
    }

    private static func strings(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a }
        if let s = v as? String { return [s] }
        return []
    }

    /// What the app shows before slicing: who made the file, for which
    /// printer, its filaments, plates and the plate picture.
    static func inspect(_ file: URL) -> JSONObject {
        guard let raw = entry("Metadata/project_settings.config", of: file),
              let cfg = try? JSONSerialization.jsonObject(with: raw) as? JSONObject else {
            return ["usable": false, "reason": "no_project"]
        }
        let model = head("3D/3dmodel.model", of: file)
        func meta(_ key: String) -> String {
            guard let r = model.range(of: "name=\"\(key)\">") else { return "" }
            return String(model[r.upperBound...].prefix { $0 != "<" })
        }
        let creator = meta("Application")
        let colours = strings(cfg["filament_colour"])
        let types = strings(cfg["filament_type"])
        let ids = strings(cfg["filament_settings_id"])
        var filaments: [JSONObject] = []
        for i in colours.indices {
            filaments.append(["colour": colours[i], "type": types[safe: i] ?? types.first ?? "",
                              "profile": ids[safe: i] ?? ""])
        }
        let settings = String(decoding: entry("Metadata/model_settings.config", of: file) ?? Data(), as: UTF8.self)
        let plates = max(1, settings.components(separatedBy: "<plate>").count - 1)
        var plateName = ""
        if let r = settings.range(of: "key=\"plater_name\" value=\"") {
            plateName = String(settings[r.upperBound...].prefix { $0 != "\"" })
        }
        let printer = (cfg["printer_model"] as? String) ?? ""
        // Only Snapmaker Orca's own projects slice as they are: Bambu Studio and
        // OrcaSlicer files carry values its command line rejects.
        let own = creator.hasPrefix("Snapmaker_Orca")
        var out: JSONObject = [
            "usable": own, "creator": creator, "printer_model": printer,
            "printer_profile": (cfg["printer_settings_id"] as? String) ?? "",
            "process": (cfg["print_settings_id"] as? String) ?? "",
            "title": meta("Title"), "plate_name": plateName, "plates": plates,
            "filaments": filaments,
            "nozzle": strings(cfg["nozzle_diameter"]).first ?? "",
            "layer_height": (cfg["layer_height"] as? String) ?? "",
            "enable_support": (cfg["enable_support"] as? String) ?? "",
            "support_type": (cfg["support_type"] as? String) ?? "",
            "sparse_infill_density": (cfg["sparse_infill_density"] as? String) ?? "",
            "wall_loops": (cfg["wall_loops"] as? String) ?? "",
            "brim_type": (cfg["brim_type"] as? String) ?? "",
            "bed_type": (cfg["curr_bed_type"] as? String) ?? "",
            "mixing": !strings(cfg["mixed_filament_definitions"]).joined().isEmpty,
        ]
        if !own { out["reason"] = "foreign" }
        if let png = entry("Metadata/plate_1.png", of: file, limit: 2_000_000) {
            out["thumbnail"] = png.base64EncodedString()
        }
        return out
    }
}

extension SliceRunner {
    /// Slices an uploaded project: `spec.project` names the file,
    /// `spec.filaments` one profile per project filament ("" = keep the
    /// project's own), `spec.filament_colours` the colours loaded,
    /// `spec.overrides` the fine tuning.
    func runProject(_ job: SliceJob, id: String, log: @escaping (String) -> Void) {
        job.state = "running"; job.stage = "prepare"; job.progress = 0.05
        job.error = nil; job.errorCode = nil
        do {
            let spec = job.spec
            guard SnapmakerOrca.cliWorks, let binary = SnapmakerOrca.binary else {
                throw SliceError.message(L("3MF-Projekte brauchen Snapmaker Orca 2.4.1 oder neuer auf diesem Computer.",
                                           "3MF projects need Snapmaker Orca 2.4.1 or newer on this computer."))
            }
            let src = modelsDir.appendingPathComponent(id)
            guard id.hasSuffix(".3mf"), !id.contains("/"), FileManager.default.fileExists(atPath: src.path) else {
                throw SliceError.message(L("Projekt fehlt — bitte noch einmal senden.", "Project missing — please send it again."))
            }
            let input = job.dir.appendingPathComponent("input.3mf")
            try? FileManager.default.removeItem(at: input)
            try FileManager.default.copyItem(at: src, to: input)
            log("Job \(job.id): " + L("3MF-Projekt, slicen mit ", "3MF project, slicing with ") + "Snapmaker Orca \(SnapmakerOrca.version ?? "")")

            // The loaded filaments, one file per project filament. A slot
            // without a profile keeps what the project has.
            var paths: [String] = []
            var any = false
            if let app = OrcaApp.named("snapmaker_orca") {
                let idx = ProfileIndex(app: app)
                for (i, name) in (spec["filaments"] as? [String] ?? []).enumerated() {
                    guard !name.isEmpty, let f = idx.resolve(kind: "filament", name: name), f.missingParent == nil else { paths.append(""); continue }
                    let u = job.dir.appendingPathComponent("filament_\(i).json")
                    try JSONSerialization.data(withJSONObject: f.dict).write(to: u)
                    paths.append(u.path); any = true
                }
            }
            var args = [input.path, "--allow-newer-file"]
            if any { args += ["--load-filaments", paths.joined(separator: ";")] }
            let colours = (spec["filament_colours"] as? [String] ?? []).map { $0.hasPrefix("#") ? $0 : "#" + $0 }
            if !colours.isEmpty, colours.allSatisfy({ $0.count == 7 }) {
                args.append("--filament-colour=" + colours.joined(separator: ";"))
            }
            let plate = max(1, spec["plate"] as? Int ?? 1)
            args += ["--slice", "\(plate)", "--outputdir", job.dir.path]
            let given = (spec["overrides"] as? JSONObject) ?? [:]
            for (key, fn) in Self.overrides {
                if let v = given[key], let a = fn(v) { args.append(a) }
            }
            try? (binary + " " + args.joined(separator: " ")).write(to: job.dir.appendingPathComponent("cmd.txt"), atomically: true, encoding: .utf8)

            job.stage = "slice"; job.progress = 0.2
            let logURL = job.dir.appendingPathComponent("orca.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = args
            p.currentDirectoryURL = job.dir
            if let fh = try? FileHandle(forWritingTo: logURL) { p.standardOutput = fh; p.standardError = fh }
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
            guard p.terminationStatus == 0, let gcode else {
                let code = Int(p.terminationStatus)
                let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                job.errorCode = code
                var msg = "Orca Exit \(code)"
                if logText.contains("Param values in 3mf/config error") {
                    msg += " – " + L("Die Einstellungen in dieser Datei passen nicht zu Snapmaker Orca (anderer Slicer oder anderer Drucker).",
                                     "The settings in this file do not fit Snapmaker Orca (another slicer or another printer).")
                } else if let reason = Self.validateReason(logText) { msg += " – " + reason }
                else if let known = Self.exitText(code) { msg += " – " + known }
                else {
                    let errs = logText.split(separator: "\n").filter { $0.lowercased().contains("error") && !$0.contains("calc_exclude_triangles") }.suffix(3)
                    if !errs.isEmpty { msg += ": " + errs.map { String($0.suffix(160)) }.joined(separator: " | ") }
                }
                throw SliceError.message(msg)
            }
            var summary = Self.summary(of: gcode)
            summary["gcode"] = gcode.lastPathComponent
            summary["slicer"] = "Snapmaker Orca \(SnapmakerOrca.version ?? "")"
            summary["source"] = "snapmaker_orca"
            summary["project"] = true
            summary["size"] = (try? FileManager.default.attributesOfItem(atPath: gcode.path)[.size] as? Int) ?? 0
            job.result = summary
            job.state = "done"; job.progress = 1; job.stage = "done"
            log("Job \(job.id) " + L("fertig", "done") + ": \(summary["filament_g"] ?? 0) g, \(summary["time_s"] ?? 0) s")
        } catch {
            job.state = "failed"; job.error = error.localizedDescription; job.stage = "failed"
            log("Job \(job.id) " + L("fehlgeschlagen", "failed") + ": \(error.localizedDescription)")
        }
    }
}
