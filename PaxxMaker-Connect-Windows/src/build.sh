#!/bin/zsh
# Cross-builds PaxxMaker-Connect.exe from macOS/Linux (needs Go: brew install go)
# and packs the one download file:
#   ../Release/PaxxMaker-Connect-Windows-<version>.zip
#   (exe + Install/Deinstall + scripts + Installation.txt)
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
VER=$(sed -nE 's/.*"FileVersion": "([^"]+)".*/\1/p' winres/winres.json | head -1)

go run github.com/tc-hib/go-winres@latest make --in winres/winres.json --out rsrc
GOOS=windows GOARCH=amd64 go build -ldflags "-H windowsgui -s -w" -o build/PaxxMaker-Connect.exe .

STAGE="build/zip/PaxxMaker-Connect"
rm -rf build/zip; mkdir -p "$STAGE/scripts"
cp build/PaxxMaker-Connect.exe Installation.txt "$STAGE/"
cp "$ROOT/PaxxMaker-Connect Install.cmd" "$ROOT/PaxxMaker-Connect Deinstall.cmd" "$STAGE/"
cp scripts/install.ps1 scripts/uninstall.ps1 "$STAGE/scripts/"
mkdir -p "$ROOT/Release"
ZIP="$ROOT/Release/PaxxMaker-Connect-Windows-$VER.zip"
rm -f "$ZIP"
( cd build/zip && zip -qr "$ZIP" PaxxMaker-Connect )
rm -rf build/zip
echo "Fertig: src/build/PaxxMaker-Connect.exe"
echo "Download: Release/$(basename "$ZIP")"
