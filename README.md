# PaxxMaker-Connect

[![Plattform](https://img.shields.io/badge/Plattform-macOS%2013%2B%20%7C%20Windows%2010%2B-blue)](#voraussetzungen)
[![Sprache](https://img.shields.io/badge/Sprache-Swift%20%7C%20Go-orange)](#technologien)
[![Status](https://img.shields.io/badge/Status-Beta-yellow)](#projektstatus)

PaxxMaker-Connect ist eine kleine Helfer-App für macOS und Windows. Sie verbindet die iPhone-/iPad-App **PaxxMaker** mit dem auf dem Rechner installierten **OrcaSlicer**.

Das Modell wird auf dem Mobilgerät platziert, gedreht, skaliert und bemalt. PaxxMaker-Connect lässt OrcaSlicer im Hintergrund (headless) slicen und liefert den fertigen G-Code zurück an die App, die ihn anschließend direkt an den Drucker senden kann.

> **Keine Cloud, kein Konto, keine Telemetrie.** Die Kommunikation läuft vollständig im eigenen WLAN. Der Kopplungscode bleibt auf dem Rechner.

PaxxMaker-Connect verändert OrcaSlicer nicht. Es liest dessen Profile und verwendet die vorhandene Kommandozeile.

## Zielgruppe

Das Projekt richtet sich insbesondere an Besitzer eines **Snapmaker U1** mit vier Druckköpfen und Multicolor-Unterstützung sowie an Nutzer von **Klipper-/Moonraker-Druckern**, zum Beispiel einem Creality Ender 3 S1. Voraussetzung ist ein Mac oder Windows-PC im selben Netzwerk, auf dem OrcaSlicer installiert ist.

## Funktionen

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

### Snapmaker U1

Bei einem Druck mit nur einem Kopf wird die Platte für `T0` gesliced und der G-Code anschließend auf den gewählten Kopf umgeschrieben.

Bei mehreren Köpfen werden vier Filamentprofile in der Kopfreihenfolge übergeben. OrcaSlicer übernimmt Werkzeugwechsel und Reinigungsturm. Die Position des Turms kommt aus der App; falls keine Position angegeben ist, sucht PaxxMaker-Connect die erste freie Ecke.

## Screenshots und Demo

> Screenshots und ein Demo-Video werden ergänzt.

| Kopplung | Slicer-Tab | G-Code-Vorschau |
|---|---|---|
| `screenshots/pairing.png` | `screenshots/slicer.png` | `screenshots/gcode-preview.png` |

## Voraussetzungen

Auf beiden Plattformen erforderlich:

- Installierter **OrcaSlicer**, getestet mit Version `2.4.2`
- Die iOS-/iPadOS-App **PaxxMaker**
- Rechner und iPhone/iPad im selben Netzwerk
- Ein unterstützter Drucker mit passender Netzwerkverbindung

> Snapmaker Orca allein reicht nicht aus, da dessen Kommandozeile nicht slicen kann. Die Profile von Snapmaker Orca werden jedoch mitgelesen, falls es installiert ist.

### macOS

- macOS 13 Ventura oder neuer
- Swift 5.9 / SwiftUI-Ausgabe

### Windows

- Windows 10 oder Windows 11, 64 Bit
- Eine einzelne ausführbare Datei ohne zusätzliche Laufzeitumgebung, ungefähr 9 MB

## Installation

### macOS

1. Das Release-DMG `PaxxMaker-Connect-<Version>.dmg` öffnen.
2. `PaxxMaker-Connect Install.command` doppelklicken. Das Skript kopiert die App nach „Programme“, prüft OrcaSlicer, fragt nach dem Autostart und startet die App.
3. Alternativ die App manuell nach `Applications` ziehen und starten.
4. Beim ersten Start unter macOS den Hinweis zum nicht verifizierten Entwickler über **Systemeinstellungen → Datenschutz & Sicherheit → Trotzdem öffnen** bestätigen.
5. Fragen zu eingehenden Verbindungen und zum lokalen Netzwerk mit **Erlauben** bestätigen.

Zum Entfernen `PaxxMaker-Connect Deinstall.command` ausführen.

Die macOS-Ausgabe läuft als Menüleisten-App mit Würfel-Symbol. Das Kopplungsfenster mit Code und QR-Code kann durch einen Doppelklick auf die App erneut geöffnet werden. Autostart wird über `SMAppService` verwaltet.

### Windows

1. Das Release-ZIP `PaxxMaker-Connect-Windows-<Version>.zip` vollständig entpacken. Die Anwendung nicht direkt aus dem ZIP starten.
2. `PaxxMaker-Connect Install.cmd` doppelklicken.
3. Die App wird nach `%LocalAppData%\Programs\PaxxMaker-Connect` kopiert und ein Startmenü-Eintrag angelegt.
4. Optional Firewall-Regel und Autostart aktivieren.
5. Beim ersten Start die SmartScreen-Meldung über **Weitere Informationen → Trotzdem ausführen** bestätigen.
6. Die Firewall-Abfrage für private Netzwerke mit **Zugriff zulassen** bestätigen.

Zum Entfernen `PaxxMaker-Connect Deinstall.cmd` ausführen.

Die Windows-Ausgabe läuft im Infobereich der Taskleiste. Die lokale Kopplungsseite ist unter [http://127.0.0.1:8765/](http://127.0.0.1:8765/) erreichbar. Dort werden unter anderem Code, QR-Code, Orca-Status, letzte Aufträge und Protokolle angezeigt.

### Koppeln mit PaxxMaker

1. In PaxxMaker **Slicer → Per QR-Code verbinden** öffnen und den QR-Code scannen.
2. Alternativ **Manuell verbinden** wählen, den Mac/PC aus der Netzwerkliste auswählen oder seine IP-Adresse eingeben.
3. Den sechsstelligen Kopplungscode eingeben.

## Selbst bauen

### macOS

```bash
./build.sh
```

Erzeugt `build/PaxxMaker-Connect.app` sowie die Release-Dateien unter `dist/`. Für die Notarisierung:

```bash
./build.sh notarize
```

Dafür werden ein Developer-ID-Zertifikat und ein `notarytool`-Profil namens `paxx-notary` benötigt.

### Windows

Auf macOS oder Linux:

```bash
./build.sh
```

Unter Windows:

```bat
build.cmd
```

Der Build erzeugt die `.exe` und ein Release-ZIP. Benötigt wird nur Go.

## Technologien

### macOS

- Swift 5.9
- SwiftUI
- Swift Package Manager
- Network.framework für HTTP und Bonjour
- Eigener kleiner HTTP-Server
- Eigene ZIP-/3MF-Verarbeitung
- Keine externen Abhängigkeiten

### Windows

Die Windows-Ausgabe ist ein Go-Port derselben Logik und verwendet:

- Go 1.26
- `fyne.io/systray`
- `github.com/grandcat/zeroconf`
- `github.com/skip2/go-qrcode`
- `golang.org/x/sys`
- `go-winres` für Icon und Versionsinformationen

Bonjour/mDNS ist unter Windows eingebaut; Apple Bonjour muss nicht installiert werden.

## Konfiguration

Es gibt keine reguläre Konfigurationsdatei. Zustand und Arbeitsdateien werden automatisch gespeichert:

- **macOS:** `~/Library/Application Support/PaxxMaker-Connect`
- **Windows:** `%AppData%\PaxxMaker-Connect`

Darin befinden sich unter anderem der Kopplungscode sowie die Verzeichnisse `jobs/` und `models/`.

### Umgebungsvariablen

| Variable | Beschreibung |
|---|---|
| `PAXX_STATE_DIR` | Alternativer Zustandsordner |
| `PAXX_ORCA` | Vollständiger Pfad zur OrcaSlicer-Binärdatei |
| `PAXX_ORCA_DATA` | Ordner mit den Orca-Profilordnern |
| `PAXX_LANG` | `de` oder `en`; überschreibt die Systemsprache |

Zusätzlich unterstützt die Windows-Ausgabe `--port <n>` für einen abweichenden Port. Weitere Startargumente sind `--show-window`, `--login-item on|off` und `--uninstall`. Die macOS-Ausgabe unterstützt dieselben Argumente über `open -a ... --args ...`.

## Architektur und API

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

## Projektstatus

**Beta.** PaxxMaker-Connect läuft im täglichen Einsatz mit einem Snapmaker U1 und einem Creality Ender 3 S1. Die macOS-Ausgabe ist ausgiebig getestet. Die Windows-Ausgabe ist ein geprüfter Port mit identischer Profilauflösung und identischem G-Code im Vergleich zur Mac-Ausgabe und wurde gegen OrcaSlicer 2.4.2 verglichen; Tests auf echter Windows-Hardware sind jedoch noch begrenzt.

Die aktuellen Ausgaben sind nicht signiert bzw. notarisiert. Deshalb ist beim ersten Start die einmalige Gatekeeper- bzw. SmartScreen-Bestätigung erforderlich.

## Roadmap

- Notarisierung und Signierung für macOS und Windows
- Linux-Ausgabe
- Unterstützung mehrerer Platten pro Auftrag
- Feinere Steuerung der Profilauswahl

## Mitwirken

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

## Lizenz und Haftungsausschluss

> **Hinweis:** Für dieses Projekt ist derzeit keine Lizenzdatei hinterlegt. Vor einer Veröffentlichung sollte eine Lizenz, zum Beispiel MIT, ergänzt werden.

PaxxMaker und PaxxMaker-Connect sind unabhängige Hobbyprojekte und stehen in keiner Verbindung zu Snapmaker oder zum OrcaSlicer-Projekt. Alle genannten Marken gehören ihren jeweiligen Inhabern.

## English

PaxxMaker-Connect is a small macOS and Windows helper application that connects the iPhone/iPad app **PaxxMaker** with a locally installed **OrcaSlicer** instance.

Models can be positioned, rotated, scaled and painted on the mobile device. PaxxMaker-Connect runs OrcaSlicer headlessly, returns the generated G-code to the app and allows it to send the job directly to the printer.

There is no cloud service, account or telemetry. Communication stays on the local network, and OrcaSlicer itself is not modified. PaxxMaker-Connect only reads OrcaSlicer profiles and uses its command-line interface.

The project is currently in beta and supports macOS 13 or later and Windows 10/11 64-bit. OrcaSlicer 2.4.2 is the tested version. See the German sections above for installation, configuration, API details and contribution guidelines.
