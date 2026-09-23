#!/bin/zsh
# PaxxMaker-Connect installieren / install — Doppelklick genügt / just double-click.
#
# Takes the app next to this file (DMG) or from the project folder
# (src/build, Release); otherwise builds it from source or downloads the
# latest GitHub release. Copies it to /Applications, clears the Gatekeeper quarantine,
# checks OrcaSlicer and starts the app with the pairing window.
set -u
DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || pwd)"
NAME="PaxxMaker-Connect"
TARGET="/Applications/$NAME.app"
TMP="$(mktemp -d /tmp/paxx-install.XXXXXX)"
MOUNT=""
trap '[ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null; rm -rf "$TMP"' EXIT

# German on a German Mac, English everywhere else.
DE=0; case "${PAXX_LANG:-$(defaults read -g AppleLocale 2>/dev/null)}" in de*) DE=1;; esac
t()     { if [ "$DE" = 1 ]; then printf "%s" "$1"; else printf "%s" "$2"; fi }
bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
ok()    { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn()  { printf "  \033[33m!\033[0m %s\n" "$*"; }
fail()  { printf "\n  \033[31m✗ %s\033[0m\n\n" "$*"; printf "%s\n" "$(t "Dieses Fenster kann geschlossen werden." "This window can be closed.")"; exit 1; }
ask()   { local a; printf "  %s [%s] " "$1" "$(t "j/N" "y/N")"; read -r a; [[ "$a" == [jJyY]* ]]; }

[ -t 1 ] && clear
bold "$(t "PaxxMaker-Connect installieren" "Install PaxxMaker-Connect")"
echo

# macOS 13 or newer
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] 2>/dev/null || fail "$(t "PaxxMaker-Connect braucht macOS 13 (Ventura) oder neuer." "PaxxMaker-Connect needs macOS 13 (Ventura) or newer.")"

# 1) Find the app
SRC=""
if [ -d "$DIR/$NAME.app" ]; then
  SRC="$DIR/$NAME.app"
elif [ -d "$DIR/src/build/$NAME.app" ]; then
  SRC="$DIR/src/build/$NAME.app"
else
  DMG=$(ls -t "$DIR"/Release/$NAME-*.dmg 2>/dev/null | head -1)
  if [ -z "$DMG" ] && [ -f "$DIR/src/Package.swift" ] && xcode-select -p >/dev/null 2>&1; then
    echo "  $(t "Hier liegt der Quellcode. Die App wird jetzt gebaut (Xcode-Werkzeuge, etwa eine Minute)…" "This is the source code. Building the app now (Xcode tools, about a minute)…")"
    ( cd "$DIR/src" && ./build.sh ) >"$TMP/build.log" 2>&1 || { tail -20 "$TMP/build.log"; fail "$(t "Bauen fehlgeschlagen — siehe Meldungen oben." "Build failed — see the messages above.")"; }
    SRC="$DIR/src/build/$NAME.app"
  elif [ -z "$DMG" ]; then
    # No source/Xcode: fetch the latest release (repo from git, else PAXX_REPO).
    REPO="${PAXX_REPO:-$(git -C "$DIR" remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##')}"
    [ -n "$REPO" ] || fail "$(t "Keine App gefunden. Bitte das DMG von der Releases-Seite laden und darin diese Datei starten." "No app found. Please download the DMG from the Releases page and run this file from there.")"
    echo "  $(t "Lade das neueste Release von" "Downloading the latest release from") github.com/$REPO …"
    URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | sed -E 's/.*"(https[^"]*)"/\1/')
    [ -n "$URL" ] || fail "$(t "Kein Release-DMG gefunden. Bitte das DMG von der Releases-Seite laden." "No release DMG found. Please download the DMG from the Releases page.")"
    curl -fSL --progress-bar "$URL" -o "$TMP/release.dmg" || fail "$(t "Download fehlgeschlagen." "Download failed.")"
    DMG="$TMP/release.dmg"
  fi
  if [ -z "$SRC" ]; then
    MOUNT="$TMP/dmg"; mkdir -p "$MOUNT"
    hdiutil attach "$DMG" -nobrowse -readonly -quiet -mountpoint "$MOUNT" || fail "$(t "DMG lässt sich nicht öffnen:" "Cannot open DMG:") $DMG"
    SRC="$MOUNT/$NAME.app"
    [ -d "$SRC" ] || fail "$(t "Im DMG fehlt" "The DMG is missing") $NAME.app."
  fi
fi
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SRC/Contents/Info.plist" 2>/dev/null || echo "?")
ok "$(t "App gefunden: Version" "Found the app: version") $VER"

# 2) Quit the running copy, copy, clear quarantine
if pgrep -xq PaxxMakerConnect; then
  pkill -x PaxxMakerConnect; sleep 1
  ok "$(t "Laufende Version beendet" "Running copy quit")"
fi
if [ ! -w /Applications ]; then
  TARGET="$HOME/Applications/$NAME.app"; mkdir -p "$HOME/Applications"
  warn "$(t "Kein Schreibrecht auf /Programme — installiere in ~/Programme" "No write access to /Applications — installing to ~/Applications")"
fi
rm -rf "$TARGET"
ditto "$SRC" "$TARGET" || fail "$(t "Kopieren nach" "Copying to") $TARGET $(t "fehlgeschlagen." "failed.")"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
ok "$(t "Installiert nach" "Installed to") $TARGET"

# 3) OrcaSlicer
if [ -d /Applications/OrcaSlicer.app ] || [ -d "$HOME/Applications/OrcaSlicer.app" ]; then
  ok "$(t "OrcaSlicer gefunden" "OrcaSlicer found")"
else
  warn "$(t "OrcaSlicer fehlt — ohne ihn kann nichts gesliced werden (Snapmaker Orca allein reicht nicht)." "OrcaSlicer is missing — nothing can be sliced without it (Snapmaker Orca alone is not enough).")"
  if ask "$(t "Download-Seite von OrcaSlicer öffnen?" "Open the OrcaSlicer download page?")"; then open "https://github.com/OrcaSlicer/OrcaSlicer/releases"; fi
fi

# 4) Login item + start
echo
LOGIN="off"
if ask "$(t "Soll PaxxMaker-Connect beim Anmelden automatisch starten?" "Start PaxxMaker-Connect automatically at login?")"; then LOGIN="on"; fi
open -a "$TARGET" --args --login-item "$LOGIN" --show-window
echo
bold "$(t "Fertig." "Done.")"
if [ "$DE" = 1 ]; then cat <<TXT
  PaxxMaker-Connect läuft jetzt (Würfel oben in der Menüleiste) und zeigt
  ein Fenster mit dem Kopplungscode.
  • Fragt macOS nach „eingehenden Verbindungen“ oder „lokalem Netzwerk“: Erlauben.
  • Auf dem iPhone/iPad: PaxxMaker › Slicer › „Per QR-Code verbinden“ und den
    QR-Code im Fenster scannen — oder „Manuell verbinden“ und den Code eintippen.

Dieses Fenster kann geschlossen werden.
TXT
else cat <<TXT
  PaxxMaker-Connect is running now (cube icon in the menu bar) and shows
  a window with the pairing code.
  • If macOS asks about "incoming connections" or "local network": Allow.
  • On the iPhone/iPad: PaxxMaker › Slicer › "Connect with QR code" and scan
    the code in the window — or "Connect manually" and type the code.

This window can be closed.
TXT
fi
