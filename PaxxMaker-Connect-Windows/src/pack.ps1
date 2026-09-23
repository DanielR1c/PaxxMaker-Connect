# Packs the one download file, same layout as build.sh produces on the Mac:
#   ..\Release\PaxxMaker-Connect-Windows-<version>.zip
#     PaxxMaker-Connect\  exe + Installation.txt + Install/Deinstall + scripts\
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$root = Split-Path -Parent $PSScriptRoot

$ver = (Get-Content winres\winres.json -Raw | ConvertFrom-Json).RT_VERSION.'#1'.'0000'.info.'0409'.FileVersion
if (-not $ver) { throw "Version nicht aus winres.json lesbar" }

$stage = "build\zip\PaxxMaker-Connect"
if (Test-Path build\zip) { Remove-Item build\zip -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$stage\scripts" | Out-Null

Copy-Item build\PaxxMaker-Connect.exe, Installation.txt $stage
Copy-Item "$root\PaxxMaker-Connect Install.cmd", "$root\PaxxMaker-Connect Deinstall.cmd" $stage
Copy-Item scripts\install.ps1, scripts\uninstall.ps1 "$stage\scripts"

New-Item -ItemType Directory -Force -Path "$root\Release" | Out-Null
$zip = "$root\Release\PaxxMaker-Connect-Windows-$ver.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "build\zip\PaxxMaker-Connect" -DestinationPath $zip
Remove-Item build\zip -Recurse -Force

Write-Host "Fertig: src\build\PaxxMaker-Connect.exe"
Write-Host "Download: Release\$(Split-Path $zip -Leaf)"
