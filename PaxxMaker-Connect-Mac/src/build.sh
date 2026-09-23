#!/bin/zsh
# Builds PaxxMaker-Connect.app and packs the one download file:
#   ../Release/PaxxMaker-Connect-<version>.dmg   (App + Programme-Link)
#   ./build.sh            → build + sign with whatever identity is available
#   ./build.sh notarize   → additionally notarize + staple (needs a Developer ID
#                           certificate and a notarytool keychain profile "paxx-notary")
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP="build/PaxxMaker-Connect.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/PaxxMakerConnect" "$APP/Contents/MacOS/PaxxMakerConnect"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi
ID=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/')
[ -z "$ID" ] && ID=$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/')
echo "Signiere mit: ${ID:-ad-hoc}"
codesign --force --options runtime --timestamp --sign "${ID:--}" --entitlements Resources/entitlements.plist "$APP"
codesign --verify --deep --strict "$APP" && echo "Signatur ok"
if [ "$1" = "notarize" ]; then
  rm -f build/notary.zip
  ditto -c -k --keepParent "$APP" build/notary.zip
  xcrun notarytool submit build/notary.zip --keychain-profile paxx-notary --wait
  xcrun stapler staple "$APP"
fi

# The download: the app and the Applications link, nothing else — the
# classic Mac way. The .command scripts stay in the project folder.
STAGE="build/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$ROOT/Release"
DMG="$ROOT/Release/PaxxMaker-Connect-$VER.dmg"
rm -f "$DMG"
hdiutil create -volname "PaxxMaker-Connect $VER" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
echo "Fertig: src/$APP"
echo "Download: Release/$(basename "$DMG")"
