#!/bin/zsh
# PaxxMaker-Connect deinstallieren / uninstall — Doppelklick genügt / just double-click.
# Quits the app, removes it from the login items and from /Applications, and
# asks whether the pairing code and working files should go too.
set -u
NAME="PaxxMaker-Connect"
DATA="$HOME/Library/Application Support/$NAME"

DE=0; case "${PAXX_LANG:-$(defaults read -g AppleLocale 2>/dev/null)}" in de*) DE=1;; esac
t()     { if [ "$DE" = 1 ]; then printf "%s" "$1"; else printf "%s" "$2"; fi }
bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
ok()    { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn()  { printf "  \033[33m!\033[0m %s\n" "$*"; }
ask()   { local a; printf "  %s [%s] " "$1" "$(t "j/N" "y/N")"; read -r a; [[ "$a" == [jJyY]* ]]; }

[ -t 1 ] && clear
bold "$(t "PaxxMaker-Connect deinstallieren" "Uninstall PaxxMaker-Connect")"
echo
found=0
for APP in "/Applications/$NAME.app" "$HOME/Applications/$NAME.app"; do
  [ -d "$APP" ] || continue
  found=1
  # The app removes itself from the login items and quits.
  pkill -x PaxxMakerConnect 2>/dev/null; sleep 1
  open -a "$APP" --args --uninstall 2>/dev/null; sleep 2
  pkill -x PaxxMakerConnect 2>/dev/null
  if /usr/libexec/ApplicationFirewall/socketfilterfw --listapps 2>/dev/null | grep -q "$APP"; then
    if ask "$(t "Firewall-Eintrag entfernen? (Admin-Passwort nötig, sonst bleibt ein verwaister Eintrag)" "Remove the firewall entry? (admin password needed, otherwise a stale entry remains)")"; then
      sudo /usr/libexec/ApplicationFirewall/socketfilterfw --remove "$APP" >/dev/null && ok "$(t "Firewall-Eintrag entfernt" "Firewall entry removed")"
    fi
  fi
  rm -rf "$APP" && ok "$(t "Gelöscht:" "Deleted:") $APP"
done
if [ "$found" = 0 ]; then
  pkill -x PaxxMakerConnect 2>/dev/null && ok "$(t "Laufende App beendet" "Running app quit")"
  warn "$(t "Keine installierte App in /Programme gefunden." "No installed app found in /Applications.")"
fi
if [ -d "$DATA" ]; then
  echo
  if ask "$(t "Auch Kopplungscode und Arbeitsdateien löschen" "Also delete the pairing code and working files") ($DATA)?"; then
    rm -rf "$DATA"; defaults delete com.paxxmaker.connect >/dev/null 2>&1
    ok "$(t "Daten gelöscht — beim nächsten Installieren muss das iPhone neu gekoppelt werden" "Data deleted — the iPhone has to be paired again after the next install")"
  else
    ok "$(t "Daten behalten — eine Neuinstallation läuft mit demselben Kopplungscode weiter" "Data kept — a reinstall continues with the same pairing code")"
  fi
fi
echo
bold "$(t "Fertig." "Done.")"
echo "$(t "Dieses Fenster kann geschlossen werden." "This window can be closed.")"
