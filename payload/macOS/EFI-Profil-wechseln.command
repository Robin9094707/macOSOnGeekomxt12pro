#!/bin/bash
# XT12 Pro: OpenCore-Profil auf XT12BOOT umschalten (BASIS <-> IRIS), von macOS aus.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
[ "$(id -u)" = 0 ] || exec /usr/bin/sudo /bin/bash "$0" "$@"
dev=$(diskutil list | awk '/ XT12BOOT / {print $NF; exit}')
[ -n "$dev" ] || { echo "XT12BOOT nicht gefunden."; exit 1; }
diskutil mount "$dev" >/dev/null 2>&1
B=$(diskutil info "$dev" | awk -F': *' '/Mount Point/ {print $2; exit}')
[ -d "$B/EFI" ] || { echo "XT12BOOT hat keine EFI."; exit 1; }
if [ -d "$B/EFI-IRIS-XE" ] && [ ! -d "$B/EFI-BASIS" ]; then mode=IRIS; src=EFI-IRIS-XE; keep=EFI-BASIS
elif [ -d "$B/EFI-BASIS" ] && [ ! -d "$B/EFI-IRIS-XE" ]; then mode=BASIS; src=EFI-BASIS; keep=EFI-IRIS-XE
else echo "Kein eindeutiges zweites Profil auf XT12BOOT."; exit 1; fi
printf 'Zum Umschalten auf %s bitte %s eingeben: ' "$mode" "$mode"; read -r a
[ "$a" = "$mode" ] || { echo "Abgebrochen."; exit 0; }
mv "$B/EFI" "$B/$keep" && { mv "$B/$src" "$B/EFI" || { mv "$B/$keep" "$B/EFI"; echo "Fehlgeschlagen."; exit 1; }; }
echo "Aktives Profil auf XT12BOOT: $mode"
