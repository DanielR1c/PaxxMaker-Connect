# PaxxMaker-Connect installieren / install (Windows)
# Started by "PaxxMaker-Connect Install.cmd" – copies the app to the user's
# Programs folder, adds Start menu entry, firewall rule (optional, UAC) and
# autostart (optional), checks OrcaSlicer and launches the pairing page.
param([string]$Root)   # Ordner, aus dem die .cmd gestartet wurde
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$de = ((Get-UICulture).Name -like 'de*')
if ($env:PAXX_LANG) { $de = ($env:PAXX_LANG -like 'de*') }
function T($d, $e) { if ($de) { $d } else { $e } }
function OK($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host ""; Write-Host "  [X] $m" -ForegroundColor Red; Write-Host ""; Read-Host (T "Enter drücken zum Schließen" "Press Enter to close") | Out-Null; exit 1 }
function Ask($q)  { $a = Read-Host ("  $q [" + (T "j/N" "y/N") + "]"); return ($a -match '^[jJyY]') }

$name   = 'PaxxMaker-Connect'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
# A caller passing "%~dp0" hands us a trailing backslash that swallows the
# closing quote, so a stray " can end up in the path.
$root   = $Root.Trim('"').TrimEnd('\')
$target = Join-Path $env:LOCALAPPDATA "Programs\$name"
$exe    = Join-Path $target "$name.exe"

Write-Host ""
Write-Host (T "PaxxMaker-Connect installieren" "Install PaxxMaker-Connect") -ForegroundColor Cyan
Write-Host ""

# 1) Find the exe: next to the scripts (ZIP download) or in dist\ (source folder).
# Neben den Skripten (ZIP-Download) oder im Projekt gebaut (src\build).
$src = @((Join-Path $root "$name.exe"), (Join-Path $root "src\build\$name.exe")) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $src) { Fail (T "PaxxMaker-Connect.exe nicht gefunden. Bitte das ZIP von der Releases-Seite laden, entpacken und diese Datei daraus starten." "PaxxMaker-Connect.exe not found. Please download the ZIP from the Releases page, unpack it and run this file from there.") }
$ver = (Get-Item $src).VersionInfo.ProductVersion
OK ((T "App gefunden: Version" "Found the app: version") + " $ver")

# 2) Quit a running copy, copy, clear the download mark.
$running = Get-Process -Name $name -ErrorAction SilentlyContinue
if ($running) { $running | Stop-Process -Force; Start-Sleep -Seconds 1; OK (T "Laufende Version beendet" "Running copy quit") }
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item -Path $src -Destination $exe -Force
try { Unblock-File -Path $exe } catch {}
OK ((T "Installiert nach" "Installed to") + " $target")

# 3) Start menu shortcut.
$ws = New-Object -ComObject WScript.Shell
$startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$lnk = $ws.CreateShortcut((Join-Path $startMenu "$name.lnk"))
$lnk.TargetPath = $exe; $lnk.Arguments = '--show-window'; $lnk.WorkingDirectory = $target; $lnk.IconLocation = "$exe,0"
$lnk.Description = T "PaxxMaker-Connect – Kopplung anzeigen" "PaxxMaker-Connect – show pairing"
$lnk.Save()
OK (T "Startmenü-Eintrag angelegt" "Start menu entry created")

# 4) Firewall rule (needs admin – Windows would otherwise ask at the first start).
if (Ask (T "Firewall-Regel für das Heimnetz anlegen? (Windows fragt nach Admin-Rechten; ohne Regel fragt die Firewall beim ersten Start)" "Add a firewall rule for the private network? (Windows asks for admin rights; without it the firewall asks at first start)")) {
    $rule = "netsh advfirewall firewall delete rule name=`"$name`" >nul 2>&1 & netsh advfirewall firewall add rule name=`"$name`" dir=in action=allow program=`"$exe`" enable=yes profile=private,domain"
    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $rule" -Verb RunAs -Wait -WindowStyle Hidden
        OK (T "Firewall-Regel angelegt" "Firewall rule added")
    } catch { Warn (T "Firewall-Regel übersprungen – die Firewall fragt dann beim ersten Start; dort „Zugriff zulassen“ wählen." "Firewall rule skipped – the firewall will ask at first start; choose “Allow access” there.") }
}

# 5) OrcaSlicer.
$orca = @("$env:ProgramFiles\OrcaSlicer\orca-slicer-console.exe", "$env:ProgramFiles\OrcaSlicer\orca-slicer.exe",
          "$env:LOCALAPPDATA\Programs\OrcaSlicer\orca-slicer-console.exe", "$env:LOCALAPPDATA\Programs\OrcaSlicer\orca-slicer.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($orca) {
    OK (T "OrcaSlicer gefunden" "OrcaSlicer found")
    # Installed is not enough: the profiles only exist once OrcaSlicer has run
    # its setup wizard and written its own data folder.
    if (Test-Path (Join-Path $env:APPDATA "OrcaSlicer\OrcaSlicer.conf")) {
        OK (T "Orca-Profile vorhanden" "Orca profiles present")
    } else {
        Warn (T "OrcaSlicer wurde noch nie gestartet – es gibt noch keine Druckprofile. Bitte OrcaSlicer einmal öffnen und den Einrichtungs-Assistenten mit dem eigenen Drucker durchlaufen, sonst meldet PaxxMaker-Connect „Keine Orca-Profile gefunden“." `
               "OrcaSlicer has never been started – there are no print profiles yet. Please open OrcaSlicer once and walk through its setup wizard with your printer, otherwise PaxxMaker-Connect reports 'No Orca profiles found'.")
    }
}
else {
    Warn (T "OrcaSlicer fehlt – ohne ihn kann nichts gesliced werden (Snapmaker Orca allein reicht nicht)." "OrcaSlicer is missing – nothing can be sliced without it (Snapmaker Orca alone is not enough).")
    if (Ask (T "Download-Seite von OrcaSlicer öffnen?" "Open the OrcaSlicer download page?")) { Start-Process 'https://github.com/OrcaSlicer/OrcaSlicer/releases' }
}

# 6) Autostart + start.
Write-Host ""
$login = 'off'
if (Ask (T "Soll PaxxMaker-Connect beim Anmelden automatisch starten?" "Start PaxxMaker-Connect automatically at login?")) { $login = 'on' }

# Smart App Control refuses unsigned programs outright – there is no "run
# anyway". Say what happened instead of dying with a raw PowerShell error.
try {
    Start-Process -FilePath $exe -ArgumentList "--login-item $login --show-window" -WorkingDirectory $target -ErrorAction Stop
} catch {
    $sac = $false
    try { $sac = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop).VerifiedAndReputablePolicyState -eq 1) } catch {}
    Write-Host ""
    if ($sac) {
        Fail (T @"
Windows hat den Start blockiert: „Smart App Control“ ist eingeschaltet.
      Diese Funktion lässt nur signierte Programme zu und bietet bewusst kein
      „Trotzdem ausführen“. Kopiert ist bereits alles, der Startmenü-Eintrag
      bleibt bestehen – nur starten lässt sich das Programm so nicht.
      Nachsehen unter: Windows-Sicherheit › App- und Browsersteuerung ›
      Smart App Control. Achtung: Ausschalten lässt sich nicht rückgängig machen.
"@ @"
Windows blocked the start: Smart App Control is switched on.
      It only allows signed programs and deliberately offers no "run anyway".
      Everything is copied already and the Start menu entry stays – the program
      just cannot be launched like this.
      Look under: Windows Security > App & browser control > Smart App Control.
      Note: switching it off cannot be undone.
"@)
    }
    Fail ((T "Start fehlgeschlagen: " "Could not start: ") + $_.Exception.Message)
}

Write-Host ""
Write-Host (T "Fertig." "Done.") -ForegroundColor Cyan
if ($de) {
@"
  PaxxMaker-Connect läuft jetzt und öffnet im Browser die Seite mit dem
  Kopplungscode. Die Seite kann geschlossen werden – das Programm läuft als
  Symbol im Infobereich der Taskleiste weiter (rechts unten, ggf. hinter dem
  Pfeil).
  • Fragt die Windows-Firewall nach dem Zugriff: „Zugriff zulassen“ (privates Netz).
  • Auf dem iPhone/iPad: PaxxMaker › Slicer › „Per QR-Code verbinden“ und den
    QR-Code auf der Seite scannen – oder „Manuell verbinden“ und den Code eintippen.
"@ | Write-Host
} else {
@"
  PaxxMaker-Connect is running now and opens the page with the pairing code in
  your browser. You can close the page – the program keeps running as an icon
  in the taskbar's notification area (bottom right, maybe behind the arrow).
  • If the Windows firewall asks: "Allow access" (private network).
  • On the iPhone/iPad: PaxxMaker › Slicer › "Connect with QR code" and scan the
    code on the page – or "Connect manually" and type the code.
"@ | Write-Host
}
Write-Host ""
Read-Host (T "Enter drücken zum Schließen" "Press Enter to close") | Out-Null
