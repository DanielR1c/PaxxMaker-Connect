# PaxxMaker-Connect deinstallieren / uninstall (Windows)
param([string]$Root)   # von der .cmd übergeben, hier nicht weiter genutzt
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$de = ((Get-UICulture).Name -like 'de*')
if ($env:PAXX_LANG) { $de = ($env:PAXX_LANG -like 'de*') }
function T($d, $e) { if ($de) { $d } else { $e } }
function OK($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Ask($q)  { $a = Read-Host ("  $q [" + (T "j/N" "y/N") + "]"); return ($a -match '^[jJyY]') }

$name   = 'PaxxMaker-Connect'
$target = Join-Path $env:LOCALAPPDATA "Programs\$name"
$exe    = Join-Path $target "$name.exe"
$data   = Join-Path $env:APPDATA $name

Write-Host ""
Write-Host (T "PaxxMaker-Connect deinstallieren" "Uninstall PaxxMaker-Connect") -ForegroundColor Cyan
Write-Host ""
$running = Get-Process -Name $name -ErrorAction SilentlyContinue
if ($running) { $running | Stop-Process -Force; Start-Sleep -Seconds 1; OK (T "Laufende App beendet" "Running app quit") }
if (Test-Path $exe) {
    # The app removes its own autostart entry.
    try { Start-Process -FilePath $exe -ArgumentList '--uninstall' -Wait -WindowStyle Hidden } catch {}
    if (Ask (T "Firewall-Regel entfernen? (Admin-Rechte nötig)" "Remove the firewall rule? (admin rights needed)")) {
        try { Start-Process -FilePath 'cmd.exe' -ArgumentList "/c netsh advfirewall firewall delete rule name=`"$name`"" -Verb RunAs -Wait -WindowStyle Hidden; OK (T "Firewall-Regel entfernt" "Firewall rule removed") } catch { Warn (T "Firewall-Regel übersprungen" "Firewall rule skipped") }
    }
    Remove-Item -Recurse -Force $target
    OK ((T "Gelöscht:" "Deleted:") + " $target")
} else { Warn (T "Keine installierte App gefunden." "No installed app found.") }
# Shortcuts and the Run entry (in case the app could not remove it).
Remove-Item -Force (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$name.lnk") -ErrorAction SilentlyContinue
Remove-Item -Force (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\$name.lnk") -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $name -ErrorAction SilentlyContinue
if (Test-Path $data) {
    Write-Host ""
    if (Ask ((T "Auch Kopplungscode und Arbeitsdateien löschen" "Also delete the pairing code and working files") + " ($data)?")) {
        Remove-Item -Recurse -Force $data
        OK (T "Daten gelöscht – beim nächsten Installieren muss das iPhone neu gekoppelt werden" "Data deleted – the iPhone has to be paired again after the next install")
    } else { OK (T "Daten behalten – eine Neuinstallation läuft mit demselben Kopplungscode weiter" "Data kept – a reinstall continues with the same pairing code") }
}
Write-Host ""
Write-Host (T "Fertig." "Done.") -ForegroundColor Cyan
Read-Host (T "Enter drücken zum Schließen" "Press Enter to close") | Out-Null
