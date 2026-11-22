#!/bin/bash
# XT12 Pro - Schritt 1: macOS 26 Tahoe komplett offline installieren (in der macOS-Wiederherstellung ausfuehren).
#
#   Dienstprogramme > Terminal, dann:
#     bash /Volumes/XT12DATA/macOS/1-Tahoe-installieren.sh
#
#   Ohne Angabe nimmt das Skript die Partition "MACOS" auf derselben externen Platte, loescht sie als APFS mit dem
#   Namen "Macintosh HD" und installiert Tahoe dort hinein. Mit einem Namen installiert es auf ein APFS-Volume, das du
#   vorher selbst im Festplattendienstprogramm angelegt hast:
#     bash /Volumes/XT12DATA/macOS/1-Tahoe-installieren.sh "Mein Volume"
#
# Nichts wird aus dem Internet geladen: Apples Vollinstaller liegt auf XT12DATA und wird direkt auf das Ziel entpackt.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
DATA=/Volumes/XT12DATA
PKG="$DATA/Tahoe/InstallAssistant.pkg"
NAME="Macintosh HD"

say()  { printf '\n==> %s\n' "$*"; }
stop() { printf '\nSTOPP: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || stop "Bitte in der macOS-Wiederherstellung ausfuehren (dort ist das Terminal root)."
[ -d "$DATA" ] || stop "$DATA ist nicht eingebunden. Ist die externe Platte angeschlossen? Im Festplattendienstprogramm XT12DATA aktivieren."
[ -f "$PKG" ] || stop "$PKG fehlt. Der Windows-Builder ist nicht bis zum Ende gelaufen."

# 1. Groesse gegen das Manifest des Windows-Builders pruefen (die volle SHA-256-Pruefung lief schon beim Kopieren).
want=$(awk '$1=="tahoe_size" {print $2}' "$DATA/macOS/manifest.txt" 2>/dev/null)
have=$(stat -f %z "$PKG")
[ -z "$want" ] || [ "$want" = "$have" ] || stop "InstallAssistant.pkg hat $have statt $want Bytes. Den Windows-Builder erneut laufen lassen."

# 2. Ziel finden
if [ $# -ge 1 ] && [ -n "$1" ]; then
  NAME=$1
  T="/Volumes/$NAME"
  [ -d "$T" ] || stop "Es gibt kein Volume \"$NAME\". Im Festplattendienstprogramm als APFS anlegen oder ohne Namen starten."
else
  T="/Volumes/$NAME"
  whole=$(diskutil info "$DATA" | awk -F': *' '/Part of Whole/ {print $2; exit}')
  [ -n "$whole" ] || stop "Die Platte von XT12DATA wurde nicht erkannt."
  if [ -d "$T" ]; then
    # Ein frueherer Lauf hat das Volume schon angelegt (z. B. abgebrochene Installation): weiterverwenden.
    say "Verwende das vorhandene Volume \"$NAME\" ($(diskutil info "$T" | awk -F': *' '/Device Node/ {print $2; exit}'))."
  else
    part=$(diskutil list "$whole" | awk '/ MACOS / {print $NF; exit}')
    [ -n "$part" ] || stop "Auf $whole gibt es keine Partition MACOS. Mit einem Volume-Namen starten (siehe oben) oder im Festplattendienstprogramm ein APFS-Volume anlegen."
    echo
    diskutil list "$whole"
    echo
    echo "Die Partition $part (MACOS) auf $whole wird GELOESCHT und als APFS \"$NAME\" neu angelegt."
    echo "XT12BOOT und XT12DATA bleiben unangetastet. Windows (interne Platte) wird nicht beruehrt."
    printf 'Zum Bestaetigen JA eingeben: '
    read -r answer
    [ "$answer" = "JA" ] || stop "Abgebrochen, nichts geaendert."
    say "Lege APFS \"$NAME\" an ..."
    diskutil eraseVolume APFS "$NAME" "$part" || stop "diskutil konnte $part nicht als APFS anlegen."
  fi
fi
[ -d "$T" ] || stop "$T ist nicht eingebunden."

free_kb=$(df -k "$T" | awk 'NR==2 {print $4}')
[ "${free_kb:-0}" -ge $((150 * 1024 * 1024)) ] || \
  echo "Hinweis: $T hat nur $((free_kb / 1024 / 1024)) GB frei. Tahoe braucht ~40 GB, Golden Gate spaeter zusaetzlich ~100 GB im selben Container."

# 3. Installer aufs Ziel entpacken und starten (streamt direkt auf die Platte, nicht in den kleinen RAM der Recovery)
say "Entpacke Apples Tahoe-Installer auf $T (einige Minuten) ..."
/usr/sbin/installer -pkg "$PKG" -target "$T" || stop "Das Installer-Paket liess sich nicht installieren."
APP=$(ls -d "$T"/Applications/Install\ macOS*.app 2>/dev/null | head -1)
[ -n "$APP" ] || stop "Die Installer-App ist auf $T nicht erschienen."

cat <<'EOF'

==> Starte die Installation. Der PC startet dabei mehrmals neu.
    Bei jedem Neustart im OpenCore-Menue waehlen:
      1. "macOS Installer" (solange vorhanden),
      2. danach "Macintosh HD".
    Danach den Mac einrichten und Schritt 2 ausfuehren:
      /Volumes/XT12DATA/macOS/2-Nach-der-Installation.command (Doppelklick im Finder)
EOF
exec "$APP/Contents/Resources/startosinstall" --agreetolicense --volume "$T" --nointeraction
