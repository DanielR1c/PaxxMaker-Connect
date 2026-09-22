# PaxxMaker-Connect

[![Platform](https://img.shields.io/badge/Platform-macOS%2013%2B%20%7C%20Windows%2010%2B-blue)](#requirements)
[![Languages](https://img.shields.io/badge/Languages-Swift%20%7C%20Go-orange)](#technologies)
[![Status](https://img.shields.io/badge/Status-Beta-yellow)](#project-status)

## English

PaxxMaker-Connect is a small macOS and Windows helper application that connects the iPhone/iPad app **PaxxMaker** with a locally installed **OrcaSlicer** instance.

The model is positioned, rotated, scaled and painted on the mobile device. PaxxMaker-Connect runs OrcaSlicer headlessly in the background and sends the generated G-code back to the app, which can then send it directly to the printer.

> **No cloud, no account, no telemetry.** Communication stays entirely on the local network. The pairing code is stored only on the computer.

PaxxMaker-Connect does not modify OrcaSlicer. It only reads its profiles and uses its command-line interface.

### Target audience

PaxxMaker-Connect is intended especially for owners of a **Snapmaker U1** with four toolheads and multicolor support, as well as users of **Klipper/Moonraker printers**, such as the Creality Ender 3 S1. A Mac or Windows PC running OrcaSlicer is required on the same network.

### Features

- Local service on port `8765`
- Network discovery via Bonjour/mDNS (`_paxxconnect._tcp`)
- Pairing with a six-digit code or QR code
- Token authentication using the `X-Paxx-Token` header
- Pairing code persists across restarts
- Reads printer, process and filament profiles from OrcaSlicer
- Reads Snapmaker Orca profiles when installed
- Resolves `inherits` chains into complete JSON profiles
- Accepts 3MF jobs with per-object transforms, toolhead assignments, settings and painted faces
- Runs OrcaSlicer headlessly
- Reports staged progress and provides print time, weight, cost, layer count and height
- Reads the effective support settings from the G-code footer
- Supports quick settings as CLI overrides, including layer height, walls, infill, supports, brim, skirt, spiral vase, print order and seam settings
- Supports the Snapmaker U1 with one or multiple toolheads
- Converts OrcaSlicer exit codes into understandable error messages
- Automatically removes jobs older than one day
- German on German systems, English otherwise

#### Snapmaker U1 support

For a single-toolhead print, the plate is sliced for `T0` and the resulting G-code is rewritten for the selected toolhead.

For multi-toolhead prints, four filament profiles are supplied in toolhead order. OrcaSlicer handles tool changes and the purge tower. The tower position is provided by the app; if no position is specified, Connect searches for the first free corner.

### Screenshots and demo

> Screenshots and a demo video will be added.

| Pairing | Slicer tab | G-code preview |
|---|---|---|
| `screenshots/pairing.png` | `screenshots/slicer.png` | `screenshots/gcode-preview.png` |

### Requirements

- Installed **OrcaSlicer**, tested with version `2.4.2`
- The **PaxxMaker** iOS/iPadOS app
- Computer and iPhone/iPad on the same network
- A supported printer with a suitable network connection

> Snapmaker Orca alone is not sufficient because its command line cannot perform slicing. Its profiles are still read when it is installed.

#### macOS

- macOS 13 Ventura or newer
- Swift 5.9 / SwiftUI build

#### Windows

- Windows 10 or Windows 11, 64-bit
- A single executable with no additional runtime, approximately 9 MB

### Installation

#### macOS

1. Open the release DMG: `PaxxMaker-Connect-<Version>.dmg`.
2. Double-click `PaxxMaker-Connect Install.command`. The script copies the app to Applications, checks OrcaSlicer, asks about autostart and launches the app.
3. Alternatively, drag the app to `Applications` and launch it manually.
4. On the first launch, allow the app under **System Settings → Privacy & Security → Open Anyway** because the app is not notarized.
5. Allow incoming connections and local network access when macOS asks.

To uninstall, run `PaxxMaker-Connect Deinstall.command`.

The macOS build runs as a menu bar app with a cube icon. Double-clicking the app opens the pairing window again. Autostart is managed through `SMAppService`.

#### Windows

1. Extract `PaxxMaker-Connect-Windows-<Version>.zip` completely. Do not run the app from inside the ZIP.
2. Double-click `PaxxMaker-Connect Install.cmd`.
3. The app is copied to `%LocalAppData%\\Programs\\PaxxMaker-Connect` and a Start Menu entry is created.
4. Optionally enable the firewall rule and autostart.
5. On the first launch, confirm the SmartScreen prompt with **More info → Run anyway** because the file is not signed.
6. Allow access for private networks when Windows Firewall asks.

To uninstall, run `PaxxMaker-Connect Deinstall.cmd`.

The Windows build runs in the system tray. Its local pairing page is available at [http://127.0.0.1:8765/](http://127.0.0.1:8765/), showing the code, QR code, Orca status, recent jobs and logs.

#### Pairing with PaxxMaker

1. In PaxxMaker, open **Slicer → Connect via QR code** and scan the QR code.
2. Alternatively, choose **Connect manually**, select the Mac/PC from the network list or enter its IP address.
3. Enter the six-digit pairing code.

### Building from source

#### macOS

```bash
./build.sh
```

This creates `build/PaxxMaker-Connect.app` and release files in `dist/`. To notarize the build:

```bash
./build.sh notarize
```

A Developer ID certificate and a `notarytool` profile named `paxx-notary` are required.

#### Windows

On macOS or Linux:

```bash
./build.sh
```

On Windows:

```bat
build.cmd
```

The build creates the `.exe` and a release ZIP. Only Go is required.

### Technologies

#### macOS

- Swift 5.9
- SwiftUI
- Swift Package Manager
- Network.framework for HTTP and Bonjour
- Small custom HTTP server
- Custom ZIP/3MF handling
- No external dependencies

#### Windows

The Windows build is a Go port of the same logic and uses:

- Go 1.26
- `fyne.io/systray`
- `github.com/grandcat/zeroconf`
- `github.com/skip2/go-qrcode`
- `golang.org/x/sys`
- `go-winres` for icon and version information

Bonjour/mDNS is built in on Windows; Apple Bonjour is not required.

### Configuration

There is no regular configuration file. State and working files are stored automatically:

- **macOS:** `~/Library/Application Support/PaxxMaker-Connect`
- **Windows:** `%AppData%\\PaxxMaker-Connect`

This directory contains the pairing token and the `jobs/` and `models/` directories.

#### Environment variables

| Variable | Description |
|---|---|
| `PAXX_STATE_DIR` | Alternative state directory |
| `PAXX_ORCA` | Full path to the OrcaSlicer binary |
| `PAXX_ORCA_DATA` | Directory containing Orca profile folders |
| `PAXX_LANG` | `de` or `en`; overrides the system language |

The Windows build also supports `--port <n>` for a custom port. Other startup arguments are `--show-window`, `--login-item on|off` and `--uninstall`. The macOS build supports the same arguments through `open -a ... --args ...`.

### Architecture and API

The API is normally used only by PaxxMaker. All routes except `/v1/info` require this header:

```http
X-Paxx-Token: <pairing-code>
```

| Method | Route | Description |
|---|---|---|
| `GET` | `/v1/info` | Name, version, hostname, Orca status and discovered profile directories |
| `GET` | `/v1/profiles?app=orca\|snapmaker_orca` | Printer, process and filament profiles |
| `GET` | `/v1/profile?app=...&kind=...&name=...` | Fully resolved preset |
| `POST` | `/v1/models` | Upload STL data; use `X-Paxx-Ext: stl` |
| `POST` | `/v1/jobs` | Create a slicing job with profiles, filaments, overrides and objects |
| `GET` | `/v1/jobs/<id>` | Status, progress, result or error |
| `GET` | `/v1/jobs/<id>/gcode` | Generated G-code |

`POST /v1/jobs` responds with `202 Accepted` and a job ID. The Windows build additionally provides a local-only interface at `/`, `/qr.png`, `/ui/state`, `/ui/autostart` and `/ui/quit`.

### Project status

**Beta.** PaxxMaker-Connect is used daily with a Snapmaker U1 and a Creality Ender 3 S1. The macOS build has been extensively tested. The Windows build is a verified port with matching profile resolution and matching G-code compared with the macOS build, and has been tested against OrcaSlicer 2.4.2; testing on real Windows hardware is still limited.

The current builds are not signed or notarized, so the one-time Gatekeeper or SmartScreen confirmation is required on first launch.

### Roadmap

- Notarization and signing for macOS and Windows
- Linux build
- Multiple plates per job
- More granular profile selection

### Contributing

Bug reports and improvements are welcome. Please include the following in an issue:

- Operating system and version
- PaxxMaker-Connect version
- OrcaSlicer version
- Printer model
- Error message shown by the app
- For slicing errors, the `Orca Exit` number if available

Pull requests should briefly describe what was changed and tested. Both builds should behave consistently; changes to slicing logic should therefore be implemented in both Swift and Go where possible.

- Swift code: `swift-format`
- Go code: `gofmt`

### License and disclaimer

> **Note:** This repository currently does not contain a license file. Add a license, such as MIT, before distributing the project.

PaxxMaker and PaxxMaker-Connect are independent hobby projects and are not affiliated with Snapmaker or the OrcaSlicer project. All mentioned trademarks belong to their respective owners.

---

## Deutsch

PaxxMaker-Connect ist eine kleine Helfer-App für macOS und Windows. Sie verbindet die iPhone-/iPad-App **PaxxMaker** mit dem auf dem Rechner installierten **OrcaSlicer**.

Das Modell wird auf dem Mobilgerät platziert, gedreht, skaliert und bemalt. PaxxMaker-Connect lässt OrcaSlicer im Hintergrund (headless) slicen und liefert den fertigen G-Code zurück an die App, die ihn anschließend direkt an den Drucker senden kann.

> **Keine Cloud, kein Konto, keine Telemetrie.** Die Kommunikation läuft vollständig im eigenen WLAN. Der Kopplungscode bleibt auf dem Rechner.

PaxxMaker-Connect verändert OrcaSlicer nicht. Es liest dessen Profile und verwendet die vorhandene Kommandozeile.

### Zielgruppe

Das Projekt richtet sich insbesondere an Besitzer eines **Snapmaker U1** mit vier Druckköpfen und Multicolor-Unterstützung sowie an Nutzer von **Klipper-/Moonraker-Druckern**, zum Beispiel einem Creality Ender 3 S1. Voraussetzung ist ein Mac oder Windows-PC im selben Netzwerk, auf dem OrcaSlicer installiert ist.

### Funktionen

- Lokaler Dienst auf Port `8765`
- Erkennung im Netzwerk per Bonjour/mDNS (`_paxxconnect._tcp`)
- Kopplung per sechsstelliger Code oder QR-Code
- Absicherung aller Anfragen mit dem Header `X-Paxx-Token`
- Kopplungscode bleibt über Neustarts hinweg erhalten
- Auslesen von Drucker-, Prozess- und Filamentprofilen aus OrcaSlicer
- Unterstützung von Snapmaker Orca-Profilen, falls installiert
- Auflösung von `inherits`-Ketten in vollständige JSON-Profile
- Übergabe von 3MF-Dateien mit Transformationen, Druckkopfzuordnung, Objekt-Einstellungen und bemalten Flächen
- Headless-Slicing über OrcaSlicer
- Fortschrittsanzeige und Auswertung von Druckzeit, Gewicht, Kosten, Layeranzahl und Höhe
- Auslesen der tatsächlich verwendeten Support-Einstellungen aus dem G-Code-Footer
- Schnelleinstellungen als CLI-Overrides, unter anderem für Schichthöhe, Wände, Infill, Support, Brim, Skirt, Spiralvase, Druckreihenfolge und Naht
- Snapmaker-U1-Unterstützung für einen oder mehrere Druckköpfe
- Verständliche Fehlermeldungen bei OrcaSlicer-Fehlern
- Automatische Bereinigung von Aufträgen, die älter als einen Tag sind
- Deutsch auf deutschen Systemen, sonst Englisch

#### Snapmaker-U1-Unterstützung

Bei einem Druck mit nur einem Kopf wird die Platte für `T0` gesliced und der G-Code anschließend auf den gewählten Kopf umgeschrieben.

Bei mehreren Köpfen werden vier Filamentprofile in der Kopfreihenfolge übergeben. OrcaSlicer übernimmt Werkzeugwechsel und Reinigungsturm. Die Position des Turms kommt aus der App; falls keine Position angegeben ist, sucht Connect die erste freie Ecke.

### Screenshots und Demo

> Screenshots und ein Demo-Video werden ergänzt.

| Kopplung | Slicer-Tab | G-Code-Vorschau |
|---|---|---|
| `screenshots/pairing.png` | `screenshots/slicer.png` | `screenshots/gcode-preview.png` |

### Voraussetzungen

- Installierter **OrcaSlicer**, getestet mit Version `2.4.2`
- Die iOS-/iPadOS-App **PaxxMaker**
- Rechner und iPhone/iPad im selben Netzwerk
- Ein unterstützter Drucker mit passender Netzwerkverbindung

> Snapmaker Orca allein reicht nicht aus, da dessen Kommandozeile nicht slicen kann. Die Profile von Snapmaker Orca werden jedoch mitgelesen, falls es installiert ist.

#### macOS

- macOS 13 Ventura oder neuer
- Swift 5.9 / SwiftUI-Ausgabe

#### Windows

- Windows 10 oder Windows 11, 64 Bit
- Eine einzelne ausführbare Datei ohne zusätzliche Laufzeitumgebung, ungefähr 9 MB

### Installation

#### macOS

1. Das Release-DMG `PaxxMaker-Connect-<Version>.dmg` öffnen.
2. `PaxxMaker-Connect Install.command` doppelklicken. Das Skript kopiert die App nach „Programme“, prüft OrcaSlicer, fragt nach dem Autostart und startet die App.
3. Alternativ die App manuell nach `Applications` ziehen und starten.
4. Beim ersten Start unter macOS den Hinweis zum nicht verifizierten Entwickler über **Systemeinstellungen → Datenschutz & Sicherheit → Trotzdem öffnen** bestätigen.
5. Fragen zu eingehenden Verbindungen und zum lokalen Netzwerk mit **Erlauben** bestätigen.

Zum Entfernen `PaxxMaker-Connect Deinstall.command` ausführen.

Die macOS-Ausgabe läuft als Menüleisten-App mit Würfel-Symbol. Das Kopplungsfenster mit Code und QR-Code kann durch einen Doppelklick auf die App erneut geöffnet werden. Autostart wird über `SMAppService` verwaltet.

#### Windows

1. Das Release-ZIP `PaxxMaker-Connect-Windows-<Version>.zip` vollständig entpacken. Die Anwendung nicht direkt aus dem ZIP starten.
2. `PaxxMaker-Connect Install.cmd` doppelklicken.
3. Die App wird nach `%LocalAppData%\\Programs\\PaxxMaker-Connect` kopiert und ein Startmenü-Eintrag angelegt.
4. Optional Firewall-Regel und Autostart aktivieren.
5. Beim ersten Start die SmartScreen-Meldung über **Weitere Informationen → Trotzdem ausführen** bestätigen.
6. Die Firewall-Abfrage für private Netzwerke mit **Zugriff zulassen** bestätigen.

Zum Entfernen `PaxxMaker-Connect Deinstall.cmd` ausführen.

Die Windows-Ausgabe läuft im Infobereich der Taskleiste. Die lokale Kopplungsseite ist unter [http://127.0.0.1:8765/](http://127.0.0.1:8765/) erreichbar. Dort werden unter anderem Code, QR-Code, Orca-Status, letzte Aufträge und Protokolle angezeigt.

#### Koppeln mit PaxxMaker

1. In PaxxMaker **Slicer → Per QR-Code verbinden** öffnen und den QR-Code scannen.
2. Alternativ **Manuell verbinden** wählen, den Mac/PC aus der Netzwerkliste auswählen oder seine IP-Adresse eingeben.
3. Den sechsstelligen Kopplungscode eingeben.

### Selbst bauen

#### macOS

```bash
./build.sh
```

Erzeugt `build/PaxxMaker-Connect.app` sowie die Release-Dateien unter `dist/`. Für die Notarisierung:

```bash
./build.sh notarize
```

Dafür werden ein Developer-ID-Zertifikat und ein `notarytool`-Profil namens `paxx-notary` benötigt.

#### Windows

Auf macOS oder Linux:

```bash
./build.sh
```

Unter Windows:

```bat
build.cmd
```

Der Build erzeugt die `.exe` und ein Release-ZIP. Benötigt wird nur Go.

### Technologien

#### macOS

- Swift 5.9
- SwiftUI
- Swift Package Manager
- Network.framework für HTTP und Bonjour
- Eigener kleiner HTTP-Server
- Eigene ZIP-/3MF-Verarbeitung
- Keine externen Abhängigkeiten

#### Windows

Die Windows-Ausgabe ist ein Go-Port derselben Logik und verwendet:

- Go 1.26
- `fyne.io/systray`
- `github.com/grandcat/zeroconf`
- `github.com/skip2/go-qrcode`
- `golang.org/x/sys`
- `go-winres` für Icon und Versionsinformationen

Bonjour/mDNS ist unter Windows eingebaut; Apple Bonjour muss nicht installiert werden.

### Konfiguration

Es gibt keine reguläre Konfigurationsdatei. Zustand und Arbeitsdateien werden automatisch gespeichert:

- **macOS:** `~/Library/Application Support/PaxxMaker-Connect`
- **Windows:** `%AppData%\\PaxxMaker-Connect`

Darin befinden sich unter anderem der Kopplungscode sowie die Verzeichnisse `jobs/` und `models/`.

#### Umgebungsvariablen

| Variable | Beschreibung |
|---|---|
| `PAXX_STATE_DIR` | Alternativer Zustandsordner |
| `PAXX_ORCA` | Vollständiger Pfad zur OrcaSlicer-Binärdatei |
| `PAXX_ORCA_DATA` | Ordner mit den Orca-Profilordnern |
| `PAXX_LANG` | `de` oder `en`; überschreibt die Systemsprache |

Zusätzlich unterstützt die Windows-Ausgabe `--port <n>` für einen abweichenden Port. Weitere Startargumente sind `--show-window`, `--login-item on|off` und `--uninstall`. Die macOS-Ausgabe unterstützt dieselben Argumente über `open -a ... --args ...`.

### Architektur und API

Normalerweise wird die API ausschließlich von PaxxMaker verwendet. Alle Routen außer `/v1/info` benötigen den Header:

```http
X-Paxx-Token: <Kopplungscode>
```

| Methode | Route | Beschreibung |
|---|---|---|
| `GET` | `/v1/info` | Name, Version, Hostname, Orca-Status und gefundene Profilordner |
| `GET` | `/v1/profiles?app=orca\|snapmaker_orca` | Drucker-, Prozess- und Filamentprofile |
| `GET` | `/v1/profile?app=...&kind=...&name=...` | Vollständig aufgelöstes Preset |
| `POST` | `/v1/models` | STL-Rohdaten hochladen; `X-Paxx-Ext: stl` verwenden |
| `POST` | `/v1/jobs` | Slicing-Auftrag mit Profilen, Filamenten, Overrides und Objekten anlegen |
| `GET` | `/v1/jobs/<id>` | Status, Fortschritt, Ergebnis oder Fehler |
| `GET` | `/v1/jobs/<id>/gcode` | Fertiger G-Code |

`POST /v1/jobs` antwortet mit `202 Accepted` und einer Auftrags-ID. Die Windows-Ausgabe bietet zusätzlich eine ausschließlich lokal erreichbare Oberfläche mit `/`, `/qr.png`, `/ui/state`, `/ui/autostart` und `/ui/quit`.

### Projektstatus

**Beta.** PaxxMaker-Connect läuft im täglichen Einsatz mit einem Snapmaker U1 und einem Creality Ender 3 S1. Die macOS-Ausgabe ist ausgiebig getestet. Die Windows-Ausgabe ist ein geprüfter Port mit identischer Profilauflösung und identischem G-Code im Vergleich zur Mac-Ausgabe und wurde gegen OrcaSlicer 2.4.2 verglichen; Tests auf echter Windows-Hardware sind jedoch noch begrenzt.

Die aktuellen Ausgaben sind nicht signiert bzw. notarisiert. Deshalb ist beim ersten Start die einmalige Gatekeeper- bzw. SmartScreen-Bestätigung erforderlich.

### Roadmap

- Notarisierung und Signierung für macOS und Windows
- Linux-Ausgabe
- Unterstützung mehrerer Platten pro Auftrag
- Feinere Steuerung der Profilauswahl

### Mitwirken

Fehlerberichte und Verbesserungen sind willkommen. Bitte erstelle ein Issue mit:

- Betriebssystem und Version
- PaxxMaker-Connect-Version
- OrcaSlicer-Version
- Druckermodell
- Fehlermeldung aus der App
- Bei Slicing-Fehlern möglichst auch die `Orca Exit`-Nummer

Pull Requests sollten kurz beschreiben, was geändert und getestet wurde. Beide Ausgaben sollen sich möglichst gleich verhalten; Änderungen an der Slicing-Logik sollten daher nach Möglichkeit sowohl in Swift als auch in Go umgesetzt werden.

- Swift-Code: `swift-format`
- Go-Code: `gofmt`

### Lizenz und Haftungsausschluss

> **Hinweis:** Für dieses Projekt ist derzeit keine Lizenzdatei hinterlegt. Vor einer Veröffentlichung sollte eine Lizenz, zum Beispiel MIT, ergänzt werden.

PaxxMaker und PaxxMaker-Connect sind unabhängige Hobbyprojekte und stehen in keiner Verbindung zu Snapmaker oder zum OrcaSlicer-Projekt. Alle genannten Marken gehören ihren jeweiligen Inhabern.
