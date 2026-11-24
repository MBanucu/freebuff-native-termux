#!/usr/bin/env python3
"""Run the app's end-to-end test on a real device.

The test itself is an instrumentation test (android/app/src/androidTest): it does
the clicking through accessibility, waits on accessibility events, and asserts
what the app shows.  This script only handles what has to happen outside the app
under test: install the APKs, run `am instrument`, collect the screenshots.

    python3 test/android-e2e.py [--apk PATH] [--test-apk PATH]
                                [--serial SERIAL] [--screenshots DIR]
                                [--require-device] [--skip-native]

Exit codes: 0 pass, 1 failure, 77 skip (no adb, no device, no Termux, no APKs).
With --require-device a skip is reported as a failure instead of 77.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

PACKAGE = "io.github.mbanucu.freebuffnative"
TEST_PACKAGE = PACKAGE + ".test"
RUNNER = TEST_PACKAGE + "/androidx.test.runner.AndroidJUnitRunner"
TEST_CLASS = PACKAGE + ".SetupFlowTest"
DENIED_CLASS = PACKAGE + ".DeniedPermissionTest"
# The two methods that need no freebuff-native installation.  They are the
# fallback when the native download does not fit the hosted job's budget; the
# native method is then a recorded follow-up, never a pass.
UI_ONLY_CLASSES = ",".join((
    TEST_CLASS + "#aMainScreenOffersTheThreeActions",
    TEST_CLASS + "#bConsentDialogStatesTheDownload",
))
REMOTE_SHOTS = "/sdcard/Android/data/" + PACKAGE + "/files/screenshots"


class Skip(Exception):
    pass


def say(message):
    print(message, flush=True)


class Device:
    def __init__(self, serial):
        self.serial = serial

    def adb(self, *args, binary=False):
        command = ["adb"] + (["-s", self.serial] if self.serial else []) + list(args)
        result = subprocess.run(command, capture_output=True, check=False)
        if result.returncode != 0:
            raise RuntimeError("adb " + " ".join(args) + " failed: "
                               + result.stderr.decode("utf-8", "replace").strip())
        return result.stdout if binary else result.stdout.decode("utf-8", "replace")

    def shell(self, command):
        args = ["adb"] + (["-s", self.serial] if self.serial else []) + ["shell", command]
        return subprocess.run(args, capture_output=True, check=False).stdout.decode(
            "utf-8", "replace")

    def install(self, path, package):
        say("  install " + path.name)
        try:
            return self.adb("install", "-r", str(path))
        except RuntimeError as error:
            # Each CI build carries a new debug signature, so a build from
            # another run cannot be updated in place.
            if "INSTALL_FAILED_UPDATE_INCOMPATIBLE" not in str(error):
                raise
            self.shell("pm uninstall " + package)
            return self.adb("install", str(path))


def instrument(device, class_name, label=None):
    """Run one test class; return (ok, output). The runner output is verbose."""
    name = label or class_name.rsplit(".", 1)[-1]
    out = device.shell("am instrument -w -r -e class '%s' %s" % (class_name, RUNNER))
    passed = re.search(r"OK \((\d+) tests?\)", out)
    if passed and "FAILURES!!!" not in out and "INSTRUMENTATION_FAILED" not in out:
        say("  %s: %s test(s) passed" % (name, passed.group(1)))
        return True, out
    say("  %s: failed" % name)
    # Print the whole runner output, not a filtered summary: this is what the
    # workflow uploads as instrumentation evidence when the job fails.
    say(out)
    return False, out


def adb_devices():
    try:
        out = subprocess.run(["adb", "devices"], capture_output=True,
                             text=True, check=False).stdout
    except FileNotFoundError:
        raise Skip("adb is not installed")
    serials = []
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            serials.append(parts[0])
    return serials


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", default="android/app/build/outputs/apk/debug/app-debug.apk")
    parser.add_argument("--test-apk",
                        default="android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk")
    parser.add_argument("--serial", default=None)
    parser.add_argument("--screenshots", default=None)
    parser.add_argument("--require-device", action="store_true",
                        help="treat a skip (no device, Termux or APK) as a failure")
    parser.add_argument("--skip-native", action="store_true",
                        help="run only the UI and consent methods; the native "
                             "install check is then a recorded follow-up")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent

    def resolve(value):
        path = Path(value)
        return path if path.is_absolute() else root / path

    apk = resolve(args.apk)
    test_apk = resolve(args.test_apk)

    try:
        serials = adb_devices()
        if not serials:
            raise Skip("no device: connect one with 'adb devices'")
        device = Device(args.serial or serials[0])
        say("device " + device.serial)

        for path in (apk, test_apk):
            if not path.is_file():
                raise Skip("missing " + str(path) + " (build the debug and androidTest APKs)")
        if "package:com.termux" not in device.shell("pm list packages com.termux"):
            raise Skip("Termux is not installed on this device")

        say("install")
        device.install(apk, PACKAGE)
        device.install(test_apk, TEST_PACKAGE)
        device.shell("pm grant %s com.termux.permission.RUN_COMMAND" % PACKAGE)

        say("instrument: setup flow" + (" (UI and consent only)" if args.skip_native else ""))
        ok_flow, _ = instrument(
            device,
            UI_ONLY_CLASSES if args.skip_native else TEST_CLASS,
            "SetupFlowTest (UI/consent)" if args.skip_native else None)
        if args.skip_native:
            say("FOLLOW-UP: %s#cCheckReportsThroughTermux was not run; "
                "the native install check is not covered by this run" % TEST_CLASS)

        # Revoking a dangerous permission kills the app process, and the runner
        # lives there, so the denial path is a separate run with the permission
        # revoked before it starts.
        say("instrument: denied permission")
        device.shell("pm revoke %s com.termux.permission.RUN_COMMAND" % PACKAGE)
        ok_denied, _ = instrument(device, DENIED_CLASS)
        device.shell("pm grant %s com.termux.permission.RUN_COMMAND" % PACKAGE)
        if args.screenshots:
            shots = Path(args.screenshots)
            shots.mkdir(parents=True, exist_ok=True)
            for name in device.shell("ls " + REMOTE_SHOTS).split():
                if not name.endswith(".png"):
                    continue
                data = device.adb("exec-out", "cat", REMOTE_SHOTS + "/" + name, binary=True)
                (shots / name).write_bytes(data)
                say("  shot " + str(shots / name))

        if not (ok_flow and ok_denied):
            say("\ndiagnostics: last 40 log lines")
            say(device.shell("logcat -d -t 40 -s FreebuffNative:I AndroidRuntime:E"))
            return 1
        return 0

    except Skip as reason:
        if args.require_device:
            say("FAIL: %s (--require-device: a skip is a failure)" % reason)
            return 1
        say("SKIP: " + str(reason))
        return 77
    except RuntimeError as error:
        say("FAIL: " + str(error))
        return 1


if __name__ == "__main__":
    sys.exit(main())
