#!/usr/bin/env python3
"""Parsers for the emulator e2e wrapper, testable without a device.

The shell wrapper has two places where a quiet misread would turn into a false
green: choosing the attached emulator out of ``adb devices`` and choosing the
x86_64 package out of a GitHub release.  Both parsers live here so the deviceless
tests can exercise them with fixtures instead of a hosted AVD.

    python3 ci/emulator_probe.py emulator --devices -
    python3 ci/emulator_probe.py release --json release.json --arch x86_64
"""

import argparse
import json
import re
import sys

EMULATOR = re.compile(r"^emulator-[0-9]+$")
DEB = re.compile(r"^freebuff-native_.*?_(?P<arch>[A-Za-z0-9_]+)\.deb$")


class ProbeError(Exception):
    pass


def attached_emulator(device_list):
    """Return the first attached emulator serial; a phone is not a substitute."""
    serials = []
    for line in device_list.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device" and EMULATOR.match(parts[0]):
            serials.append(parts[0])
    if not serials:
        raise ProbeError("no attached emulator-* in the adb device state")
    return serials[0]


def deb_asset(release, arch="x86_64"):
    """Return (name, url, sha256) for the release's freebuff-native .deb.

    The digest is required: a package downloaded without a checksum would make
    the native install evidence weaker than the release page it came from.
    """
    if not isinstance(release, dict):
        raise ProbeError("the release metadata is not a JSON object")
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise ProbeError("the release metadata has no asset list")

    matches = []
    for asset in assets:
        if not isinstance(asset, dict):
            continue
        name = asset.get("name") or ""
        found = DEB.match(name)
        if found and found.group("arch") == arch:
            matches.append(asset)
    if not matches:
        raise ProbeError("the release has no freebuff-native .deb for " + arch)
    if len(matches) > 1:
        names = ", ".join(sorted(asset.get("name", "?") for asset in matches))
        raise ProbeError("the release has more than one " + arch + " .deb: " + names)

    asset = matches[0]
    name = asset.get("name") or ""
    url = asset.get("browser_download_url") or ""
    if not name or not url:
        raise ProbeError("the " + arch + " .deb asset has no name or download URL")
    digest = asset.get("digest") or ""
    if not digest.startswith("sha256:"):
        raise ProbeError(name + " has no sha256 digest; refusing an unverified download")
    sha256 = digest[len("sha256:"):]
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise ProbeError(name + " has a malformed sha256 digest:" + digest)
    return name, url, sha256


def read_input(path):
    if path == "-":
        return sys.stdin.read()
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    verbs = parser.add_subparsers(dest="verb", required=True)

    emulator = verbs.add_parser("emulator", help="select an attached emulator")
    emulator.add_argument("--devices", default="-",
                          help="a file with `adb devices` output, or - for stdin")

    release = verbs.add_parser("release", help="select the release .deb")
    release.add_argument("--json", required=True,
                         help="the GitHub releases/latest JSON, or - for stdin")
    release.add_argument("--arch", default="x86_64")

    args = parser.parse_args(argv)
    try:
        if args.verb == "emulator":
            print(attached_emulator(read_input(args.devices)))
        else:
            name, url, sha256 = deb_asset(json.loads(read_input(args.json)),
                                          args.arch)
            print("%s\t%s\t%s" % (name, url, sha256))
    except (ProbeError, OSError, ValueError) as error:
        print("emulator e2e: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
