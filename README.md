# PaxxMaker-Connect

[![Latest release](https://img.shields.io/github/v/release/DanielR1c/PaxxMaker-Connect?label=Release)](https://github.com/DanielR1c/PaxxMaker-Connect/releases/latest)
[![Platform](https://img.shields.io/badge/Platform-macOS%2013%2B%20%7C%20Windows%2010%2B-blue)](#requirements)
[![Status](https://img.shields.io/badge/Status-Beta-yellow)](#project-status)

PaxxMaker-Connect is a small macOS and Windows helper application that connects the iPhone/iPad app PaxxMaker with a locally installed OrcaSlicer instance.
The model is positioned, rotated, scaled and painted on the mobile device. PaxxMaker-Connect runs OrcaSlicer headlessly in the background and sends the generated G-code back to the app, which can then send it to the printer.
No cloud, no account. Communication stays entirely on the local network. The pairing code is stored only on the computer and on the paired device.
PaxxMaker-Connect does not modify OrcaSlicer. It only reads its profiles and uses OrcaSlicer's command-line interface.
A running Mac or Windows PC with OrcaSlicer installed is required on the same network.

Features

* Local service on port `8765`
* Network discovery via Bonjour/mDNS (`_paxxconnect._tcp`)
* Pairing with a six-character code or QR code
* Pairing code persists across restarts
* Reads printer, process and filament profiles from OrcaSlicer
* Resolves `inherits` chains into complete JSON profiles
* Runs OrcaSlicer headlessly
* Reports staged progress and provides print time, weight, cost, layer count and height
* Reads the effective support settings from the G-code footer
* Takes slice settings from the app as CLI overrides — the quick settings (layer height, walls, infill, supports, brim, skirt, spiral vase, print order, seam) and any other OrcaSlicer setting the app sends
* Applies nozzle and bed temperatures per toolhead as set in the app
* Supports the Snapmaker U1 with one or multiple toolheads
* Automatically removes jobs older than one day

Snapmaker U1 support
For multi-toolhead prints, four filament profiles are supplied in toolhead order. OrcaSlicer handles tool changes and the purge tower. The tower position is provided by the app; if none is set, PaxxMaker-Connect places it in a free corner of the plate.

Requirements

* Installed OrcaSlicer, tested with version `2.4.2`
* The PaxxMaker iOS/iPadOS app
* Computer and iPhone/iPad on the same network
* A supported printer with a suitable network connection

Snapmaker Orca is not used: its command line cannot perform slicing, and OrcaSlicer already ships the Snapmaker profiles.

macOS

* macOS 13 Ventura or newer
* Swift 5.9 / SwiftUI build

Windows

* Windows 10 or Windows 11, 64-bit
* A single executable with no additional runtime, approximately 9 MB

Installation

macOS

1. Open the release DMG: `PaxxMaker-Connect-....dmg`.
2. Drag the app to `Applications` and launch it manually.
3. On the first launch, allow the app under System Settings → Privacy & Security → Open Anyway because the app is not notarized.
4. Allow incoming connections and local network access when macOS asks.

The macOS build runs as a menu bar app with a cube icon. Double-clicking the app opens the pairing window again. Autostart is managed through `SMAppService`.

Windows

1. Extract `PaxxMaker-Connect-....zip` completely. Do not run the app from inside the ZIP.
2. Double-click `PaxxMaker-Connect Install.cmd`.
3. The app is copied to `%LocalAppData%\Programs\PaxxMaker-Connect` and a Start Menu entry is created.
4. Optionally enable the firewall rule and autostart.
5. On the first launch, confirm the SmartScreen prompt with More info → Run anyway because the file is not signed.
6. Allow access for private networks when Windows Firewall asks.

To uninstall, run `PaxxMaker-Connect Deinstall.cmd`.
The Windows build runs in the system tray. Its local pairing page is available at http://127.0.0.1:8765/, showing the code, QR code, Orca status, recent jobs and logs.

Pairing with PaxxMaker

1. In PaxxMaker, open Slicer → Connect via QR code and scan the QR code.
2. Alternatively, choose Connect manually, select the Mac/PC from the network list or enter its IP address.
3. Enter the six-character pairing code.

Project status
Beta. PaxxMaker-Connect is used daily with a Snapmaker U1 and a Creality Ender 3 S1.
The current builds are not signed or notarized, so the one-time Gatekeeper or SmartScreen confirmation is required on first launch.

Contributing
Bug reports and improvements are welcome. Please include the following in an issue:

* Operating system and version
* PaxxMaker-Connect version
* OrcaSlicer version
* Printer model
* Error message shown by the app
* For slicing errors, the `(OrcaSlicer …)` number at the end of the message

PaxxMaker and PaxxMaker-Connect are independent hobby projects and are not affiliated with Snapmaker or the OrcaSlicer project. All mentioned trademarks belong to their respective owners.
