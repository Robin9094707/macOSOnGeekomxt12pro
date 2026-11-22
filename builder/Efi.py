"""OpenCore checks and the two OpenCore profiles of the XT12 Pro.

BASIS  1401's EFI for macOS 26 Tahoe, unchanged apart from the profile NVRAM switch: boots the installer and the first
       desktop on the firmware framebuffer. Safe fallback.
IRIS   the same EFI plus Lilu 1.7.2, AMFIAnchor + injector and WhateverXe 0.8.3 for the Iris Xe (Alder Lake 46A6), SIP
       0x803 as WhateverXe requires. With WhateverXe Graphics 0.4.4 installed in Tahoe it gives Metal acceleration,
       and Liberator carries exactly that driver over to macOS 27 ("apple" graphics path).
"""
import plistlib
import re
import shutil
import zipfile
from pathlib import Path, PurePosixPath

NVRAM_APPLE = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
IGPU = "PciRoot(0x0)/Pci(0x2,0x0)"
IRIS_KEXTS = ("Lilu.kext", "AMFIAnchor.kext", "AMFIAnchorInjector.kext", "WhateverXe.kext")
CONFLICTS = {"whatevergreen.kext", "amfipass.kext"}
IRIS_ARGS = ("-allow3d", "-disablegfxfirmware", "-igfxdvmt")
DROP_ARGS = {"-igfxvesa", "-wegnoigpu", "-amfipassbeta", "amfi=0x80", "ipc_control_port_options=0", "-radvesa"}
TAHOE_MIN_KERNEL = "25.0.0"
MARKER = ".1401-build"          # Liberator only prepares startup files that 1401 made: this file beside EFI says so


class EfiError(ValueError):
    pass


def load_plist(path):
    with Path(path).open("rb") as stream:
        return plistlib.load(stream)


def save_plist(path, data):
    with Path(path).open("wb") as stream:
        plistlib.dump(data, stream, sort_keys=False)


def inspect_efi(source):
    """Checks that every enabled ACPI table, kext and driver in config.plist exists. Returns the EFI folder."""
    source = Path(source)
    efi = source / "EFI" if (source / "EFI").is_dir() else source
    if efi.name.upper() != "EFI":
        raise EfiError("Waehle die EFI oder ihren uebergeordneten Ordner.")
    for relative in ("BOOT/BOOTx64.efi", "OC/OpenCore.efi", "OC/config.plist"):
        if not (efi / relative).is_file():
            raise EfiError(f"In der EFI fehlt {relative}.")
    oc = efi / "OC"
    config = load_plist(oc / "config.plist")
    for section, key, folder, field in (("ACPI", "Add", "ACPI", "Path"),
                                        ("Kernel", "Add", "Kexts", "BundlePath"),
                                        ("UEFI", "Drivers", "Drivers", "Path")):
        for entry in config.get(section, {}).get(key, []):
            if isinstance(entry, str):
                name = entry
            elif entry.get("Enabled"):
                name = entry[field]
            else:
                continue
            relative = PurePosixPath(name)
            if relative.is_absolute() or ".." in relative.parts or ":" in name or "\\" in name:
                raise EfiError(f"Ungueltiger Pfad in config.plist: {name}")
            asset = oc / folder / relative
            if not asset.exists():
                raise EfiError(f"Aktiviert, aber fehlt in der EFI: {folder}/{name}")
            if folder == "Kexts" and isinstance(entry, dict):
                for field_name in ("PlistPath", "ExecutablePath"):
                    sub = entry.get(field_name)
                    if sub and not (asset / sub).is_file():
                        raise EfiError(f"Aktiviert, aber fehlt in der EFI: {name}/{sub}")
    return efi


def enabled_kexts(efi):
    config = load_plist(Path(efi) / "OC/config.plist")
    return [item["BundlePath"].split("/", 1)[0] for item in config["Kernel"]["Add"] if item.get("Enabled")]


def unpack_kext(archive, name, destination):
    """Extracts exactly one <name> bundle from an official release ZIP, refusing odd paths."""
    with zipfile.ZipFile(archive) as bundle:
        roots = {item.filename[: -len("/Contents/Info.plist")]
                 for item in bundle.infolist()
                 if item.filename.endswith(f"{name}/Contents/Info.plist") and not item.filename.startswith("__MACOSX/")
                 and "/PlugIns/" not in item.filename and ".dSYM/" not in item.filename}
        if len(roots) != 1:
            raise EfiError(f"{name} fehlt oder ist im offiziellen Archiv mehrdeutig.")
        prefix = roots.pop() + "/"
        destination = Path(destination)
        if destination.exists():
            shutil.rmtree(destination)
        for item in bundle.infolist():
            if item.is_dir() or not item.filename.startswith(prefix):
                continue
            parts = item.filename[len(prefix):].split("/")
            if any(part in {"", ".", ".."} or ":" in part or "\\" in part for part in parts):
                raise EfiError(f"Ungueltiger Pfad im Archiv: {item.filename}")
            target = destination.joinpath(*parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            with bundle.open(item) as src, target.open("wb") as out:
                shutil.copyfileobj(src, out)


def kext_entry(kext):
    meta = load_plist(Path(kext) / "Contents/Info.plist")
    executable = meta.get("CFBundleExecutable", "")
    path = f"Contents/MacOS/{executable}" if executable else ""
    if path and not (Path(kext) / path).is_file():
        raise EfiError(f"{Path(kext).name}: Das Kext-Executable fehlt.")
    return {
        "Arch": "x86_64",
        "BundlePath": Path(kext).name,
        "Comment": "XT12 Pro Iris Xe (Tahoe, von Liberator nach macOS 27 mitgenommen)",
        "Enabled": True,
        "ExecutablePath": path,
        "MaxKernel": "",
        "MinKernel": TAHOE_MIN_KERNEL,
        "PlistPath": "Contents/Info.plist",
    }


def version_of(kext):
    info = Path(kext) / "Contents/Info.plist"
    if not info.is_file():
        return ()
    match = re.match(r"^(\d+)\.(\d+)\.(\d+)", load_plist(info).get("CFBundleShortVersionString", ""))
    return tuple(map(int, match.groups())) if match else ()


def _boot_args(nvram):
    flags = nvram.get("boot-args", "")
    if isinstance(flags, bytes):
        flags = flags.decode("ascii", "replace")
    return flags.split()


def apply_profile_nvram(efi):
    """Each profile writes its own boot-args and SIP at every start (Delete + Add), so switching profiles never leaves
    the other profile's values behind in the firmware's NVRAM."""
    path = Path(efi) / "OC/config.plist"
    config = load_plist(path)
    nvram = config.setdefault("NVRAM", {})
    apple = nvram.setdefault("Add", {}).setdefault(NVRAM_APPLE, {})
    apple.setdefault("boot-args", "")
    apple.setdefault("csr-active-config", bytes(4))
    deletes = nvram.setdefault("Delete", {}).setdefault(NVRAM_APPLE, [])
    for name in ("boot-args", "csr-active-config"):
        if name not in deletes:
            deletes.append(name)
    save_plist(path, config)


def configure_iris(efi):
    """Turns a copy of the BASIS EFI into the IRIS profile (kexts must already be in OC/Kexts)."""
    efi = Path(efi)
    path = efi / "OC/config.plist"
    config = load_plist(path)
    kexts = efi / "OC/Kexts"
    ours = {name.lower() for name in IRIS_KEXTS}
    remaining = []
    for entry in config["Kernel"]["Add"]:
        parent = entry["BundlePath"].split("/", 1)[0].lower()
        if parent in ours:
            continue
        if parent in CONFLICTS:
            entry["Enabled"] = False
        remaining.append(entry)
    config["Kernel"]["Add"] = [kext_entry(kexts / name) for name in IRIS_KEXTS] + remaining

    nvram = config["NVRAM"]["Add"].setdefault(NVRAM_APPLE, {})
    flags = [flag for flag in _boot_args(nvram) if flag not in DROP_ARGS]
    for flag in IRIS_ARGS:
        if flag not in flags:
            flags.append(flag)
    nvram["boot-args"] = " ".join(flags)
    nvram["csr-active-config"] = bytes.fromhex("03080000")

    gpu = config.setdefault("DeviceProperties", {}).setdefault("Add", {}).setdefault(IGPU, {})
    for key in ("device-id", "AAPL,ig-platform-id", "disable-gpu-control"):
        gpu.pop(key, None)
    # WhateverXe's 60-MB-DVMT recipe. With 96 MB DVMT in the BIOS these are unnecessary but harmless.
    gpu["framebuffer-patch-enable"] = bytes.fromhex("01000000")
    gpu["framebuffer-stolenmem"] = bytes.fromhex("0000C003")
    save_plist(path, config)


def prepare_iris(base, destination, files):
    """files: {"lilu": zip, "wex": zip, "anchor": zip, "injector": Info.plist}. Returns the IRIS EFI folder."""
    destination = Path(destination)
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(base, destination)
    kexts = destination / "OC/Kexts"
    if version_of(kexts / "Lilu.kext") < (1, 7, 2):
        unpack_kext(files["lilu"], "Lilu.kext", kexts / "Lilu.kext")
    unpack_kext(files["anchor"], "AMFIAnchor.kext", kexts / "AMFIAnchor.kext")
    injector = kexts / "AMFIAnchorInjector.kext/Contents"
    injector.mkdir(parents=True, exist_ok=True)
    shutil.copy2(files["injector"], injector / "Info.plist")
    if load_plist(injector / "Info.plist").get("CFBundleIdentifier") != "org.b00t0x.AMFIAnchorInjector":
        raise EfiError("AMFIAnchorInjector hat eine unerwartete Bundle-ID.")
    unpack_kext(files["wex"], "WhateverXe.kext", kexts / "WhateverXe.kext")
    configure_iris(destination)
    inspect_efi(destination)
    return destination


def write_marker(root):
    (Path(root) / MARKER).write_text("built by 1401 (XT12 Pro Golden Gate Builder)\n", encoding="ascii")
