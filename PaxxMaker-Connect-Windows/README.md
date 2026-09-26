# PaxxMaker-Connect for Windows

The Windows edition of PaxxMaker-Connect: the link between the PaxxMaker app
(iPhone/iPad) and OrcaSlicer on your PC. Models are placed and painted on the
phone, PaxxMaker-Connect lets the **installed** OrcaSlicer slice in the background
and sends the G-code back. Same interface as the Mac version (port 8765, Bonjour,
pairing by code), everything on your own network – no cloud.

## Installation

**Requirements:** Windows 10/11 (64-bit) · [OrcaSlicer](https://github.com/OrcaSlicer/OrcaSlicer/releases)
installed · PC and iPhone on the same network.

1. **Download:** get the latest `PaxxMaker-Connect-Windows-x.y.zip` from the Releases
   page and extract it completely. Do not run the app from inside the ZIP.
2. **Install:** double-click **`PaxxMaker-Connect Install.cmd`**.
   The script copies the app to `%LocalAppData%\Programs\PaxxMaker-Connect`, adds a
   Start menu entry, asks about a firewall rule and autostart, checks for OrcaSlicer
   and launches the app.
   If Windows shows "Windows protected your PC" (SmartScreen): **"More info" ›
   "Run anyway"** – needed only once. If the firewall asks: **"Allow access"** (private network).
3. **Pair:** your browser opens the page with the **pairing code and QR code**. In
   PaxxMaker go to *Slicer › Connect with QR code* and scan it – or *Connect manually*
   and type the 6-character code. Done.

Please install with `PaxxMaker-Connect Install.cmd` – do not start the `.exe` directly.

The app then runs as an icon in the taskbar's notification area (bottom right, maybe
behind the arrow): click › *Show pairing…* brings the page back, where autostart and
quit can be toggled too.

**Uninstall:** double-click `PaxxMaker-Connect Deinstall.cmd`. Deleting the `.exe`
alone is not enough.

## What it does
- Service on port 8765, Bonjour `_paxxconnect._tcp` (built in, no Apple Bonjour needed)
- Reads printer/process/filament profiles from `%AppData%\OrcaSlicer` and resolves
  `inherits` chains
- Writes the plate from the app as 3MF (transforms, head per object, per-object
  settings, painted faces), runs `orca-slicer-console.exe` headless and reads the
  result off the G-code
- U1: one head → `T0` is rewritten to the chosen head; several heads → four filament
  profiles in head order, Orca does the tool changes and the prime tower

Working files: `%AppData%\PaxxMaker-Connect` (pairing code, recent jobs – they clean
themselves up after a day). Installed to `%LocalAppData%\Programs\PaxxMaker-Connect`
– no admin rights needed.

## Folders
```
PaxxMaker-Connect Install.cmd     ← double-click: install
PaxxMaker-Connect Deinstall.cmd   ← double-click: remove
README.md
src/        Go source, installer scripts, build.sh / build.cmd
Release/    the finished ZIP (created by the build)
```

## Building it yourself
A Go program (a single `.exe`, no runtime needed). Needs [Go](https://go.dev/dl/):
```
src/build.sh     # on macOS/Linux: builds src/build/PaxxMaker-Connect.exe + Release/…zip
src\build.cmd    # on Windows: builds src\build\PaxxMaker-Connect.exe
```
The file is not code signed – hence the one-time SmartScreen question.
