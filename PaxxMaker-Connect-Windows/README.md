# PaxxMaker-Connect for Windows

*Deutsch – [English below](#english)*

Die Windows-Ausgabe von PaxxMaker-Connect: das Bindeglied zwischen der
PaxxMaker-App (iPhone/iPad) und OrcaSlicer auf dem PC. Modelle werden auf dem
Handy platziert und bemalt, PaxxMaker-Connect lässt den **installierten**
OrcaSlicer im Hintergrund slicen und schickt den G-Code zurück. Gleiche
Schnittstelle wie die Mac-Version (Port 8765, Bonjour, Kopplung per Code),
alles im eigenen Netzwerk – keine Cloud.

## Installation

**Voraussetzungen:** Windows 10/11 (64 Bit) · [OrcaSlicer](https://github.com/OrcaSlicer/OrcaSlicer/releases)
installiert · PC und iPhone im selben Netzwerk.

1. **Laden:** auf Github die neuste Version holen und öffnen.
2. **Installieren:** Doppelklick auf **`PaxxMaker-Connect Install.cmd`**.
   Das Skript kopiert die App in den Programme-Ordner des Benutzers, legt einen
   Startmenü-Eintrag an, fragt nach Firewall-Regel und Autostart, prüft OrcaSlicer
   und startet die App.
   Meldet Windows „Der Computer wurde durch Windows geschützt“ (SmartScreen):
   **„Weitere Informationen“ › „Trotzdem ausführen“** – nur einmal nötig.
   Fragt die Firewall: **„Zugriff zulassen“** (privates Netz).
3. **Koppeln:** Im Browser öffnet sich die Seite mit **Kopplungscode und QR-Code**. In
   PaxxMaker *Slicer › Per QR-Code verbinden* und scannen – oder *Manuell verbinden*
   und den 6-stelligen Code eintippen. Fertig.

Danach läuft die App als Symbol im Infobereich der Taskleiste (rechts unten, ggf.
hinter dem Pfeil): Klick › *Kopplung anzeigen…* bringt die Seite zurück, dort lassen
sich auch Autostart und Beenden schalten. **Entfernen:** Doppelklick auf
`PaxxMaker-Connect Deinstall.cmd`. 

## Was es tut
- Dienst auf Port 8765, Bonjour `_paxxconnect._tcp` (eingebaut, kein Apple-Bonjour nötig)
- Liest Drucker-/Prozess-/Filamentprofile aus `%AppData%\OrcaSlicer` (und
  `Snapmaker_Orca`, falls installiert) und löst `inherits`-Ketten auf
- Schreibt die Platte aus der App als 3MF (Transformationen, Kopf je Objekt,
  Objekt-Einstellungen, bemalte Flächen), ruft `orca-slicer-console.exe` headless auf
  und liest das Ergebnis aus dem G-Code
- U1: ein Kopf → `T0` wird zum gewählten Kopf umgeschrieben; mehrere Köpfe → vier
  Filamentprofile in Kopfreihenfolge, Orca macht Werkzeugwechsel und Reinigungsturm

Arbeitsdateien: `%AppData%\PaxxMaker-Connect` (Kopplungscode, letzte Jobs – räumen
sich nach einem Tag selbst auf). Installiert wird nach
`%LocalAppData%\Programs\PaxxMaker-Connect` – ohne Admin-Rechte.

## Ordner
```
PaxxMaker-Connect Install.cmd     ← Doppelklick: installieren
PaxxMaker-Connect Deinstall.cmd   ← Doppelklick: entfernen
README.md
src/        Go-Quellcode, Installer-Skripte, build.sh / build.cmd
Release/    die fertige ZIP-Datei (entsteht beim Bauen)
```

## Selbst bauen
Ein Go-Programm (eine einzige `.exe`, keine Laufzeitumgebung nötig). Braucht
[Go](https://go.dev/dl/):
```
src/build.sh     # auf Mac/Linux: baut src/build/PaxxMaker-Connect.exe + Release/…zip
src\build.cmd    # auf Windows: baut src\build\PaxxMaker-Connect.exe
```
Die Datei ist nicht signiert – daher die einmalige SmartScreen-Nachfrage.

---

## English

The Windows edition of PaxxMaker-Connect: the link between the PaxxMaker app
(iPhone/iPad) and OrcaSlicer on your PC. Models are placed and painted on the
phone, PaxxMaker-Connect lets the **installed** OrcaSlicer slice in the background
and sends the G-code back. Same interface as the Mac version (port 8765, Bonjour,
pairing by code), everything on your own network – no cloud.

### Installation

**Requirements:** Windows 10/11 (64-bit) · [OrcaSlicer](https://github.com/OrcaSlicer/OrcaSlicer/releases)
installed · PC and iPhone on the same network.

1. **Download:** Download newes Version on GitHub and open it.
2. **Install:** double-click **`PaxxMaker-Connect Install.cmd`**.
   The script copies the app to the user's Programs folder, adds a Start menu entry,
   asks about a firewall rule and autostart, checks for OrcaSlicer and launches the app.
   If Windows shows "Windows protected your PC" (SmartScreen): **"More info" ›
   "Run anyway"** – needed only once. If the firewall asks: **"Allow access"** (private network).
3. **Pair:** your browser opens the page with the **pairing code and QR code**. In
   PaxxMaker go to *Slicer › Connect with QR code* and scan it – or *Connect manually*
   and type the 6-character code. Done.

The app then runs as an icon in the taskbar's notification area (bottom right, maybe
behind the arrow): click › *Show pairing…* brings the page back, where autostart and
quit can be toggled too. **Remove:** double-click `PaxxMaker-Connect Deinstall.cmd`.

### What it does
- Service on port 8765, Bonjour `_paxxconnect._tcp` (built in, no Apple Bonjour needed)
- Reads printer/process/filament profiles from `%AppData%\OrcaSlicer` (and
  `Snapmaker_Orca`, if installed) and resolves `inherits` chains
- Writes the plate from the app as 3MF (transforms, head per object, per-object
  settings, painted faces), runs `orca-slicer-console.exe` headless and reads the
  result off the G-code
- U1: one head → `T0` is rewritten to the chosen head; several heads → four filament
  profiles in head order, Orca does the tool changes and the prime tower

Working files: `%AppData%\PaxxMaker-Connect` (pairing code, recent jobs – they clean
themselves up after a day). Installed to `%LocalAppData%\Programs\PaxxMaker-Connect`
– no admin rights needed.

### Folders
```
PaxxMaker-Connect Install.cmd     ← double-click: install
PaxxMaker-Connect Deinstall.cmd   ← double-click: remove
README.md
src/        Go source, installer scripts, build.sh / build.cmd
Release/    the finished ZIP (created by the build)
```

### Building it yourself
A Go program (a single `.exe`, no runtime needed). Needs [Go](https://go.dev/dl/):
```
src/build.sh     # on macOS/Linux: builds src/build/PaxxMaker-Connect.exe + Release/…zip
src\build.cmd    # on Windows: builds src\build\PaxxMaker-Connect.exe
```
The file is not code signed – hence the one-time SmartScreen question.
