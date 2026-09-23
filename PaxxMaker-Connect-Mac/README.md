# PaxxMaker-Connect for Mac

The link between the **PaxxMaker** app (iPhone/iPad) and the **OrcaSlicer installed on your
Mac**: place, rotate, scale and paint the model on the phone — PaxxMaker-Connect has
OrcaSlicer slice it in the background and sends the G-code back, and the app passes it
straight to the printer. OrcaSlicer itself is left untouched; everything stays on your own
Wi-Fi — no cloud, no account, no telemetry.

A Windows version lives in its own repository.

## Installation

**Requirements:** macOS 13 (Ventura) or newer ·
[OrcaSlicer](https://github.com/OrcaSlicer/OrcaSlicer/releases) in the Applications folder ·
Mac and iPhone on the same Wi-Fi.

1. **Download:** get the latest `PaxxMaker-Connect-x.y.dmg` from the releases page and open it.
2. **Install:** drag `PaxxMaker-Connect` onto `Applications`, then start it from the
   Applications folder.
   On first launch macOS says the developer cannot be verified — the app is signed but not
   notarized: *System Settings › Privacy & Security* → **"Open Anyway"** at the bottom.
   Needed only once.
   Answer the prompts about *incoming connections* and *local network* with **Allow**,
   otherwise the iPhone cannot reach the Mac.
3. **Pair:** a window opens with the **pairing code and QR code**. In PaxxMaker go to
   *Slicer › Connect with QR code* and scan it — or *Connect manually*, pick the Mac from the
   network list and type the 6-character code. Done.

The app deliberately has no Dock icon: it sits as a cube in the menu bar (on a narrow screen
it may hide behind the clock or the notch). Started by hand it always shows the pairing
window, and double-clicking the app brings that window back at any time; only the automatic
start after logging in stays quiet. Start at login is a switch in the app's menu.

**Remove:** drag the app from the Applications folder to the trash. The working files live in
`~/Library/Application Support/PaxxMaker-Connect`.

The project folder also holds `PaxxMaker-Connect Install.command` and `… Deinstall.command`.
They do the same by double-click — including the Gatekeeper release, an OrcaSlicer check and
the start-at-login question — and build the app from source when no finished one is around.

## What it does

- Service on port 8765, Bonjour `_paxxconnect._tcp`, pairing by a 6-character code
- Reads printer, process and filament profiles from OrcaSlicer (and Snapmaker Orca, if
  installed) and resolves their `inherits` chains into complete JSON — the same choices you
  see in the program itself
- Writes the plate from the app as 3MF with transforms, head per object, per-object settings
  and painted faces (Orca's `paint_color`), runs OrcaSlicer headless and reads the result off
  the G-code: print time, grams (total and per head), cost, layer count, height and the
  support settings that were actually used
- Snapmaker U1: one head → `T0` is rewritten to the chosen head; several heads → four filament
  profiles in head order, and OrcaSlicer does the tool changes and the prime tower
- OrcaSlicer errors reach the app as plain sentences instead of exit numbers
- Speaks German on a German Mac, English otherwise

All working files live in `~/Library/Application Support/PaxxMaker-Connect` (pairing code,
recent jobs — they clean themselves up after a day).

## Folders

```
PaxxMaker-Connect Install.command     ← double-click: install (instead of dragging)
PaxxMaker-Connect Deinstall.command   ← double-click: remove
README.md
src/        source, resources and build.sh
Release/    the finished DMG (created by the build)
```

## Building it yourself

Xcode (or the Command Line Tools) is all you need — a Swift package with no dependencies.

```
src/build.sh            # → src/build/PaxxMaker-Connect.app and Release/PaxxMaker-Connect-<version>.dmg
src/build.sh notarize   # additionally notarize (Developer ID certificate + notarytool profile "paxx-notary")
```

Without notarization users have to allow the app once via "Open Anyway" (step 2 above).
For a release without that step: create a **Developer ID Application** certificate in your
Apple Developer account, run
`xcrun notarytool store-credentials paxx-notary --apple-id <Apple ID> --team-id <Team ID>`
once (app-specific password from appleid.apple.com), then `src/build.sh notarize` and attach
the DMG from `Release/` to a GitHub release.

## Status

Beta — in daily use with a Snapmaker U1 and a Creality Ender 3 S1. Feedback and bug reports
are welcome as an issue; please include your macOS version, the OrcaSlicer version, the
printer and, for slicing errors, the message from the app including its `Orca Exit` number.

PaxxMaker and PaxxMaker-Connect are an independent hobby project and are not affiliated with
Snapmaker or the OrcaSlicer project. Trademarks belong to their owners.
