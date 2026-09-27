#!/usr/bin/env python3
"""Configure an extracted host Info.plist before signing an injected IPA."""
import plistlib
import sys
from pathlib import Path


def configure(info):
    identifier = info["CFBundleIdentifier"] + ".gotohp.upload.*"
    permitted = info.setdefault("BGTaskSchedulerPermittedIdentifiers", [])
    if identifier not in permitted:
        permitted.append(identifier)
    modes = info.setdefault("UIBackgroundModes", [])
    if "processing" not in modes:
        modes.append("processing")
    return info


if __name__ == "__main__":
    path = Path(sys.argv[1])
    path.write_bytes(plistlib.dumps(configure(plistlib.loads(path.read_bytes())), fmt=plistlib.FMT_BINARY))
