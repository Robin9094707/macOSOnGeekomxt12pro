"""Apple's full macOS 26 Tahoe installer (InstallAssistant.pkg), checked against Apple's own SHA-256 block list.

Apple publishes <package>.integrityDataV1 beside every InstallAssistant.pkg: a list of SHA-256 hashes, one per block of
the package, itself closed by a SHA-256. A resumed download is checked block by block, so a broken tail is cut off and
loaded again instead of starting over. After that 1401's verify_xar() checks the archive's own checksums.
"""
import hashlib
import re
import struct
import subprocess
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import urlopen

from Fetch import FetchError, curl_binary, progress_printer, sha256_file

APPLE_HOSTS = {"swcdn.apple.com", "updates.cdn-apple.com", "oscdn.apple.com"}
HEADER = struct.Struct("<4sIBBBBQQQ")
CHUNK = struct.Struct("<I32s")
MAX_MANIFEST = 1024 ** 2
GIB = 1024 ** 3


def parse_chunks(manifest, size):
    if len(manifest) < HEADER.size + 32:
        raise FetchError("Apples Installer-Pruefliste ist unvollstaendig.")
    magic, header_size, version, method, trailer, reserved, count, start, end = HEADER.unpack_from(manifest)
    if ((magic, header_size, version, method, trailer, reserved, start)
            != (b"CNKL", HEADER.size, 1, 1, 2, 0, HEADER.size)
            or not count or end != start + count * CHUNK.size or len(manifest) != end + 32
            or hashlib.sha256(manifest[:end]).digest() != manifest[end:]):
        raise FetchError("Apples Installer-Pruefliste hat ein unerwartetes Format oder eine falsche Pruefsumme.")
    chunks = list(CHUNK.iter_unpack(manifest[start:end]))
    if any(not 0 < length <= 64 * 1024 ** 2 for length, _ in chunks) or sum(length for length, _ in chunks) != size:
        raise FetchError("Apples Installer-Pruefliste passt nicht zur Kataloggroesse.")
    return chunks


def apple_chunks(url, size):
    source = urlsplit(url)
    if source.scheme != "https" or source.hostname not in APPLE_HOSTS or source.query or source.fragment:
        raise FetchError("Der InstallAssistant muss aus Apples offiziellem Download-Katalog kommen.")
    with urlopen(url + ".integrityDataV1", timeout=60) as response:  # noqa: S310 - https, Apple host checked
        final = urlsplit(response.geturl())
        if final.scheme != "https" or final.hostname not in APPLE_HOSTS:
            raise FetchError("Die Installer-Pruefliste wurde nicht von Apple geliefert.")
        manifest = response.read(MAX_MANIFEST + 1)
    if len(manifest) > MAX_MANIFEST:
        raise FetchError("Apples Installer-Pruefliste ist ungewoehnlich gross.")
    return parse_chunks(manifest, size)


def verified_prefix(path, chunks, progress=None):
    if not path.is_file():
        return 0
    total = path.stat().st_size
    verified = 0
    with path.open("rb") as stream:
        for length, digest in chunks:
            if verified + length > total or hashlib.sha256(stream.read(length)).digest() != digest:
                break
            verified += length
            if progress:
                progress(verified, total)
    return verified


def _trim(path, length):
    if path.is_file() and path.stat().st_size > length:
        with path.open("r+b") as stream:
            stream.truncate(length)


def version_tuple(text):
    return tuple(int(part) for part in re.findall(r"\d+", str(text))[:3])


def choose_tahoe(fullinstaller, catalog_major, minimum):
    product = fullinstaller.latest(catalog_major)
    version, build = str(product.get("version", "")), str(product.get("build", ""))
    if not re.fullmatch(r"26(\.\d+){1,2}", version) or not re.fullmatch(r"25[A-Z]\d+[a-z]?", build):
        raise FetchError(f"Apples Katalog lieferte keinen eindeutigen Tahoe-Build ({version} {build}).")
    if version_tuple(version) < minimum:
        raise FetchError(f"Apple bietet Tahoe {version} an; WhateverXe Graphics braucht {'.'.join(map(str, minimum))} oder neuer.")
    if int(product.get("size", 0)) <= 0:
        raise FetchError("Der Tahoe-Installer hat keine gueltige Groesse im Katalog.")
    return product


def fetch_tahoe(fullinstaller, product, folder):
    """Returns (path, sha256) of a fully checked InstallAssistant.pkg for `product`, directly inside `folder`."""
    size = int(product["size"])
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    final = folder / fullinstaller.PACKAGE_NAME
    stamp = folder / (fullinstaller.PACKAGE_NAME + ".ok")
    if final.is_file() and final.stat().st_size == size and stamp.is_file():
        fields = stamp.read_text(encoding="ascii").split()
        if len(fields) == 3 and fields[:2] == [str(size), str(int(final.stat().st_mtime))]:
            print(f"  Vorhanden und geprueft: macOS Tahoe {product['version']} ({product['build']})")
            return final, fields[2]
    print(f"  Apple macOS Tahoe {product['version']} ({product['build']}), {size / GIB:.1f} GiB", flush=True)
    chunks = apple_chunks(product["url"], size)
    part = final if final.is_file() else folder / (fullinstaller.PACKAGE_NAME + ".part")
    verified = verified_prefix(part, chunks)
    _trim(part, verified)
    if verified != size:
        if part == final:
            part = final.rename(folder / (fullinstaller.PACKAGE_NAME + ".part"))
        if verified:
            print(f"  Setze den Download ab {verified / GIB:.2f} GiB fort.")
        for attempt in range(1, 7):
            result = subprocess.run([
                curl_binary(), "--fail", "--location", "--proto", "=https", "--proto-redir", "=https",
                "--connect-timeout", "30", "--speed-limit", "1024", "--speed-time", "120",
                "--retry", "5", "--retry-delay", "5", "--continue-at", "-", "--progress-bar",
                "--output", str(part), product["url"],
            ])
            if part.is_file() and part.stat().st_size == size:
                break
            print(f"  Download unterbrochen (curl {result.returncode}), Versuch {attempt}/6 ...")
        print("  Pruefe Apples SHA-256-Bloecke ...", flush=True)
        verified = verified_prefix(part, chunks, progress_printer("Apple-Bloecke"))
        if verified != size:
            _trim(part, verified)
            raise FetchError(f"Apples Blockpruefung stoppte bei {verified / GIB:.2f} GiB. Erneut starten setzt dort fort.")
    print("  Pruefe das Paketarchiv (xar, liest das ganze Paket noch einmal) ...", flush=True)
    fullinstaller.verify_xar(str(part), progress=progress_printer("Paketarchiv"))
    if part != final:
        part.replace(final)
    print("  Berechne die SHA-256 fuer die spaetere Kopierpruefung ...", flush=True)
    digest = sha256_file(final, progress_printer("SHA-256"))
    stamp.write_text(f"{size} {int(final.stat().st_mtime)} {digest}\n", encoding="ascii")
    return final, digest
