"""Tests that run anywhere (no Windows, no network): python3 -m unittest discover -s tests"""
import hashlib
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "builder"))

import AppleInstaller  # noqa: E402
import Efi  # noqa: E402
import Fetch  # noqa: E402
import Pins  # noqa: E402
import XT12Builder  # noqa: E402


def write_kext_zip(path, name, executable=True, prefix=""):
    with zipfile.ZipFile(path, "w") as z:
        info = {"CFBundleIdentifier": f"test.{name}", "CFBundleShortVersionString": "1.7.2"}
        if executable:
            info["CFBundleExecutable"] = name.removesuffix(".kext")
            z.writestr(f"{prefix}{name}/Contents/MacOS/{name.removesuffix('.kext')}", b"\xcf\xfa\xed\xfe")
        z.writestr(f"{prefix}{name}/Contents/Info.plist", plistlib.dumps(info))
        z.writestr(f"{prefix}{name}.dSYM/Contents/Info.plist", plistlib.dumps({"x": 1}))


def make_efi(root):
    efi = Path(root) / "EFI"
    (efi / "BOOT").mkdir(parents=True)
    (efi / "BOOT/BOOTx64.efi").write_bytes(b"boot")
    oc = efi / "OC"
    (oc / "Kexts").mkdir(parents=True)
    (oc / "Drivers").mkdir()
    (oc / "ACPI").mkdir()
    (oc / "OpenCore.efi").write_bytes(b"oc")
    for kext in ("Lilu.kext", "WhateverGreen.kext"):
        (oc / "Kexts" / kext / "Contents/MacOS").mkdir(parents=True)
        (oc / "Kexts" / kext / "Contents/MacOS" / kext.removesuffix(".kext")).write_bytes(b"x")
        (oc / "Kexts" / kext / "Contents/Info.plist").write_bytes(plistlib.dumps(
            {"CFBundleExecutable": kext.removesuffix(".kext"), "CFBundleShortVersionString": "1.6.9"}))
    config = {
        "ACPI": {"Add": []},
        "DeviceProperties": {"Add": {Efi.IGPU: {"AAPL,ig-platform-id": b"\x00\x00\x00\x00"}}},
        "Kernel": {"Add": [
            {"BundlePath": k, "Enabled": True, "ExecutablePath": f"Contents/MacOS/{k[:-5]}", "PlistPath": "Contents/Info.plist",
             "Arch": "Any", "Comment": "", "MaxKernel": "", "MinKernel": ""} for k in ("Lilu.kext", "WhateverGreen.kext")]},
        "NVRAM": {"Add": {Efi.NVRAM_APPLE: {"boot-args": "-v -wegnoigpu keepsyms=1"}}, "Delete": {}},
        "UEFI": {"Drivers": []},
    }
    (oc / "config.plist").write_bytes(plistlib.dumps(config))
    return efi


class PinsTest(unittest.TestCase):
    def test_every_pin_is_complete(self):
        for pin in Pins.all_pins():
            self.assertRegex(pin["sha256"], r"^[0-9a-f]{64}$", pin["name"])
            self.assertTrue(pin["url"].startswith("https://"), pin["name"])
            self.assertGreater(pin["size"], 0)
            self.assertNotIn("/", pin["name"])

    def test_golden_gate_matches_liberator_beta5(self):
        self.assertIn(Pins.GOLDEN_GATE_BUILD, Pins.GOLDEN_GATE_IPSW["name"])
        self.assertIn(Pins.GOLDEN_GATE_BUILD, Pins.KDK["name"])
        self.assertIn("beta.5", Pins.LIBERATOR_KIT["url"])

    def test_mac_script_uses_the_same_names(self):
        script = (ROOT / "payload/macOS/2-Nach-der-Installation.command").read_text()
        for pin in Pins.GOLDEN_GATE_FILES + (Pins.WHATEVERXE_GRAPHICS,):
            self.assertIn(pin["name"], script)

    def test_alder_lake_ids(self):
        self.assertIn("46A6", Pins.ALDER_LAKE_IGPU)


class EfiTest(unittest.TestCase):
    def test_iris_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            base = make_efi(tmp / "base")
            Efi.apply_profile_nvram(base)
            Efi.inspect_efi(base)
            zips = {}
            for key, name in (("lilu", "Lilu.kext"), ("wex", "WhateverXe.kext")):
                zips[key] = tmp / f"{key}.zip"
                write_kext_zip(zips[key], name)
            zips["anchor"] = tmp / "anchor.zip"
            write_kext_zip(zips["anchor"], "AMFIAnchor.kext", prefix="AMFIAnchor-0.1.2-Release/")
            zips["injector"] = tmp / "Info.plist"
            zips["injector"].write_bytes(plistlib.dumps({"CFBundleIdentifier": "org.b00t0x.AMFIAnchorInjector"}))
            iris = Efi.prepare_iris(base, tmp / "iris/EFI", zips)
            config = Efi.load_plist(iris / "OC/config.plist")
            order = [e["BundlePath"] for e in config["Kernel"]["Add"]]
            self.assertEqual(order[:4], list(Efi.IRIS_KEXTS))
            weg = next(e for e in config["Kernel"]["Add"] if e["BundlePath"] == "WhateverGreen.kext")
            self.assertFalse(weg["Enabled"])
            self.assertEqual(config["Kernel"]["Add"][3]["MinKernel"], "25.0.0")
            self.assertEqual(config["Kernel"]["Add"][2]["ExecutablePath"], "")
            nv = config["NVRAM"]["Add"][Efi.NVRAM_APPLE]
            self.assertEqual(nv["csr-active-config"], bytes.fromhex("03080000"))
            self.assertNotIn("-wegnoigpu", nv["boot-args"].split())
            for flag in Efi.IRIS_ARGS:
                self.assertIn(flag, nv["boot-args"].split())
            self.assertIn("boot-args", config["NVRAM"]["Delete"][Efi.NVRAM_APPLE])
            self.assertNotIn("AAPL,ig-platform-id", config["DeviceProperties"]["Add"][Efi.IGPU])
            self.assertEqual(Efi.version_of(iris / "OC/Kexts/Lilu.kext"), (1, 7, 2))
            # the base profile is untouched
            self.assertIn("WhateverGreen.kext", Efi.enabled_kexts(base))

    def test_missing_kext_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = make_efi(tmp)
            import shutil
            shutil.rmtree(base / "OC/Kexts/Lilu.kext")
            with self.assertRaises(Efi.EfiError):
                Efi.inspect_efi(base)


class AppleTest(unittest.TestCase):
    def manifest(self, blocks):
        body = b"".join(struct.pack("<I32s", len(b), hashlib.sha256(b).digest()) for b in blocks)
        header = struct.pack("<4sIBBBBQQQ", b"CNKL", 36, 1, 1, 2, 0, len(blocks), 36, 36 + len(body))
        data = header + body
        return data + hashlib.sha256(data).digest()

    def test_chunks_and_prefix(self):
        blocks = [b"a" * 100, b"b" * 50]
        chunks = AppleInstaller.parse_chunks(self.manifest(blocks), 150)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "pkg"
            path.write_bytes(b"a" * 100 + b"x" * 50)
            self.assertEqual(AppleInstaller.verified_prefix(path, chunks), 100)
            path.write_bytes(b"".join(blocks))
            self.assertEqual(AppleInstaller.verified_prefix(path, chunks), 150)

    def test_bad_manifest(self):
        data = bytearray(self.manifest([b"a"]))
        data[-1] ^= 1
        with self.assertRaises(Fetch.FetchError):
            AppleInstaller.parse_chunks(bytes(data), 1)

    def test_version(self):
        self.assertGreaterEqual(AppleInstaller.version_tuple("26.7.3"), Pins.TAHOE_MIN)
        self.assertLess(AppleInstaller.version_tuple("26.6"), Pins.TAHOE_MIN)


class FetchTest(unittest.TestCase):
    def test_copy_and_stamp(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "a.bin"
            src.write_bytes(b"hello" * 1000)
            sha = hashlib.sha256(src.read_bytes()).hexdigest()
            pin = {"name": "a.bin", "size": src.stat().st_size, "sha256": sha, "what": "a"}
            self.assertTrue(Fetch.is_verified(src, pin))
            dst = Fetch.copy_verified(src, Path(tmp) / "out" / "a.bin", sha, "a")
            self.assertEqual(dst.read_bytes(), src.read_bytes())
            self.assertTrue(Fetch.is_verified(dst, pin))
            dst2 = Fetch.copy_verified(src, Path(tmp) / "out2" / "a.bin", None, "a")
            self.assertEqual(dst2.read_bytes(), src.read_bytes())
            with self.assertRaises(Fetch.FetchError):
                Fetch.copy_verified(src, Path(tmp) / "out3" / "a.bin", "0" * 64, "a")


class PayloadTest(unittest.TestCase):
    def test_shell_scripts_parse(self):
        for script in list((ROOT / "payload").rglob("*.sh")) + list((ROOT / "payload").rglob("*.command")):
            subprocess.run(["bash", "-n", str(script)], check=True)
            self.assertNotIn(b"\r\n", script.read_bytes(), script.name)

    def test_line_ends(self):
        with tempfile.TemporaryDirectory() as tmp:
            sh, cmd = Path(tmp) / "a.sh", Path(tmp) / "a.cmd"
            sh.write_bytes(b"a\r\nb\r\n")
            cmd.write_bytes(b"a\nb\r\n")
            XT12Builder.normalise_text(sh, Path(tmp) / "o/a.sh")
            XT12Builder.normalise_text(cmd, Path(tmp) / "o/a.cmd")
            self.assertEqual((Path(tmp) / "o/a.sh").read_bytes(), b"a\nb\n")
            self.assertEqual((Path(tmp) / "o/a.cmd").read_bytes(), b"a\r\nb\r\n")

    def test_hardware_ids(self):
        report = {"GPU": {"Iris": {"Device ID": "8086-46a6"}}, "Network": {"MT": {"Device ID": "14C3-7922"}}}
        self.assertEqual(XT12Builder.device_ids(report, "GPU"), ["8086-46A6"])
        self.assertEqual(XT12Builder.device_ids(report, "Bluetooth"), [])

    def test_disk_budget(self):
        product = {"size": 18388869343}
        data = XT12Builder.data_bytes(product)
        self.assertLess(2 * Pins.GIB + data, 64 * 10 ** 9)       # a 64 GB disk holds the installer
        self.assertGreater(256 * 10 ** 9 - 2 * Pins.GIB - data, XT12Builder.MACOS_MIN_GIB * Pins.GIB)  # 256 GB holds macOS too


if __name__ == "__main__":
    unittest.main()
