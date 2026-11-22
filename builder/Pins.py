"""Every file the builder downloads, pinned by address, size and SHA-256.

Stand: 22. November 2026. Each value was checked against the real download before it was written here.
A file that differs by one byte is refused. Apple's Tahoe installer is the only file chosen at run time: it comes
from Apple's own catalog and is checked against Apple's own SHA-256 block list (AppleInstaller.py).
"""

# --- macOS 27 Golden Gate (the files Liberator Beta 5 is built for) --------------------------------------------------
# Liberator's lay-down script refuses every other build, so these must match kit/laydown/*.sh of v3.0.0-beta.5.
GOLDEN_GATE_BUILD = "26B123"
GOLDEN_GATE_VERSION = "27.2"

GOLDEN_GATE_IPSW = {
    "name": "UniversalMac_27.2_26B123_Restore.ipsw",
    "url": "https://updates.cdn-apple.com/2026FallFCS/c9671975-52db-4fb5-9af2-00217169ba8d/UniversalMac_27.2_26B123_Restore.ipsw",
    "size": 25595669503,
    "sha256": "6613b34e8589db2202a01ec37a2648afb141ece13428175183f8f3e38438534f",
    "what": "macOS 27.2 Golden Gate (Apple-Wiederherstellungsimage)",
}

KDK = {
    "name": "Kernel_Debug_Kit_27.2_build_26B123.dmg",
    "url": "https://github.com/dortania/KdkSupportPkg/releases/download/26B123/Kernel_Debug_Kit_27.2_build_26B123.dmg",
    "size": 1251288981,
    "sha256": "c582c072188a15d8dbe0b878ab84563af8fb2baa25da2ea9565140de3df2228c",
    "what": "Kernel Debug Kit 27.2 (Intel-Kernel fuer Golden Gate)",
}

LIBERATOR_KIT = {
    "name": "nullmoth-v3-kit-3.0.0-beta.5.tar.gz",
    "url": "https://github.com/nullmoth/liberator/releases/download/v3.0.0-beta.5/nullmoth-v3-kit-3.0.0-beta.5.tar.gz",
    "size": 246607797,
    "sha256": "30a9369a266874dcc0520fbfd59bd2b43373eb29d8937c9347ea97eef9203345",
    "what": "Liberator-Kit Beta 5 (macOS-27-Startdateien fuer Intel)",
}

LIBERATOR_APP = {
    "name": "Liberator-Mac-0.5.0.zip",
    "url": "https://github.com/nullmoth/liberator/releases/download/v3.0.0-beta.5/Liberator-Mac-0.5.0.zip",
    "size": 2715761,
    "sha256": "928b0646ee6e62e7100b130e41afbd970520a2752658d6aac9642b3241c2bdb0",
    "what": "Liberator 0.5.0 (Mac-App: Tahoe -> Golden Gate)",
}

# --- Intel Iris Xe (Alder Lake 46A6) ---------------------------------------------------------------------------------
LILU = {
    "name": "Lilu-1.7.2-RELEASE.zip",
    "url": "https://github.com/acidanthera/Lilu/releases/download/1.7.2/Lilu-1.7.2-RELEASE.zip",
    "size": 781360,
    "sha256": "53967d7dcfaab01023a33df2e969a89522f13d6654a6a56ac4711b62dabf3ab8",
    "what": "Lilu 1.7.2",
}
WHATEVERXE = {
    "name": "WhateverXe-0.8.3-RELEASE.zip",
    "url": "https://github.com/b00t0x/WhateverXe/releases/download/0.8.3/WhateverXe-0.8.3-RELEASE.zip",
    "size": 2120129,
    "sha256": "d56e3a7055b1dbb6f75f9f155bc4fe1ce1b5989b6038e79902e3a6cccce762e2",
    "what": "WhateverXe 0.8.3",
}
AMFIANCHOR = {
    "name": "AMFIAnchor-0.1.2-Release.zip",
    "url": "https://github.com/b00t0x/AMFIAnchor/releases/download/0.1.2/AMFIAnchor-0.1.2-Release.zip",
    "size": 26547,
    "sha256": "7c4f416bf97e599cf9fe85347ad55a3c454e0eb9944a439a1b04ad16e8beb8bd",
    "what": "AMFIAnchor 0.1.2",
}
AMFIANCHOR_INJECTOR = {
    "name": "AMFIAnchorInjector-Info.plist",
    "url": "https://raw.githubusercontent.com/b00t0x/AMFIAnchor/0.1.2/Injectors/AMFIAnchorInjector.kext/Contents/Info.plist",
    "size": 2484,
    "sha256": "787000ebd869d2654d169098daa6e8dac646caf29b842695833f9d5847e2ec68",
    "what": "AMFIAnchorInjector 0.1.2",
}
WHATEVERXE_GRAPHICS = {
    "name": "WhateverXe-Graphics-0.4.4.pkg",
    "url": "https://github.com/b00t0x/WhateverXe-Graphics/releases/download/v0.4.4/WhateverXe-Graphics-0.4.4.pkg",
    "size": 95215914,
    "sha256": "f4c2d680a7c52c33a3f038ce6945da0aa2cc044e62b935a52ea046c7c473cfec",
    "what": "WhateverXe Graphics 0.4.4 (Iris-Xe-Beschleunigung fuer Tahoe)",
}

IRIS_FILES = (LILU, WHATEVERXE, AMFIANCHOR, AMFIANCHOR_INJECTOR)
GOLDEN_GATE_FILES = (GOLDEN_GATE_IPSW, KDK, LIBERATOR_KIT, LIBERATOR_APP)

# --- macOS 26 Tahoe (the step before Golden Gate) --------------------------------------------------------------------
TAHOE_DARWIN = 25            # 1401's engine and recovery speak Darwin numbers
TAHOE_CATALOG_MAJOR = 26     # 1401's full-installer catalog speaks marketing numbers
TAHOE_MIN = (26, 7)          # WhateverXe Graphics 0.4.4 needs Tahoe 26.7 or newer

# --- Iris Xe IDs WhateverXe drives on Alder Lake-H/P/U (docs/device-selection.md of WhateverXe 0.8.3) -----------------
ALDER_LAKE_IGPU = {"4626", "4628", "462A", "46A0", "46A1", "46A2", "46A3", "46A6", "46A8", "46AA",
                   "46B0", "46B1", "46B2", "46B3", "46C0", "46C1", "46C2", "46C3"}

GIB = 1024 ** 3


def all_pins():
    return IRIS_FILES + (WHATEVERXE_GRAPHICS,) + GOLDEN_GATE_FILES


def golden_gate_bytes():
    return sum(pin["size"] for pin in GOLDEN_GATE_FILES)
