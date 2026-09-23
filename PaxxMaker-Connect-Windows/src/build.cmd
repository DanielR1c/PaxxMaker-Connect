@echo off
rem Builds PaxxMaker-Connect.exe on Windows (needs Go: https://go.dev/dl/)
rem and packs the one download file:
rem   ..\Release\PaxxMaker-Connect-Windows-<version>.zip
cd /d "%~dp0"
go run github.com/tc-hib/go-winres@latest make --in winres\winres.json --out rsrc
if errorlevel 1 exit /b 1
go build -ldflags "-H windowsgui -s -w" -o build\PaxxMaker-Connect.exe .
if errorlevel 1 exit /b 1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pack.ps1"
if errorlevel 1 exit /b 1
