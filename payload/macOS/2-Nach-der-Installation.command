#!/bin/bash
# XT12 Pro - Schritt 2: in macOS 26 Tahoe ausfuehren (Doppelklick im Finder oder: bash /Volumes/XT12DATA/macOS/2-Nach-der-Installation.command)
#
# Das Skript erkennt selbst, wie weit du bist, und macht jeweils den naechsten Schritt. Einfach so oft starten, bis es
# "FERTIG" meldet (normalerweise zweimal, mit einem Neustart dazwischen):
#
#   a) Golden Gate offline vorbereiten: kopiert Apples macOS-27-Image (25,6 GB) und das Kernel Debug Kit von XT12DATA
#      genau dorthin, wo Liberator sie sucht, das Liberator-Kit in deinen Downloads-Ordner und Liberator nach
#      /Programme. Liberator laedt diese grossen Dateien dann NICHT mehr aus dem Internet.
#   b) Iris Xe: schaltet XT12BOOT auf das IRIS-Profil (WhateverXe, SIP 0x803) -> Neustart.
#   c) Nach dem Neustart mit IRIS-Profil: installiert WhateverXe Graphics 0.4.4 (Metal-Beschleunigung) -> Neustart.
#   d) Danach: Liberator oeffnen und "Prepare for Golden Gate" druecken.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
if [ "$(id -u)" != 0 ]; then
  echo "Fuer die Systemschritte wird einmal dein Passwort gebraucht."
  exec /usr/bin/sudo /bin/bash "$0" "$@"
fi

DATA=/Volumes/XT12DATA
LAYWORK="/Library/Application Support/1401/golden-gate/laydown"
IPSW=UniversalMac_27.2_26B123_Restore.ipsw
KDK=Kernel_Debug_Kit_27.2_build_26B123.dmg
KIT=nullmoth-v3-kit-3.0.0-beta.5.tar.gz
APPZIP=Liberator-Mac-0.5.0.zip
GFXPKG=WhateverXe-Graphics-0.4.4.pkg
OC_GUID=4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102

say()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
stop() { printf '\nSTOPP: %s\n' "$*" >&2; exit 1; }
size_of() { stat -f %z "$1" 2>/dev/null || echo 0; }
want()  { awk -v k="$1" '$1==k {print $2}' "$DATA/macOS/manifest.txt" 2>/dev/null; }

[ "$(uname -m)" = x86_64 ] || stop "Dieses Skript ist fuer den XT12 Pro (Intel)."
ver=$(sw_vers -productVersion); major=${ver%%.*}; minor=$(echo "$ver" | cut -d. -f2)
[ "$major" = 26 ] || stop "Hier laeuft macOS $ver. Dieser Schritt ist fuer macOS 26 Tahoe (Golden Gate wird von Tahoe aus vorbereitet)."
[ "${minor:-0}" -ge 7 ] || stop "Tahoe $ver ist zu alt: WhateverXe Graphics braucht 26.7 oder neuer."
[ -d "$DATA" ] || stop "XT12DATA ist nicht eingebunden. Externe Platte anschliessen."
[ -f "$DATA/macOS/manifest.txt" ] || stop "Das Manifest des Windows-Builders fehlt auf XT12DATA."

USER_NAME=${SUDO_USER:-$(stat -f %Su /dev/console)}
[ -n "$USER_NAME" ] && [ "$USER_NAME" != root ] || stop "Bitte als normaler Benutzer per Doppelklick starten (nicht als root)."
USER_HOME=$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[ -d "$USER_HOME" ] || stop "Benutzerordner von $USER_NAME nicht gefunden."

# --- XT12BOOT einbinden ------------------------------------------------------------------------------------------------
BOOTDEV=$(diskutil list | awk '/ XT12BOOT / {print $NF; exit}')
[ -n "$BOOTDEV" ] || stop "Die Partition XT12BOOT wurde nicht gefunden."
diskutil mount "$BOOTDEV" >/dev/null 2>&1
BOOT=$(diskutil info "$BOOTDEV" | awk -F': *' '/Mount Point/ {print $2; exit}')
[ -n "$BOOT" ] && [ -d "$BOOT/EFI" ] || stop "XT12BOOT ($BOOTDEV) liess sich nicht einbinden oder hat keine EFI."

# Von welcher Partition hat OpenCore gestartet? (OpenCore schreibt boot-path ins NVRAM)
bootpath=$(nvram "$OC_GUID:boot-path" 2>/dev/null | cut -f2-)
partuuid=$(diskutil info "$BOOTDEV" | awk -F': *' '/Disk \/ Partition UUID/ {print $2; exit}')
FROM_STICK=unknown
if [ -n "$bootpath" ] && [ -n "$partuuid" ]; then
  if echo "$bootpath" | grep -qi "$partuuid"; then FROM_STICK=yes; else FROM_STICK=no; fi
fi

# --- a) Golden Gate offline vorbereiten ----------------------------------------------------------------------------------
say "Golden Gate (macOS 27.2) offline vorbereiten"
need=0
for f in "$IPSW" "$KDK"; do
  [ "$(size_of "$LAYWORK/$f")" = "$(want "size_$f")" ] || need=$((need + $(want "size_$f")))
done
free_kb=$(df -k / | awk 'NR==2 {print $4}')
if [ "$need" -gt 0 ] && [ $((free_kb * 1024)) -lt $((need + 100 * 1024 * 1024 * 1024)) ]; then
  stop "Auf dem Tahoe-Volume sind nur $((free_kb / 1024 / 1024)) GB frei. Fuer die Kopie ($((need / 1024 / 1024 / 1024)) GB) plus Golden Gate (~100 GB) reicht das nicht."
fi
mkdir -p "$LAYWORK"
for d in "/Library/Application Support/1401" "/Library/Application Support/1401/golden-gate" "$LAYWORK"; do
  chown root:wheel "$d"; chmod 755 "$d"
done
for f in "$IPSW" "$KDK"; do
  src="$DATA/GoldenGate/$f"; dst="$LAYWORK/$f"; w=$(want "size_$f")
  [ "$(size_of "$src")" = "$w" ] || stop "$src fehlt oder ist unvollstaendig ($(size_of "$src") statt $w Bytes)."
  if [ "$(size_of "$dst")" = "$w" ]; then note "schon vorhanden: $f"; continue; fi
  note "kopiere $f ($((w / 1024 / 1024)) MB) ..."
  rm -f "$dst" "$dst.part"
  cp "$src" "$dst.part" || stop "Kopieren von $f fehlgeschlagen."
  [ "$(size_of "$dst.part")" = "$w" ] || stop "$f ist nach dem Kopieren unvollstaendig."
  mv "$dst.part" "$dst"; chown root:wheel "$dst"; chmod 644 "$dst"
done
note "Liberator prueft beide Dateien beim Start noch einmal selbst gegen Apples bzw. Dortanias SHA-256."

dl="$USER_HOME/Downloads"; mkdir -p "$dl"
if [ "$(size_of "$dl/$KIT")" != "$(want "size_$KIT")" ]; then
  cp "$DATA/GoldenGate/$KIT" "$dl/$KIT" || stop "Kit konnte nicht nach Downloads kopiert werden."
fi
chown "$USER_NAME" "$dl/$KIT"; note "Liberator-Kit liegt in $dl"

if [ ! -d /Applications/Liberator.app ] || [ "$(defaults read /Applications/Liberator.app/Contents/Info CFBundleShortVersionString 2>/dev/null)" != 0.5.0 ]; then
  rm -rf /Applications/Liberator.app
  ditto -x -k "$DATA/GoldenGate/$APPZIP" /Applications || stop "Liberator liess sich nicht entpacken."
fi
xattr -dr com.apple.quarantine /Applications/Liberator.app 2>/dev/null
note "Liberator 0.5.0 liegt in /Programme"

# --- b/c) Iris Xe --------------------------------------------------------------------------------------------------------
say "Intel Iris Xe (WhateverXe)"
wex_loaded=no
if kmutil showloaded --list-only 2>/dev/null | grep -q WhateverXe || kextstat 2>/dev/null | grep -q WhateverXe; then wex_loaded=yes; fi
gfx_installed=no
pkgutil --pkgs 2>/dev/null | grep -qi whateverxe && gfx_installed=yes

if [ "$wex_loaded" = no ]; then
  if [ "$FROM_STICK" = no ]; then
    note "Achtung: Dieser Start kam NICHT von XT12BOOT (vermutlich von der Windows-EFI)."
    note "Das Umschalten unten wirkt nur beim Start von der externen Platte."
  fi
  if [ -d "$BOOT/EFI-IRIS-XE" ] && [ ! -d "$BOOT/EFI-BASIS" ]; then
    mv "$BOOT/EFI" "$BOOT/EFI-BASIS" || stop "EFI konnte nicht umbenannt werden."
    if ! mv "$BOOT/EFI-IRIS-XE" "$BOOT/EFI"; then mv "$BOOT/EFI-BASIS" "$BOOT/EFI"; stop "Umschalten fehlgeschlagen, nichts geaendert."; fi
    say "XT12BOOT startet ab jetzt mit dem IRIS-Profil."
    note "JETZT NEU STARTEN (von der externen Platte, Macintosh HD waehlen) und dieses Skript danach noch einmal ausfuehren."
    note "Falls das Bild schwarz bleibt: Windows starten und auf XT12BOOT EFI-PROFIL.cmd ausfuehren (zurueck auf BASIS)."
    exit 0
  fi
  if [ -d "$BOOT/EFI-BASIS" ]; then
    stop "Das IRIS-Profil ist auf XT12BOOT aktiv, aber WhateverXe wurde nicht geladen. Von der externen Platte neu starten. Haelt das an: auf XT12BOOT EFI-PROFIL.cmd (Windows) bzw. EFI-Profil-wechseln.command auf BASIS stellen und einen Bericht schicken."
  fi
  stop "Auf XT12BOOT gibt es kein IRIS-Profil (EFI-IRIS-XE). Den Windows-Builder erneut laufen lassen."
fi

csr=$(nvram csr-active-config 2>/dev/null | cut -f2)
if [ "$gfx_installed" = no ]; then
  say "Installiere WhateverXe Graphics 0.4.4 ..."
  installer -pkg "$DATA/Iris-Xe/$GFXPKG" -target / || stop "WhateverXe Graphics liess sich nicht installieren. Details: /var/log/install.log (SIP: $csr)"
  say "Iris-Xe-Grafik installiert. JETZT NEU STARTEN und das Skript ein letztes Mal ausfuehren."
  exit 0
fi

metal=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': *' '/Metal/ {print $2; exit}')
note "Grafik: $(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': *' '/Chipset Model/ {print $2; exit}'), Metal: ${metal:-nicht erkannt}"

# --- d) Fertig --------------------------------------------------------------------------------------------------------
cat <<EOF

==> FERTIG mit der Vorbereitung.

    Jetzt Golden Gate:
      1. Ethernet-Kabel anschliessen (Liberator holt kleine Pruefdaten/Schluessel von Apple; die grossen
         Dateien liegen schon bereit).
      2. /Programme/Liberator oeffnen (beim ersten Mal: Rechtsklick > Oeffnen).
      3. "Set up as a new Mac instead" leer lassen (Konto wird uebernommen) und "Prepare for Golden Gate" druecken.
      4. Wenn Liberator fertig meldet: neu starten. Beim Text "PCI configuration" bis zu 2 Minuten warten.

    Tahoe bleibt daneben erhalten. Zurueck: im OpenCore-Menue "Macintosh HD" waehlen, Liberator oeffnen,
    "Cancel Golden Gate".
EOF
launchctl asuser "$(id -u "$USER_NAME")" sudo -u "$USER_NAME" open /Applications/Liberator.app 2>/dev/null || true
