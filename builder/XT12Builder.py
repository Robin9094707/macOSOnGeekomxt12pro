"""GEEKOM XT12 Pro: macOS 26 Tahoe + macOS 27 Golden Gate, komplett unter Windows vorbereitet.

Runs with the embedded Python of 1401 (nullmoth/1401 v3.0), whose engine builds the OpenCore EFI for this exact PC.
Started by START.cmd -> builder/Start.ps1, which passes the cache folder as the first argument.

What ends up on the external disk (everything verified by SHA-256 and read back after writing):
  XT12BOOT  OpenCore (BASIS + IRIS profile), Tahoe recovery (offline start), BIOS guide
  XT12DATA  Apple's full Tahoe installer, macOS 27.2 image + KDK + Liberator kit/app, WhateverXe Graphics, scripts
  MACOS     (big disks) the partition macOS 26 and macOS 27 are installed to
"""
import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
PAYLOAD = REPO / "payload"
sys.path.insert(0, str(HERE))

import AppleInstaller  # noqa: E402
import Efi  # noqa: E402
import Fetch  # noqa: E402
import Pins  # noqa: E402

VERSION = "2.0 (22.11.2026)"
GIB = 1024 ** 3
MIB = 1024 ** 2
RECOVERY_DIR = "com.apple.recovery.boot"
MACOS_MIN_GIB = 150           # Tahoe (~40 GB) + Golden Gate (Liberator wants ~92-102 GB free in the same container)
DATA_MARGIN_GIB = 4


# --- small helpers ------------------------------------------------------------------------------------------------------
def title(text):
    print("\n" + "=" * 78 + f"\n  {text}\n" + "=" * 78, flush=True)


def step(text):
    print(f"\n--> {text}", flush=True)


def ask(prompt):
    try:
        return input(prompt).strip()
    except EOFError:
        return ""


def powershell(script, *args, parse=True):
    exe = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    process = subprocess.run(
        [str(exe), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(HERE / script), *map(str, args)],
        text=True, encoding="utf-8", errors="replace", stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if process.returncode:
        raise RuntimeError(f"{script} {args[1] if len(args) > 1 else ''}: {(process.stderr or process.stdout).strip()[-1500:]}")
    if not parse:
        return None
    text = process.stdout.strip()
    data = json.loads(text) if text else None
    if isinstance(data, dict):
        return data
    return data if isinstance(data, list) else ([] if data is None else [data])


def run_engine(*args):
    """1401's engine as a module of the embedded Python (cwd = engine\\app, set by Start.ps1)."""
    subprocess.run([sys.executable, "-E", "-s", "-B", "-X", "utf8", "-u", "-m", *map(str, args)], check=True)


def normalise_text(source, destination):
    """Shell scripts must reach macOS with LF line ends, whatever git or an editor did on Windows."""
    data = Path(source).read_bytes()
    if Path(source).suffix in {".sh", ".command"}:
        data = data.replace(b"\r\n", b"\n")
    elif Path(source).suffix in {".cmd", ".txt", ".ps1"}:
        data = data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
    Path(destination).parent.mkdir(parents=True, exist_ok=True)
    Path(destination).write_bytes(data)


# --- hardware --------------------------------------------------------------------------------------------------------
def device_ids(report, section):
    ids = []
    for props in (report.get(section) or {}).values():
        if isinstance(props, dict) and props.get("Device ID"):
            ids.append(str(props["Device ID"]).upper())
    return ids


def check_hardware(report_path):
    report = json.loads(Path(report_path).read_text(encoding="utf-8-sig"))
    cpu = str((report.get("CPU") or {}).get("Processor Name", "unbekannt"))
    gpus = device_ids(report, "GPU")
    nets = device_ids(report, "Network")
    bts = device_ids(report, "Bluetooth")
    board = report.get("Motherboard") or {}
    igpu = [g for g in gpus if g.startswith("8086-") and g[5:] in Pins.ALDER_LAKE_IGPU]
    print(f"  Prozessor : {cpu}")
    print(f"  Board     : {board.get('Name', '?')} ({board.get('Chipset', '?')})")
    print(f"  Grafik    : {', '.join(gpus) or 'keine erkannt'}" + ("  -> Iris Xe (Alder Lake), WhateverXe-faehig" if igpu else ""))
    print(f"  Netzwerk  : {', '.join(nets) or 'keine erkannt'}")
    print(f"  Bluetooth : {', '.join(bts) or 'keine erkannt'}")
    mediatek = any(n.startswith("14C3-") for n in nets)
    if mediatek:
        print("  Hinweis   : MediaTek-WLAN erkannt. Unter Tahoe experimentell (AirportMtkWlan), ohne AirDrop;")
        print("              unter macOS 27 gibt es noch KEIN WLAN/Bluetooth (Liberator Beta 5). Ethernet benutzen.")
    if not igpu:
        print("\n  ACHTUNG: Keine Alder-Lake-Iris-Xe gefunden. Dieser Builder ist fuer den GEEKOM XT12 Pro gemacht.")
        if ask("  Trotzdem fortfahren? WEITER eingeben: ").upper() != "WEITER":
            raise SystemExit(1)
    return {"cpu": cpu, "gpus": gpus, "nets": nets, "bts": bts, "mediatek": mediatek}


# --- EFI ---------------------------------------------------------------------------------------------------------------
def build_efis(work, cache):
    from p1401 import validate  # noqa: PLC0415
    scan, output = work / "Scan", work / "Build"
    step("Scanne Hardware und ACPI-Tabellen dieses PCs (1401 / Hardware Sniffer)")
    run_engine("p1401.scan", scan)
    facts = check_hardware(scan / "Report.json")

    step("Baue die OpenCore-EFI fuer macOS 26 Tahoe (1401-Engine, mit MediaTek-WLAN/BT experimentell)")
    run_engine("p1401", "build", scan / "Report.json", scan / "ACPI", output,
               "--macos", str(Pins.TAHOE_DARWIN), "--external-target", "--experimental-drivers")
    original = Efi.inspect_efi(output)
    guide = work / "XT12Pro-BIOS.html"
    run_engine("p1401.guide", scan / "Report.json", original / "OC/config.plist", "--macos", str(Pins.TAHOE_DARWIN), "--html", guide)

    base = work / "BASIS" / "EFI"
    shutil.copytree(original, base)
    Efi.apply_profile_nvram(base)
    Efi.write_marker(base.parent)
    checked = validate.validate(str(base.parent))
    if not checked.get("ok"):
        raise RuntimeError(f"OpenCore-Pruefung (ocvalidate) der BASIS-EFI fehlgeschlagen: "
                           f"{checked.get('error') or checked.get('invariants') or checked.get('ocvalidate')}")
    print("  BASIS-EFI geprueft (ocvalidate + Dateipruefung).")
    kexts = Efi.enabled_kexts(base)
    print("  Kexts: " + ", ".join(kexts))

    step("Baue das IRIS-Profil (Lilu 1.7.2, AMFIAnchor 0.1.2, WhateverXe 0.8.3, SIP 0x803)")
    iris_cache = cache / "Iris-Xe"
    files = {key: Fetch.pinned(pin, iris_cache) for key, pin in
             zip(("lilu", "wex", "anchor", "injector"), Pins.IRIS_FILES)}
    iris = Efi.prepare_iris(base, work / "IRIS" / "EFI", files)
    Efi.write_marker(iris.parent)
    checked = validate.validate(str(iris.parent))
    if not checked.get("ok"):
        raise RuntimeError(f"OpenCore-Pruefung der IRIS-EFI fehlgeschlagen: "
                           f"{checked.get('error') or checked.get('invariants') or checked.get('ocvalidate')}")
    print("  IRIS-EFI geprueft.")
    return {"base": base, "iris": iris, "guide": guide, "facts": facts, "kexts": kexts}


# --- downloads -----------------------------------------------------------------------------------------------------------
def tahoe_product(fullinstaller):
    step("Frage Apples Katalog nach dem neuesten macOS 26 Tahoe (Vollinstaller)")
    product = AppleInstaller.choose_tahoe(fullinstaller, Pins.TAHOE_CATALOG_MAJOR, Pins.TAHOE_MIN)
    print(f"  macOS Tahoe {product['version']} ({product['build']}), {int(product['size']) / GIB:.1f} GiB")
    return product


def recovery_into(cache, apple):
    """Tahoe's recovery (BaseSystem) into the cache, checked chunk by chunk against Apple's signed chunklist."""
    folder = cache / "Recovery-Tahoe"
    rec = folder / RECOVERY_DIR
    if rec.is_dir() and len(list(rec.glob("*.dmg"))) == 1 and len(list(rec.glob("*.chunklist"))) == 1 \
            and (folder / "ok").is_file():
        print("  Vorhanden und geprueft: Tahoe-Recovery")
        return rec
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    info = apple.image_info(Pins.TAHOE_DARWIN)
    apple.preflight(info)
    apple.download(info, str(folder), progress=Fetch.progress_printer("Tahoe-Recovery"))
    print()
    if len(list(rec.glob("*.dmg"))) != 1 or len(list(rec.glob("*.chunklist"))) != 1:
        raise RuntimeError("Die gepruefte Tahoe-Recovery ist unvollstaendig.")
    (folder / "ok").write_text("ok\n", encoding="ascii")
    return rec


def ensure_pinned(pin, cache_dir, target_dir):
    """Puts a verified copy of pin into target_dir: from the cache when it is there, else downloaded straight to it."""
    cached = Path(cache_dir) / pin["name"]
    if target_dir is None:
        return Fetch.pinned(pin, cache_dir)
    target = Path(target_dir) / pin["name"]
    if Fetch.is_verified(target, pin):
        print(f"  Schon auf der Platte und geprueft: {pin['what']}")
        return target
    if cached.is_file() and Fetch.is_verified(cached, pin):
        return Fetch.copy_verified(cached, target, pin["sha256"], pin["name"])
    return Fetch.pinned(pin, target_dir)


def ensure_tahoe(fullinstaller, product, cache, target_dir):
    cache_folder = cache / ("Tahoe-" + product["build"])
    cached = cache_folder / fullinstaller.PACKAGE_NAME
    stamp = cache_folder / (fullinstaller.PACKAGE_NAME + ".ok")
    if target_dir is None:
        return AppleInstaller.fetch_tahoe(fullinstaller, product, cache_folder)
    if cached.is_file() and stamp.is_file() and len(stamp.read_text(encoding="ascii").split()) == 3:
        path, digest = AppleInstaller.fetch_tahoe(fullinstaller, product, cache_folder)
        return Fetch.copy_verified(path, Path(target_dir) / fullinstaller.PACKAGE_NAME, digest, "InstallAssistant.pkg"), digest
    return AppleInstaller.fetch_tahoe(fullinstaller, product, target_dir)


def need_free(directory, needed, what):
    free = shutil.disk_usage(directory).free
    if free < needed:
        raise RuntimeError(f"{what}: {free / GIB:.1f} GiB frei in {directory}, {needed / GIB:.1f} GiB noetig.")


# --- the disk ------------------------------------------------------------------------------------------------------------
def data_bytes(product):
    return int(product["size"]) + Pins.golden_gate_bytes() + Pins.WHATEVERXE_GRAPHICS["size"] + DATA_MARGIN_GIB * GIB


def choose_disk(product):
    disks = powershell("Disk.ps1", "-Action", "List")
    minimum = 2 * GIB + data_bytes(product) + GIB
    usable = [d for d in disks if int(d["bytes"]) >= minimum]
    print("\nAngeschlossene USB-Laufwerke (interne Platten und die Windows-Platte werden nie angezeigt):")
    if not disks:
        print("  keine")
    for d in disks:
        size = int(d["bytes"])
        flags = []
        if size < minimum:
            flags.append(f"zu klein, mind. {minimum / 10 ** 9:.0f} GB")
        elif size - 2 * GIB - data_bytes(product) >= MACOS_MIN_GIB * GIB:
            flags.append("gross genug fuer Installer UND macOS darauf")
        else:
            flags.append("nur Installer, macOS dann auf eine andere Platte")
        if d.get("builder"):
            flags.append("enthaelt schon einen XT12-Aufbau")
        print(f"  {d['number']:>3} - {d['name']}, {size / 10 ** 9:.0f} GB, {d['letters'] or 'ohne Buchstaben'}  [{'; '.join(flags)}]")
    if not usable:
        raise RuntimeError(f"Keine passende USB-Platte. Noetig sind mindestens {minimum / 10 ** 9:.0f} GB; "
                           f"empfohlen ist eine SSD ab 256 GB, dann passt macOS selbst mit darauf.")
    choice = ask("\nNummer der Platte, die vorbereitet werden soll (Enter = Abbruch): ")
    disk = next((d for d in usable if str(d["number"]) == choice), None)
    if not choice:
        return None
    if disk is None:
        raise RuntimeError("Diese Nummer steht nicht in der Liste der geeigneten Platten.")
    return disk


def prepare_disk(disk, product):
    """Returns ({'boot': 'X', 'data': 'Y', 'macos': bool}, erased)."""
    if disk.get("builder"):
        answer = ask("\nDiese Platte enthaelt schon einen XT12-Aufbau.\n"
                     "  F = fortsetzen/aktualisieren (nichts loeschen, vorhandene Downloads weiterverwenden)\n"
                     "  N = komplett neu (alles loeschen)\nAuswahl [F/N]: ").upper()
        if answer == "F":
            return powershell("Disk.ps1", "-Action", "Find", "-ExpectedToken", disk["token"]), False
        if answer != "N":
            return None, False
    size = int(disk["bytes"])
    data_mb = data_bytes(product) // MIB
    with_macos = size - 2 * GIB - data_bytes(product) >= MACOS_MIN_GIB * GIB
    if with_macos:
        rest = (size - 2 * GIB - data_bytes(product)) / 10 ** 9
        if ask(f"\nmacOS (Tahoe + Golden Gate) mit auf diese Platte installieren? Dafuer bleiben ~{rest:.0f} GB "
               f"als Partition MACOS. [J/n]: ").lower().startswith("n"):
            with_macos = False
    print(f"\nAufteilung: XT12BOOT 2 GB (FAT32/EFI) | XT12DATA {data_mb / 1024:.0f} GB (exFAT)"
          + (" | MACOS Rest (wird in der Recovery zu APFS)" if with_macos else " | (ohne MACOS: Rest von XT12DATA)"))
    command = f"LOESCHEN {disk['number']}"
    print(f"\nACHTUNG: Die komplette Platte {disk['number']} ({disk['name']}, {size / 10 ** 9:.0f} GB) wird geloescht.")
    if ask(f"Zum Bestaetigen {command} eingeben: ").upper() != command:
        print("Abgebrochen. Platte nicht veraendert.")
        return None, False
    args = ["-Action", "Prepare", "-Number", disk["number"], "-ExpectedToken", disk["token"], "-DataMB", data_mb]
    if with_macos:
        args.append("-WithMacos")
    return powershell("Disk.ps1", *args), True


def check_letters(disk, drives):
    powershell("Disk.ps1", "-Action", "Check", "-ExpectedToken", disk["token"],
               "-Letters", f"{drives['boot']},{drives['data']}", parse=False)


def write_boot(boot, efis, recovery, verify_efi_copy):
    for name in ("EFI", "EFI-BASIS", "EFI-IRIS-XE", RECOVERY_DIR):
        if (boot / name).exists():
            shutil.rmtree(boot / name)
    with tempfile.TemporaryDirectory(prefix="xt12-", dir=boot) as tmp:
        staged = Path(tmp)
        shutil.copytree(recovery, staged / RECOVERY_DIR)
        shutil.copytree(efis["iris"], staged / "EFI-IRIS-XE")
        shutil.copytree(efis["base"], staged / "EFI")
        (staged / RECOVERY_DIR).rename(boot / RECOVERY_DIR)
        (staged / "EFI-IRIS-XE").rename(boot / "EFI-IRIS-XE")
        (staged / "EFI").rename(boot / "EFI")      # last: a half-written disk never shows a bootable EFI
    verify_efi_copy(str(efis["base"]), str(boot / "EFI"))
    verify_efi_copy(str(efis["iris"]), str(boot / "EFI-IRIS-XE"))
    for src, dst in zip(sorted(recovery.iterdir()), sorted((boot / RECOVERY_DIR).iterdir())):
        if Fetch.sha256_file(src) != Fetch.sha256_file(dst):
            raise RuntimeError(f"Die Recovery-Datei {dst.name} liest sich auf XT12BOOT falsch zurueck.")
    Efi.write_marker(boot)
    shutil.copy2(efis["guide"], boot / "XT12Pro-BIOS.html")
    normalise_text(PAYLOAD / "XT12BOOT-LIESMICH.txt", boot / "LIESMICH.txt")


def write_payload(data):
    for src in sorted(PAYLOAD.rglob("*")):
        if src.is_file() and src.name != "XT12BOOT-LIESMICH.txt":
            normalise_text(src, data / src.relative_to(PAYLOAD))
    (data / "Backups").mkdir(exist_ok=True)


def write_manifest(data, product, tahoe_sha, efis, drives):
    lines = [
        f"builder_version {VERSION.split()[0]}",
        f"created {datetime.datetime.now().isoformat(timespec='seconds')}",
        f"tahoe_version {product['version']}",
        f"tahoe_build {product['build']}",
        f"tahoe_size {product['size']}",
        f"tahoe_sha256 {tahoe_sha}",
        f"golden_gate {Pins.GOLDEN_GATE_VERSION} {Pins.GOLDEN_GATE_BUILD}",
    ]
    for pin in Pins.GOLDEN_GATE_FILES + (Pins.WHATEVERXE_GRAPHICS,):
        lines += [f"size_{pin['name']} {pin['size']}", f"sha256_{pin['name']} {pin['sha256']}"]
    lines.append("kexts " + ",".join(efis["kexts"]))
    lines.append(f"macos_partition {'yes' if drives.get('macos') else 'no'}")
    (data / "macOS").mkdir(exist_ok=True)
    (data / "macOS" / "manifest.txt").write_text("\n".join(lines) + "\n", encoding="ascii", newline="\n")


def full_disk(cache, offer_esp=True):
    from p1401 import apple, fullinstaller  # noqa: PLC0415
    from p1401.usbwriter import verify_efi_copy  # noqa: PLC0415
    title("Externe Platte komplett vorbereiten: Tahoe-Installer + Golden Gate offline")
    with tempfile.TemporaryDirectory(prefix="XT12-Build-", dir=cache) as folder:
        work = Path(folder)
        efis = build_efis(work, cache)
        product = tahoe_product(fullinstaller)
        step("Pruefe, dass Apple die Tahoe-Recovery ausliefert (bevor irgendetwas geloescht wird)")
        recovery = recovery_into(cache, apple)

        disk = choose_disk(product)
        if disk is None:
            return
        drives, _ = prepare_disk(disk, product)
        if not drives:
            return
        boot, data = Path(drives["boot"] + ":/"), Path(drives["data"] + ":/")
        check_letters(disk, drives)

        step("Schreibe XT12BOOT: OpenCore BASIS + IRIS, Tahoe-Recovery, BIOS-Anleitung")
        write_boot(boot, efis, recovery, verify_efi_copy)
        write_payload(data)

        step("Lade/kopiere Apples macOS 26 Tahoe Vollinstaller nach XT12DATA\\Tahoe (danach keine Online-Recovery noetig)")
        check_letters(disk, drives)
        _, tahoe_sha = ensure_tahoe(fullinstaller, product, cache, data / "Tahoe")

        step("Lade/kopiere macOS 27.2 Golden Gate, Kernel Debug Kit und Liberator nach XT12DATA\\GoldenGate")
        for pin in Pins.GOLDEN_GATE_FILES:
            check_letters(disk, drives)
            ensure_pinned(pin, cache / "GoldenGate", data / "GoldenGate")

        step("Lade/kopiere WhateverXe Graphics nach XT12DATA\\Iris-Xe")
        ensure_pinned(Pins.WHATEVERXE_GRAPHICS, cache / "Iris-Xe", data / "Iris-Xe")

        check_letters(disk, drives)
        write_manifest(data, product, tahoe_sha, efis, drives)
        summary(drives, product, efis)
        if offer_esp and ask("\nOpenCore jetzt zusaetzlich auf die interne Windows-EFI installieren? [j/N]: ").lower().startswith("j"):
            install_esp(efis, data / "Backups")


def summary(drives, product, efis):
    title("FERTIG - die externe Platte ist ein komplettes Offline-Installationsmedium")
    print(f"""  XT12BOOT ({drives['boot']}:)  OpenCore (Profil BASIS aktiv, IRIS vorbereitet), Tahoe-Recovery
  XT12DATA ({drives['data']}:)  Tahoe {product['version']} Vollinstaller, macOS 27.2 + KDK + Liberator, Iris-Xe-Paket
  {'MACOS             wird in der Recovery automatisch zu APFS "Macintosh HD"' if drives.get('macos') else ''}

  So geht es weiter (steht auch in XT12DATA\\LIESMICH.txt):
  1. XT12Pro-BIOS.html auf XT12BOOT lesen (Secure Boot aus, VT-d aus o. ae.).
  2. Neustart, F7 (GEEKOM-Bootmenue) -> die externe Platte waehlen ("UEFI: ...").
  3. Im OpenCore-Menue die Tahoe-Recovery starten, Dienstprogramme > Terminal:
       bash /Volumes/XT12DATA/macOS/1-Tahoe-installieren.sh
  4. In Tahoe: XT12DATA/macOS/2-Nach-der-Installation.command (2x, mit Neustart dazwischen).
  5. Liberator: "Prepare for Golden Gate" -> macOS 27 Golden Gate.""")


# --- Windows ESP ---------------------------------------------------------------------------------------------------------
def install_esp(efis, backup_dir):
    title("OpenCore auf die interne Windows-EFI-Partition")
    info = powershell("WinEsp.ps1", "-Action", "Inspect")
    print(f"  Windows-EFI: {info['size'] / MIB:.0f} MB, frei {info['free'] / MIB:.0f} MB, "
          f"OpenCore vorhanden: {'ja' if info['has_opencore'] else 'nein'} ({info['opencore_mb']} MB), "
          f"Firmware-Eintrag fuer OpenCore: {'ja' if info['oc_entry'] else 'nein'}")
    if info["has_opencore"]:
        print("  Das vorhandene OpenCore wird ersetzt (vorher komplett gesichert). Windows-Dateien bleiben unberuehrt.")
    profile = ask("  Welches Profil? B = BASIS (sicher, fuer die Installation), I = IRIS (nach installiertem "
                  "WhateverXe Graphics) [B/i]: ").upper() or "B"
    source = efis["iris"] if profile == "I" else efis["base"]
    if ask("  Zum Installieren ESP eingeben: ").upper() != "ESP":
        print("  Abgebrochen, nichts geaendert.")
        return
    Path(backup_dir).mkdir(parents=True, exist_ok=True)
    local_backup = Path(os.environ.get("LOCALAPPDATA", tempfile.gettempdir())) / "RJ-XT12Pro-GoldenGate" / "Backups"
    local_backup.mkdir(parents=True, exist_ok=True)
    result = powershell("WinEsp.ps1", "-Action", "Install", "-Source", source, "-BackupDir", local_backup,
                        *([] if info["oc_entry"] else ["-AddBootEntry"]))
    try:
        shutil.copytree(result["backup"], Path(backup_dir) / Path(result["backup"]).name)
    except OSError:
        pass
    print(f"  OK. Sicherung der alten EFI: {result['backup']}")
    if result.get("entry"):
        print(f"  Neuer Firmware-Booteintrag 'OpenCore (XT12 Pro)': {result['entry']} (im F7-Bootmenue waehlbar)")
    print("  Hinweis: Fuer Golden Gate (Liberator) am besten von der externen Platte starten; Liberator baut dann")
    print("  die macOS-27-Startdateien dort. Die 200-MB-Windows-EFI kann dafuer zu knapp sein.")


def esp_only(cache):
    with tempfile.TemporaryDirectory(prefix="XT12-Build-", dir=cache) as folder:
        efis = build_efis(Path(folder), cache)
        install_esp(efis, cache / "Backups")


def downloads_only(cache):
    from p1401 import apple, fullinstaller  # noqa: PLC0415
    title("Nur herunterladen (Cache unter Windows, die Platte wird nicht beruehrt)")
    product = tahoe_product(fullinstaller)
    need = data_bytes(product)
    need_free(cache, need, "Cache-Laufwerk (oder Option 1 nehmen: dann gehen die Dateien direkt auf die Platte)")
    recovery_into(cache, apple)
    ensure_tahoe(fullinstaller, product, cache, None)
    for pin in Pins.GOLDEN_GATE_FILES:
        ensure_pinned(pin, cache / "GoldenGate", None)
    ensure_pinned(Pins.WHATEVERXE_GRAPHICS, cache / "Iris-Xe", None)
    for pin in Pins.IRIS_FILES:
        ensure_pinned(pin, cache / "Iris-Xe", None)
    print(f"\nAlles geprueft im Cache: {cache}")


def check_only(cache):
    with tempfile.TemporaryDirectory(prefix="XT12-Scan-", dir=cache) as folder:
        build_efis(Path(folder), cache)
    print("\nHardware-Pruefung und EFI-Bau erfolgreich. Es wurde nichts auf eine Platte geschrieben.")


def main(cache):
    title(f"GEEKOM XT12 Pro  ->  macOS 26 Tahoe  ->  macOS 27 Golden Gate      Builder {VERSION}")
    print("""  1  Externe Platte komplett vorbereiten (empfohlen): OpenCore + Tahoe-Vollinstaller + Golden Gate offline
  2  Nur alles herunterladen und pruefen (Cache unter Windows, keine Platte)
  3  OpenCore auf die interne Windows-EFI installieren/ersetzen (optional, mit Sicherung)
  4  Nur Hardware pruefen und EFI testweise bauen (aendert nichts)""")
    choice = ask("Auswahl [1-4], Enter = Abbruch: ")
    actions = {"1": full_disk, "2": downloads_only, "3": esp_only, "4": check_only}
    if choice in actions:
        actions[choice](cache)


if __name__ == "__main__":
    try:
        main(Path(sys.argv[1]).resolve(strict=True))
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError, Fetch.FetchError) as error:
        print(f"\nABBRUCH: {error}", file=sys.stderr)
        print("Ein erneuter Start setzt fertige Downloads fort; die Platte wird nur nach Bestaetigung geloescht.", file=sys.stderr)
        sys.exit(1)
