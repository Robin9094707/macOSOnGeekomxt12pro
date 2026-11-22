# GEEKOM XT12 Pro → macOS 26 Tahoe → macOS 27 Golden Gate

Ein Windows-Builder, der auf dem GEEKOM XT12 Pro (Intel Alder Lake, Iris Xe `8086:46A6`, MediaTek MT7922)
eine **externe Platte zu einem kompletten Offline-Installationsmedium** macht: OpenCore für genau diesen PC,
Apples vollständiger Tahoe-Installer, Apples macOS-27.2-Image samt allem, was [Liberator](https://github.com/nullmoth/liberator)
für Golden Gate auf Intel braucht, und die Iris-Xe-Treiber. Nach dem Schreiben wird nichts Großes mehr aus dem Internet geladen,
auch nicht über die Online-Recovery.

Stand: 22. November 2026 · Builder 2.0

> [!WARNING]
> macOS 27 läuft offiziell nicht auf Intel. Golden Gate auf einem PC ist eine **Community-Beta** (Liberator Beta 5):
> SIP/AMFI gelockert, kein WLAN/Bluetooth unter macOS 27, Iris-Xe-Grafik unter macOS 27 auf echter Hardware kaum erprobt.
> Nur als Testsystem verwenden. Windows auf der internen Platte wird vom Builder nie verändert
> (außer du wählst ausdrücklich Option 3, und dann nur der OpenCore-Ordner auf der EFI-Partition, mit Sicherung).

## Download & Start

1. Diesen Branch als ZIP laden: **Code → Download ZIP** (oder
   [direkt](../../archive/refs/heads/claude/gifted-lovelace-n8ymin.zip)) und unter Windows entpacken.
2. Externe USB-Platte anschließen (**ab 256 GB empfohlen**, dann wird macOS gleich mit darauf installiert;
   ab 64 GB nur als Installer).
3. `START.cmd` doppelklicken, Administratorabfrage bestätigen, **Option 1** wählen.

Der Builder:

| Schritt | Was passiert |
|---|---|
| Hardware | scannt CPU, Iris Xe, WLAN/BT und die ACPI-Tabellen (1401 / Hardware Sniffer) |
| OpenCore | baut die EFI für macOS 26 mit der [1401-Engine](https://github.com/nullmoth/1401) v3.0 (OpCore-Simplify + Regeln), inkl. experimentellem MediaTek-WLAN (AirportMtkWlan) und -BT; prüft mit `ocvalidate` |
| Profile | **BASIS** (Installation, sicherer Start) und **IRIS** (Lilu 1.7.2, AMFIAnchor 0.1.2, WhateverXe 0.8.3, SIP 0x803) |
| Prüfung vorab | fragt Apple nach Tahoe-Recovery und Vollinstaller, *bevor* die Platte gelöscht wird |
| Platte | GPT: `XT12BOOT` (2 GB EFI/FAT32), `XT12DATA` (exFAT), `MACOS` (Rest, wird später APFS) |
| Downloads | Tahoe 26.7.x Vollinstaller (Apples SHA-256-Blockliste), macOS 27.2 26B123 IPSW (25,6 GB), KDK 27.2, Liberator 0.5.0 + Kit Beta 5, WhateverXe Graphics 0.4.4 – alles mit fester SHA-256, fortsetzbar, nach dem Schreiben zurückgelesen |
| Optional | OpenCore auf die interne Windows-EFI (ersetzt ein vorhandenes OpenCore, Sicherung vorher, Firmware-Booteintrag) |

Abgebrochen? Einfach neu starten: fertige Downloads werden weiterverwendet, eine vorhandene XT12-Platte kann
mit **F** (fortsetzen) aktualisiert werden, ohne gelöscht zu werden.

## Auf dem XT12 Pro

Die genaue Anleitung liegt danach auf der Platte (`XT12DATA\LIESMICH.txt`). Kurz:

1. BIOS nach `XT12BOOT\XT12Pro-BIOS.html` einstellen, Ethernet + HDMI anschließen.
2. F7 → externe Platte → im OpenCore-Menü die **Tahoe-Recovery** → Terminal:
   ```sh
   bash /Volumes/XT12DATA/macOS/1-Tahoe-installieren.sh
   ```
   Löscht nach Rückfrage nur die Partition `MACOS`, legt APFS „Macintosh HD“ an und installiert Tahoe **offline**.
3. In Tahoe `XT12DATA/macOS/2-Nach-der-Installation.command` ausführen (mehrmals, mit Neustarts): legt das
   Golden-Gate-Image, das KDK und das Kit genau dorthin, wo Liberator sie sucht
   (`/Library/Application Support/1401/golden-gate/laydown`, `~/Downloads`), schaltet auf das IRIS-Profil,
   installiert WhateverXe Graphics (Metal auf der Iris Xe) und öffnet Liberator.
4. Liberator → **Prepare for Golden Gate** → Neustart → macOS 27 Golden Gate. Tahoe bleibt daneben erhalten.

## Warum nicht „direkt Golden Gate ohne Tahoe“?

Das wurde geprüft – es geht (Stand heute) nicht, auch nicht mit [hao-patcher](https://github.com/lythka/hao-patcher):

- macOS 27 enthält **keine Intel-Kernel-Erweiterungen, keinen Intel-Installer und keine Intel-Recovery**. Die
  Startdateien (Kernel-Collections) müssen mit Apples `kmutil` aus Tahoe-Treibern + dem 27er-KDK gebaut, das
  Image mit `aea`/`hdiutil`/APFS-Werkzeugen ausgepackt und in eine APFS-Volume-Gruppe gelegt werden. Diese Werkzeuge
  gibt es nur unter macOS, nicht unter Windows.
- hao-patcher baut ein Image für genau ein Gerät (MacBook Pro 2012, HD 4000) und braucht einen Mac als Builder.
- Liberator (NullMoth, von denselben Leuten wie 1401) macht genau diesen Schritt auf dem PC selbst, von macOS 15 oder 26
  aus – und übernimmt dabei die Grafiktreiber, die unter Tahoe laufen („wenn Tahoe die iGPU beschleunigt, nimmt
  Golden Gate diesen Treiber mit“). Deshalb ist **Tahoe mit WhateverXe der notwendige Zwischenschritt**.

Der Builder macht deshalb alles, was unter Windows möglich ist, und legt den Rest so bereit, dass auf dem Mini-PC
nichts Großes mehr heruntergeladen wird.

## Ehrliche Erwartungen

| | Tahoe 26.7 | Golden Gate 27.2 (Liberator Beta 5) |
|---|---|---|
| Iris Xe 46A6 mit Metal | ja (WhateverXe, auf Alder Lake-H getestet) | „apple“-Pfad: Treiber aus Tahoe mitgenommen, auf echter Iris-Xe-Hardware kaum erprobt |
| Ethernet | ja | ja |
| MediaTek MT7922 WLAN | experimentell (AirportMtkWlan 1.5.0) | **nein** (Liberator: noch kein WLAN/BT) |
| MediaTek Bluetooth | experimentell (SimpleMtkBtFw) | **nein** |
| AirDrop / Continuity | **nein** mit MediaTek (kein awdl-Treiber) | **nein** |
| Audio ALC269 | layout-abhängig, früher ohne Ausgang getestet | wie Tahoe |

**AirDrop:** geht nur mit einer Broadcom-Karte (z. B. Fenvi/BCM94360NG, M.2 2230 E-Key) statt der MediaTek-Karte –
unter Tahoe mit OCLP-Root-Patch. Unter macOS 27 gibt es derzeit gar kein WLAN.

## Aufbau

```
START.cmd                     Doppelklick unter Windows
builder/Start.ps1             Admin-Rechte, lädt die 1401-Engine (SHA-256-gepinnt), startet den Builder
builder/XT12Builder.py        Ablauf, Menü, Plattenbelegung
builder/Pins.py               alle Downloads mit Größe + SHA-256
builder/Fetch.py              fortsetzbare, geprüfte Downloads und Kopien mit Rücklesen
builder/AppleInstaller.py     Tahoe-Vollinstaller gegen Apples Blockliste
builder/Efi.py                OpenCore-Prüfung, BASIS-/IRIS-Profil
builder/Disk.ps1              USB-Platten auflisten/aufteilen/prüfen (nur USB, nie die Windows-Platte)
builder/WinEsp.ps1            optional: OpenCore auf die Windows-EFI
payload/                      landet auf XT12DATA (Mac-Skripte, Profilumschalter, Anleitung)
tests/                        Tests (python3 -m unittest discover -s tests)
```

## Quellen

- 1401 (Windows-OpenCore-Builder): https://github.com/nullmoth/1401
- Liberator (macOS 27 auf PCs): https://github.com/nullmoth/liberator · https://nullmothsystems.com/downloads
- hao-patcher (macOS 27 auf Intel-Macs, Hintergrund): https://github.com/lythka/hao-patcher
- WhateverXe / WhateverXe Graphics / AMFIAnchor: https://github.com/b00t0x
- WhateverGate (Xe-Metal unter Golden Gate, Testphase): https://github.com/randomdev31/WhateverGate
- Kernel Debug Kits: https://github.com/dortania/KdkSupportPkg
- OpenCore Install Guide (Handarbeit, falls etwas klemmt): https://dortania.github.io/OpenCore-Install-Guide/
