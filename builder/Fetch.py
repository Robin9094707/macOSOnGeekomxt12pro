"""Downloads that survive interruptions and never hand over an unchecked byte.

pinned(): files with a known size and SHA-256 (Pins.py). A download goes to <name>.part, resumes there, and is
renamed only after its size and SHA-256 match. A verified file gets a small stamp (<name>.ok) holding size, mtime and
hash, so a second run does not read 25 GB again unless the file changed.

Apple's Tahoe installer is checked against Apple's own SHA-256 block list (.integrityDataV1) instead: AppleInstaller.py.
"""
import hashlib
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

MIB = 1024 ** 2
GIB = 1024 ** 3


class FetchError(RuntimeError):
    pass


def curl_binary():
    if os.name == "nt":
        path = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "curl.exe"
        if path.is_file():
            return str(path)
    found = shutil.which("curl.exe" if os.name == "nt" else "curl")
    if not found:
        raise FetchError("curl fehlt. Unter Windows 10/11 gehoert curl.exe zum System (C:\\Windows\\System32\\curl.exe).")
    return found


def progress_printer(label):
    state = {"last": -1, "t": 0.0}

    def update(done, total):
        if not total:
            return
        percent = min(100, int(done * 100 / total))
        now = time.monotonic()
        if percent != state["last"] and (now - state["t"] > 0.5 or percent == 100):
            print(f"\r  {label}: {percent:3d} %  ({done / GIB:.2f} / {total / GIB:.2f} GiB)", end="", flush=True)
            state["last"], state["t"] = percent, now
            if percent == 100:
                print(flush=True)

    return update


def sha256_file(path, progress=None, chunk=8 * MIB):
    digest = hashlib.sha256()
    total = path.stat().st_size
    done = 0
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(chunk), b""):
            digest.update(block)
            done += len(block)
            if progress:
                progress(done, total)
    return digest.hexdigest()


def _stamp(path):
    return path.with_name(path.name + ".ok")


def _stamp_text(path, sha):
    st = path.stat()
    return f"{st.st_size} {int(st.st_mtime)} {sha}\n"


def is_verified(path, pin):
    """True when path holds exactly the pinned file. Uses the stamp when it still describes the file."""
    if not path.is_file() or path.stat().st_size != pin["size"]:
        return False
    stamp = _stamp(path)
    try:
        if stamp.read_text(encoding="ascii") == _stamp_text(path, pin["sha256"]):
            return True
    except OSError:
        pass
    print(f"  Pruefe SHA-256 von {pin['name']} ...", flush=True)
    if sha256_file(path, progress_printer("SHA-256") if pin["size"] > 512 * MIB else None) != pin["sha256"]:
        return False
    try:
        stamp.write_text(_stamp_text(path, pin["sha256"]), encoding="ascii")
    except OSError:
        pass
    return True


def free_bytes(directory):
    return shutil.disk_usage(directory).free


def pinned(pin, directory, tries=6):
    """Returns the path of the verified file in `directory`, downloading or resuming it when needed."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    final = directory / pin["name"]
    if is_verified(final, pin):
        print(f"  Vorhanden und geprueft: {pin['what']}")
        return final
    if final.exists():
        print(f"  {final.name} passt nicht zum Pin und wird neu geladen.")
        final.unlink()
    part = directory / (pin["name"] + ".part")
    if part.is_file() and part.stat().st_size > pin["size"]:
        part.unlink()
    have = part.stat().st_size if part.is_file() else 0
    if free_bytes(directory) < pin["size"] - have + 256 * MIB:
        raise FetchError(f"Zu wenig Platz in {directory} fuer {pin['name']} "
                         f"({(pin['size'] - have) / GIB:.1f} GiB fehlen noch).")
    print(f"  Lade {pin['what']} ({pin['size'] / GIB:.2f} GiB)" + (f", fortgesetzt ab {have / GIB:.2f} GiB" if have else ""),
          flush=True)
    curl = curl_binary()
    for attempt in range(1, tries + 1):
        result = subprocess.run([
            curl, "--fail", "--location", "--proto", "=https", "--proto-redir", "=https",
            "--connect-timeout", "30", "--speed-limit", "1024", "--speed-time", "120",
            "--retry", "5", "--retry-delay", "5", "--continue-at", "-",
            "--progress-bar", "--output", str(part), pin["url"],
        ])
        size = part.stat().st_size if part.is_file() else 0
        if size == pin["size"]:
            break
        if result.returncode == 33 or size > pin["size"]:      # server refused the resume, or a broken tail
            part.unlink(missing_ok=True)
        print(f"  Download unterbrochen (curl {result.returncode}), Versuch {attempt}/{tries} ...", file=sys.stderr)
        time.sleep(min(60, 5 * attempt))
    else:
        raise FetchError(f"{pin['name']} konnte nicht vollstaendig geladen werden. Ein erneuter Start setzt fort.")
    print(f"  Pruefe SHA-256 von {pin['name']} ...", flush=True)
    got = sha256_file(part, progress_printer("SHA-256") if pin["size"] > 512 * MIB else None)
    if got != pin["sha256"]:
        part.unlink(missing_ok=True)
        raise FetchError(f"{pin['name']}: falsche SHA-256 ({got}). Die Datei wurde geloescht, bitte erneut starten.")
    part.replace(final)
    _stamp(final).write_text(_stamp_text(final, pin["sha256"]), encoding="ascii")
    print(f"  OK: {pin['what']}")
    return final


def copy_verified(source, destination, sha256, label):
    """Copies a file, flushes it to the disk and reads it back: a USB disk that loses writes is caught here.
    sha256 None: the source is hashed while it is copied, and the copy must read back the same."""
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    size = Path(source).stat().st_size
    if sha256 and destination.is_file() and destination.stat().st_size == size:
        stamp = _stamp(destination)
        try:
            if stamp.read_text(encoding="ascii") == _stamp_text(destination, sha256):
                print(f"  Schon auf dem Ziel und geprueft: {label}")
                return destination
        except OSError:
            pass
    temp = destination.with_name(destination.name + ".part")
    progress = progress_printer(f"Kopiere {label}")
    source_hash = hashlib.sha256()
    done = 0
    with open(source, "rb") as src, open(temp, "wb") as dst:
        for block in iter(lambda: src.read(8 * MIB), b""):
            source_hash.update(block)
            dst.write(block)
            done += len(block)
            progress(done, size)
        dst.flush()
        os.fsync(dst.fileno())
    if sha256 and source_hash.hexdigest() != sha256:
        temp.unlink(missing_ok=True)
        raise FetchError(f"{label}: die Quelle im Cache ist beschaedigt. Cache-Datei loeschen und erneut starten: {source}")
    sha256 = sha256 or source_hash.hexdigest()
    got = sha256_file(temp, progress_printer(f"Lese {label} zurueck") if size > 512 * MIB else None)
    if got != sha256:
        temp.unlink(missing_ok=True)
        raise FetchError(f"{label} liest sich auf dem Ziel anders zurueck als die gepruefte Quelle. "
                         "Das Laufwerk verliert Daten: anderen USB-Port oder andere Platte verwenden.")
    if destination.exists():
        destination.unlink()
    temp.replace(destination)
    try:
        _stamp(destination).write_text(_stamp_text(destination, sha256), encoding="ascii")
    except OSError:
        pass
    return destination
