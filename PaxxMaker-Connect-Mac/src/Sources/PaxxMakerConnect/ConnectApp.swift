import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ServiceManagement
import CryptoKit
import Darwin

// PaxxMaker-Connect — menu bar app. Starts the HTTP service for the
// PaxxMaker iOS app, shows the pairing code (and as QR), whether OrcaSlicer
// and profiles were found, and the last jobs.

/// German on a German Mac, English everywhere else.
let isGerman = Locale.preferredLanguages.first?.lowercased().hasPrefix("de") ?? false
func L(_ de: String, _ en: String) -> String { isGerman ? de : en }

final class ConnectState: ObservableObject {
    static let shared = ConnectState()
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    static let port: UInt16 = 8765
    /// True once the app lives in a Programme folder — only then is "start at
    /// login" stable and the download's DMG can be ejected.
    static let inApplications = Bundle.main.bundlePath.hasPrefix("/Applications/") || Bundle.main.bundlePath.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/")

    @Published var running = false
    @Published var lastError: String? = nil
    @Published var log: [String] = []
    @Published var jobs: [SliceJob] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    let token: String
    let stateDir: URL
    let jobsDir: URL
    let modelsDir: URL
    private var server: HTTPServer?
    private let lock = NSLock()
    private lazy var runner = SliceRunner(modelsDir: modelsDir)

    init() {
        stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PaxxMaker-Connect")
        jobsDir = stateDir.appendingPathComponent("jobs")
        modelsDir = stateDir.appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: jobsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
                let tokenURL = stateDir.appendingPathComponent("token")
        if let t = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count == 6 {
            token = t
        } else {
            let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
            token = String((0..<6).map { _ in chars.randomElement()! })
            try? token.write(to: tokenURL, atomically: true, encoding: .utf8)
        }
        start()
        cleanupOldJobs()
    }

    var hostName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    /// What the phone should dial: the Mac's LAN IPv4, else its Bonjour name.
    var reachableHost: String {
        var addr: String? = nil
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let cur = p {
                let i = cur.pointee
                if let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                   (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (i.ifa_flags & UInt32(IFF_UP)) != 0 {
                    let name = String(cString: i.ifa_name)
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let s = String(cString: host)
                        // Prefer Wi-Fi/Ethernet (en*) over VPN/virtual interfaces.
                        if name.hasPrefix("en") && !s.hasPrefix("169.254") { addr = s; break }
                        if addr == nil, !s.hasPrefix("169.254") { addr = s }
                    }
                }
                p = i.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        if let a = addr { return a }
        let local = ProcessInfo.processInfo.hostName
        return local.hasSuffix(".local") ? local : local + ".local"
    }
    var orcaInstalled: Bool { Orca.installed }
    var orcaVersion: String? { Orca.version }
    var installedApps: [OrcaApp] { OrcaApp.installed }

    func start() {
        let s = HTTPServer(port: Self.port) { [weak self] req in self?.route(req) ?? .json(["error": "gone"], status: 500) }
        do {
            try s.start(serviceName: "PaxxMaker-Connect (\(hostName))", txt: ["v": Self.version, "host": hostName])
            server = s
            running = true
            lastError = nil
            append(L("Dienst gestartet auf Port \(Self.port)", "Service started on port \(Self.port)"))
        } catch {
            running = false
            lastError = error.localizedDescription
            append(L("Start fehlgeschlagen: ", "Start failed: ") + error.localizedDescription)
        }
    }

    func stop() { server?.stop(); server = nil; running = false }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = on
        } catch {
            append(L("Anmeldeobjekt: ", "Login item: ") + error.localizedDescription)
        }
    }

    private func append(_ line: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        DispatchQueue.main.async {
            self.log.append("\(f.string(from: Date()))  \(line)")
            if self.log.count > 200 { self.log.removeFirst(self.log.count - 200) }
        }
    }

    /// Jobs older than a day are removed — the G-code lives on the printer.
    private func cleanupOldJobs() {
        let fm = FileManager.default
        for d in (try? fm.contentsOfDirectory(at: jobsDir, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            if let c = try? d.resourceValues(forKeys: [.creationDateKey]).creationDate, Date().timeIntervalSince(c) > 86400 {
                try? fm.removeItem(at: d)
            }
        }
    }

    // MARK: routes

    private func route(_ req: HTTPRequest) -> HTTPResponse {
        if req.method == "GET", req.path == "/v1/info" {
            return .json(["name": "PaxxMaker-Connect", "version": Self.version, "host": hostName,
                          "orca": orcaInstalled, "apps": installedApps.map(\.key)])
        }
        guard req.headers["x-paxx-token"] == token else { return .json(["error": "token"], status: 401) }

        if req.method == "GET", req.path == "/v1/profiles" {
            guard let app = OrcaApp.named(req.query["app"] ?? "orca") else { return .json(["error": "app"], status: 404) }
            let idx = ProfileIndex(app: app)
            let av = idx.available()
            var out: JSONObject = [:]
            for kind in ProfileIndex.kinds {
                out[kind] = (av[kind] ?? []).map { p -> JSONObject in
                    var d: JSONObject = ["name": p.name, "origin": p.origin, "inherits": p.inherits,
                                         "compatible_printers": p.compatible ?? NSNull()]
                    if kind == "machine" { for (k, v) in idx.machineInfo(p.name) { d[k] = v } }
                    return d
                }
            }
            return .json(out)
        }
        // One preset flattened through its inheritance chain — the app shows
        // its values as the starting point of the quick settings.
        if req.method == "GET", req.path == "/v1/profile" {
            guard let app = OrcaApp.named(req.query["app"] ?? "orca") else { return .json(["error": "app"], status: 404) }
            let kind = req.query["kind"] ?? "process"
            guard ProfileIndex.kinds.contains(kind), let name = req.query["name"],
                  let r = ProfileIndex(app: app).resolve(kind: kind, name: name) else { return .json(["error": "preset"], status: 404) }
            return .json(r.dict)
        }
        if req.method == "POST", req.path == "/v1/models" {
            let ext = (req.headers["x-paxx-ext"] ?? "stl").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard ext == "stl" else { return .json(["error": "ext"], status: 400) }
            let hash = SHA256.hash(data: req.body).map { String(format: "%02x", $0) }.joined().prefix(24)
            let id = "\(hash).\(ext)"
            try? req.body.write(to: modelsDir.appendingPathComponent(id))
            return .json(["model": id, "bytes": req.body.count])
        }
        if req.method == "POST", req.path == "/v1/jobs" {
            guard let spec = try? JSONSerialization.jsonObject(with: req.body) as? JSONObject else { return .json(["error": "json"], status: 400) }
            let job = SliceJob(spec: spec, jobsDir: jobsDir)
            lock.lock(); jobs.insert(job, at: 0); if jobs.count > 20 { jobs.removeLast(jobs.count - 20) }; lock.unlock()
            append("Job \(job.id): \(spec["process"] ?? "") " + L("auf", "on") + " \(spec["machine"] ?? "")")
            DispatchQueue.main.async { self.objectWillChange.send() }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                self.runner.run(job) { self.append($0) }
                DispatchQueue.main.async { self.objectWillChange.send() }
            }
            return .json(job.json, status: 202)
        }
        if req.method == "GET", req.path.hasPrefix("/v1/jobs/") {
            let rest = req.path.dropFirst("/v1/jobs/".count)
            let parts = rest.split(separator: "/")
            guard let idPart = parts.first else { return .json(["error": "job"], status: 404) }
            lock.lock(); let job = jobs.first { $0.id == idPart }; lock.unlock()
            guard let job else { return .json(["error": "job"], status: 404) }
            if parts.count == 2, parts[1] == "gcode" {
                guard job.state == "done", let name = job.result?["gcode"] as? String,
                      let data = try? Data(contentsOf: job.dir.appendingPathComponent(name)) else { return .json(["error": "not done"], status: 409) }
                return HTTPResponse(status: 200, headers: ["Content-Type": "text/plain"], body: data)
            }
            return .json(job.json)
        }
        return .json(["error": "path"], status: 404)
    }
}

// MARK: - UI

@main
struct ConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = ConnectState.shared

    var body: some Scene {
        MenuBarExtra {
            ConnectMenu().environmentObject(state)
        } label: {
            Image(systemName: state.running ? "cube.transparent.fill" : "cube.transparent")
        }
        .menuBarExtraStyle(.window)
    }
}

/// A menu bar app shows nothing when it starts — so the first start (and a
/// double-click on the app while it runs) opens a window with the pairing
/// code instead of leaving people hunting for the icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        // The install/uninstall scripts drive the login item through
        // arguments: `--login-item on|off`, `--show-window`, `--uninstall` (quits).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--login-item"), i + 1 < args.count {
            ConnectState.shared.setLaunchAtLogin(args[i + 1] == "on")
        }
        if args.contains("--uninstall") {
            ConnectState.shared.setLaunchAtLogin(false)
            NSApp.terminate(nil)
            return
        }
        // The app has no Dock icon and no window of its own — a double-click
        // that shows nothing looks like "it didn't start". So a start by hand
        // always opens the pairing window; only the automatic start right
        // after logging in stays quiet.
        let d = UserDefaults.standard
        let quiet = ConnectState.shared.launchAtLogin && ProcessInfo.processInfo.systemUptime < 300
        if args.contains("--show-window") || !d.bool(forKey: "welcomed") || !quiet {
            d.set(true, forKey: "welcomed")
            MainWindow.show()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainWindow.show()
        return false
    }
}

enum MainWindow {
    private static var window: NSWindow?
    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: ConnectMenu(inWindow: true).environmentObject(ConnectState.shared))
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.title = "PaxxMaker-Connect"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ConnectMenu: View {
    @EnvironmentObject var state: ConnectState
    /// In the window the QR code is bigger and the "open window" button is gone.
    var inWindow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "cube.transparent.fill").font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("PaxxMaker-Connect \(ConnectState.version)").font(.headline)
                    Text(state.running ? L("Bereit", "Ready") + " · Port \(ConnectState.port) · \(state.hostName)" : (state.lastError ?? L("Gestoppt", "Stopped")))
                        .font(.caption).foregroundStyle(state.running ? .secondary : Color.orange)
                }
                Spacer()
                if !inWindow {
                    Button { MainWindow.show() } label: { Image(systemName: "macwindow") }
                        .buttonStyle(.borderless).help(L("Als Fenster öffnen", "Open as window"))
                }
            }

            if inWindow {
                Text(L("PaxxMaker-Connect läuft als Würfel-Symbol oben in der Menüleiste. Dieses Fenster kann geschlossen werden — der Dienst läuft weiter.",
                       "PaxxMaker-Connect lives as a cube icon in the menu bar. This window can be closed — the service keeps running."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !ConnectState.inApplications {
                Label(L("Die App liegt noch nicht im Programme-Ordner. Bitte dorthin ziehen, sonst geht der Autostart nicht.",
                        "The app is not in the Applications folder yet. Please move it there, otherwise start at login won't work."), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(alignment: .top, spacing: 14) {
                QRView(text: "paxxmaker://connect?host=\(state.reachableHost)&port=\(ConnectState.port)&code=\(state.token)&name=\(state.hostName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
                    .frame(width: inWindow ? 128 : 96, height: inWindow ? 128 : 96)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Kopplungscode", "Pairing code")).font(.caption).foregroundStyle(.secondary)
                    Text(state.token).font(.system(size: 26, weight: .bold, design: .monospaced)).textSelection(.enabled)
                    Text(L("QR-Code mit der iPhone-Kamera scannen — PaxxMaker koppelt sich dann von selbst. Oder in PaxxMaker unter Slicer › Manuell verbinden den Code eingeben.",
                           "Scan the QR code with the iPhone camera — PaxxMaker pairs by itself. Or enter the code in PaxxMaker under Slicer › Connect manually."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Label(state.orcaInstalled ? "OrcaSlicer \(state.orcaVersion ?? "") " + L("gefunden", "found") : L("OrcaSlicer fehlt — bitte installieren (Snapmaker Orca allein reicht nicht)", "OrcaSlicer missing — please install it (Snapmaker Orca alone is not enough)"),
                      systemImage: state.orcaInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(state.orcaInstalled ? .green : .red)
                let apps = state.installedApps
                Label(apps.isEmpty ? L("Keine Orca-Profile gefunden", "No Orca profiles found") : L("Profile aus: ", "Profiles from: ") + apps.map { $0.key == "snapmaker_orca" ? "Snapmaker Orca" : "OrcaSlicer" }.joined(separator: ", "),
                      systemImage: apps.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(apps.isEmpty ? .red : .green)
            }
            .font(.caption)

            if !state.jobs.isEmpty {
                Divider()
                Text(L("Letzte Aufträge", "Recent jobs")).font(.caption).foregroundStyle(.secondary)
                ForEach(state.jobs.prefix(4), id: \.id) { j in
                    HStack {
                        Image(systemName: j.state == "done" ? "checkmark.circle" : j.state == "failed" ? "xmark.circle" : "clock")
                            .foregroundStyle(j.state == "done" ? .green : j.state == "failed" ? .red : .secondary)
                        Text((j.spec["process"] as? String) ?? "Job").lineLimit(1)
                        Spacer()
                        if j.state == "done", let g = j.result?["filament_g"] as? Double, let t = j.result?["time_s"] as? Int {
                            Text(String(format: "%.1f g · %d min", g, t / 60)).foregroundStyle(.secondary)
                        } else if j.state == "failed" {
                            Text(j.error ?? "").foregroundStyle(.red).lineLimit(1)
                        } else {
                            Text("\(Int(j.progress * 100)) %").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }

            Divider()

            Toggle(L("Bei Anmeldung starten", "Start at login"), isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                .font(.caption)
            HStack {
                Button(state.running ? L("Dienst stoppen", "Stop service") : L("Dienst starten", "Start service")) { state.running ? state.stop() : state.start() }
                Spacer()
                Button(L("Beenden", "Quit")) { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: inWindow ? 400 : 360)
    }
}

/// QR code for the pairing string, rendered with Core Image.
struct QRView: View {
    let text: String
    var body: some View {
        if let img = Self.image(text) {
            Image(nsImage: img).resizable().interpolation(.none).scaledToFit()
                .background(Color.white).cornerRadius(6)
        } else {
            Color.gray
        }
    }
    static func image(_ s: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let ci = f.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size); img.addRepresentation(rep)
        return img
    }
}
