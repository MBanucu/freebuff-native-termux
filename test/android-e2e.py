#!/usr/bin/env python3
"""End-to-end test for the Android setup app, on a real device over adb.

Drives the UI like a user: read the screen, tap a button by its label, assert
what the app shows.  The Termux side is real: "Check setup" sends RUN_COMMAND to
the installed Termux and the app prints `freebuff-native --check`.

It is event driven.  Asynchronous work is awaited on `adb logcat` (the app logs
`FreebuffNative: sent app-shell: ...` and `result: ...`), window changes are
awaited on a cheap `dumpsys window`/`dumpsys activity` poll, and the UI
hierarchy is dumped only when an assertion needs it.  There are no fixed sleeps.

Requirements: adb, a connected device (`adb devices`), Termux installed there.

    python3 test/android-e2e.py [--apk PATH] [--serial SERIAL] [--screenshots DIR]

Exit codes: 0 pass, 1 failure, 77 skip (no adb, no device, no Termux).
"""

import argparse
import re
import select
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

PACKAGE = "io.github.mbanucu.freebuffnative"
ACTIVITY = PACKAGE + "/.MainActivity"
PERMISSION = "com.termux.permission.RUN_COMMAND"
LOG_TAG = "FreebuffNative"
REMOTE_UI = "/sdcard/freebuff-native-ui.xml"

failures = []


class Skip(Exception):
    pass


def say(message):
    print(message, flush=True)


def step(message, started=None):
    suffix = "" if started is None else "  (%.1fs)" % (time.monotonic() - started)
    say("\n# " + message + suffix)


def check(condition, message, detail=""):
    if condition:
        say("  ok   " + message)
    else:
        failures.append(message)
        say("  FAIL " + message + (("  (" + detail + ")") if detail else ""))


class LogWatch:
    """A logcat stream, so waiting for the app is a blocking read, not a poll."""

    def __init__(self, serial):
        command = ["adb"] + (["-s", serial] if serial else [])
        command += ["logcat", "-T", "1", "-v", "brief", "-s", LOG_TAG + ":I"]
        self.process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

    def wait(self, pattern, timeout):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            ready, _, _ = select.select([self.process.stdout], [], [], remaining)
            if not ready:
                return None
            line = self.process.stdout.readline()
            if not line:
                return None
            if re.search(pattern, line):
                return line.strip()

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.kill()


class Device:
    def __init__(self, serial, apk):
        self.serial = serial
        self.apk = apk
        self.shots = None

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

    def logcat(self):
        return LogWatch(self.serial)

    def ui(self):
        self.shell("uiautomator dump " + REMOTE_UI + " >/dev/null 2>&1")
        xml = self.shell("cat " + REMOTE_UI)
        xml = xml[xml.find("<?xml"):]
        return ET.fromstring(xml) if xml.strip() else None

    def texts(self, tree=None):
        tree = self.ui() if tree is None else tree
        return [node.get("text", "") for node in tree.iter("node")] if tree is not None else []

    def find(self, label, tree=None):
        tree = self.ui() if tree is None else tree
        if tree is None:
            return None
        for node in tree.iter("node"):
            if node.get("text", "") == label:
                return node
        return None

    def wait_text(self, needle, timeout=15):
        """Dump until the text is on screen. The dump is the only way to read UI."""
        deadline = time.monotonic() + timeout
        while True:
            tree = self.ui()
            texts = self.texts(tree)
            if any(needle == text for text in texts):
                return tree
            if time.monotonic() >= deadline:
                return None

    def wait_focus(self, needle, timeout=15):
        """Cheap window check; dumpsys is ~50 ms, so polling it is cheap."""
        deadline = time.monotonic() + timeout
        while True:
            out = self.shell("dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'")
            if needle in out:
                return True
            if time.monotonic() >= deadline:
                return False
            select.select([], [], [], 0.05)  # yield, don't sleep on a fixed timer

    def wait_activity(self, needle, timeout=15):
        deadline = time.monotonic() + timeout
        while True:
            out = self.shell("dumpsys activity activities | grep -m1 " + needle)
            if needle in out:
                return True
            if time.monotonic() >= deadline:
                return False
            select.select([], [], [], 0.05)

    def tap(self, label):
        node = self.find(label)
        if node is None:
            raise RuntimeError("no such element on screen: " + label)
        match = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
        if not match:
            raise RuntimeError("element has no bounds: " + label)
        x1, y1, x2, y2 = (int(value) for value in match.groups())
        self.shell("input tap %d %d" % ((x1 + x2) // 2, (y1 + y2) // 2))

    def screenshot(self, name):
        if self.shots is None:
            return
        Path(self.shots).mkdir(parents=True, exist_ok=True)
        path = Path(self.shots) / name
        path.write_bytes(self.adb("exec-out", "screencap", "-p", binary=True))
        say("  shot " + str(path))


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
    parser.add_argument("--serial", default=None)
    parser.add_argument("--screenshots", default=None)
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    apk = Path(args.apk)
    if not apk.is_absolute():
        apk = root / apk

    started = time.monotonic()
    try:
        serials = adb_devices()
        if not serials:
            raise Skip("no device: connect one with 'adb devices'")
        device = Device(args.serial or serials[0], apk)
        device.shots = args.screenshots

        step("device " + device.serial)
        if not apk.is_file():
            raise Skip("no apk at " + str(apk) + " (build it first)")
        say("  apk  " + str(apk))
        if "package:com.termux" not in device.shell("pm list packages com.termux"):
            raise Skip("Termux is not installed on this device")
        say("  Termux is installed")

        # A fresh install every run: each CI build carries a new debug signature.
        step("install")
        device.shell("pm uninstall " + PACKAGE)
        out = device.adb("install", str(apk))
        check("Success" in out, "the apk installs", out.strip()[-200:])
        device.shell("pm grant %s %s" % (PACKAGE, PERMISSION))
        grants = device.shell("dumpsys package %s | grep -A1 'runtime permissions'" % PACKAGE)
        check(PERMISSION in grants and "granted=true" in grants,
              "the RUN_COMMAND permission is granted", grants.strip()[-160:])
        internet = device.shell(
            "dumpsys package %s | grep -c 'android.permission.INTERNET'" % PACKAGE).strip()
        check(internet in ("", "0"), "the app has no INTERNET permission", internet)

        step("launch")
        device.shell("am start -W -n " + ACTIVITY)
        check(device.wait_focus(PACKAGE, timeout=15), "the app comes to the front")
        tree = device.wait_text("Termux is installed.", timeout=10)
        check(tree is not None, "the app sees Termux")
        for label in ("Set up freebuff-native", "Check setup", "Open Termux"):
            check(device.find(label, tree) is not None, "button present: " + label)
        device.screenshot("01-main.png")

        step("consent dialog")
        device.tap("Set up freebuff-native")
        tree = device.wait_text("Download about 540 MB?", timeout=10)
        check(tree is not None, "setup asks before downloading")
        if tree is not None:
            screen = "\n".join(text for text in device.texts(tree) if text)
            check("install.sh" in screen and "freebuff-native --download" in screen,
                  "the dialog shows the command it will run")
            check("136 MB" in screen and "400 MB" in screen,
                  "the dialog states the download sizes")
        device.screenshot("02-consent.png")
        device.tap("CANCEL")
        check(device.wait_text("Download about 540 MB?", timeout=5) is None,
              "cancel closes the dialog")

        step("check setup: RUN_COMMAND through Termux")
        watch = device.logcat()
        try:
            device.tap("Check setup")
            sent = watch.wait(r"sent app-shell: Check setup", timeout=15)
            check(sent is not None, "the app sends the check as an app-shell command",
                  "" if sent else "no log line")
            result = watch.wait(r"result: ", timeout=120) if sent else None
            check(result is not None, "Termux returns the result to the app",
                  "" if result else "no result event")
            check(device.wait_focus(PACKAGE, timeout=5),
                  "a background check does not leave the app")
            device.wait_text("native install complete", timeout=10)
            screen = "\n".join(device.texts())
            check("native install complete" in screen, "the app shows the check output")
            check("exit code 0" in screen, "the check exited 0", screen[-200:])
            check("spawn shim present" in screen, "the report names the shim")
            device.screenshot("03-check.png")
        finally:
            watch.close()

        step("permission prompt and recovery")
        device.shell("pm revoke %s %s" % (PACKAGE, PERMISSION))
        device.shell("pm clear " + PACKAGE)
        device.shell("am start -W -n " + ACTIVITY)
        device.wait_focus(PACKAGE, timeout=15)
        device.wait_text("Termux is installed.", timeout=10)
        watch = device.logcat()
        try:
            device.tap("Check setup")
            asked = watch.wait(r"asking for " + PERMISSION, timeout=10)
            check(asked is not None, "the app asks for Termux's permission")
            check(device.wait_activity("GrantPermissionsActivity", timeout=10),
                  "Android shows the permission dialog")
        finally:
            watch.close()
        device.shell("input keyevent BACK")
        device.shell("pm grant %s %s" % (PACKAGE, PERMISSION))
        watch = device.logcat()
        try:
            device.tap("Check setup")
            check(watch.wait(r"result: ", timeout=120) is not None,
                  "the check works once the permission is granted")
        finally:
            watch.close()

    except Skip as reason:
        say("\nSKIP: " + str(reason))
        return 77
    except RuntimeError as error:
        say("\nFAIL: " + str(error))
        return 1

    step("done in %.1fs" % (time.monotonic() - started))
    if failures:
        say("%d failure(s)" % len(failures))
        return 1
    say("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
