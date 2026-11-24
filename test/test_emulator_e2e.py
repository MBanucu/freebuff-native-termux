#!/usr/bin/env python3
"""Deviceless checks for the emulator e2e wrapper.

No emulator, no adb and no KVM: a fake adb supplies the device table and the
getprop answers, a fake python3 turns the instrumentation call into an exit-77
skip, and the release fixture is the GitHub API's shape.  The hosted job still
needs a real AVD; these tests keep the fail-closed parts honest.
"""

import json
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SCRIPT = ROOT / "ci" / "emulator-e2e.sh"
PROBE = ROOT / "ci" / "emulator_probe.py"
E2E = ROOT / "test" / "android-e2e.py"

sys.path.insert(0, str(ROOT / "ci"))
import emulator_probe as probe  # noqa: E402

FAKE_ADB = """#!/bin/sh
if [ "$1" = "devices" ]; then
    printf 'List of devices attached\\n'
    printf '%s\\n' "${FAKE_ADB_DEVICES:-}"
    exit 0
fi
for arg in "$@"; do
    case $arg in
        ro.build.version.sdk) echo 35; exit 0 ;;
        ro.product.cpu.abi) echo x86_64; exit 0 ;;
        ro.product.model) echo Fake_API_35; exit 0 ;;
        pm)
            if [ "${FAKE_TERMUX:-0}" = 1 ]; then
                echo 'package:com.termux'
            fi
            exit 0
            ;;
    esac
done
exit 0
"""

FAKE_PYTHON = """#!/bin/sh
for arg in "$@"; do
    case $arg in
        *android-e2e.py)
            echo 'SKIP: the fake python3 turned the instrumentation call into a skip'
            exit 77
            ;;
    esac
done
exec "${REAL_PYTHON}" "$@"
"""


def write_executable(path, text):
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


def fake_tools(directory, devices="", skip_e2e=False, termux=False):
    """A PATH with a fake adb and, optionally, a python that skips the e2e."""
    bin_dir = Path(directory) / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    write_executable(bin_dir / "adb", FAKE_ADB)
    if skip_e2e:
        write_executable(bin_dir / "python3", FAKE_PYTHON)
    env = os.environ.copy()
    env["PATH"] = str(bin_dir) + os.pathsep + env.get("PATH", "")
    env["FAKE_ADB_DEVICES"] = devices
    env["FAKE_TERMUX"] = "1" if termux else "0"
    env["REAL_PYTHON"] = sys.executable
    env["EMULATOR_E2E_CACHE"] = str(Path(directory) / "cache")
    return env


def run_wrapper(args, env, timeout=90):
    return subprocess.run(["bash", str(SCRIPT), *args], cwd=ROOT, env=env,
                          capture_output=True, text=True, timeout=timeout)


class ProbeTests(unittest.TestCase):
    def test_an_attached_emulator_is_selected(self):
        devices = ("List of devices attached\n"
                   "0123456789ABCDEF\tdevice\n"
                   "emulator-5554\tdevice\n")
        self.assertEqual("emulator-5554", probe.attached_emulator(devices))

    def test_a_physical_serial_does_not_satisfy_the_gate(self):
        with self.assertRaises(probe.ProbeError):
            probe.attached_emulator("List of devices attached\n0123\tdevice\n")

    def test_an_offline_emulator_is_not_attached(self):
        with self.assertRaises(probe.ProbeError):
            probe.attached_emulator(
                "List of devices attached\nemulator-5554\toffline\n")

    def release(self, digest="sha256:" + "a" * 64, arch="x86_64"):
        return {
            "assets": [
                {"name": "freebuff-native_1.1.0_aarch64.deb",
                 "browser_download_url": "https://example.invalid/arm.deb",
                 "digest": "sha256:" + "b" * 64},
                {"name": "freebuff-native_1.1.0_%s.deb" % arch,
                 "browser_download_url": "https://example.invalid/x86.deb",
                 "digest": digest},
                {"name": "freebuff-repo_all.deb",
                 "browser_download_url": "https://example.invalid/repo.deb",
                 "digest": "sha256:" + "c" * 64},
            ]
        }

    def test_the_x86_64_deb_is_selected_with_its_digest(self):
        name, url, sha256 = probe.deb_asset(self.release())
        self.assertEqual("freebuff-native_1.1.0_x86_64.deb", name)
        self.assertEqual("https://example.invalid/x86.deb", url)
        self.assertEqual("a" * 64, sha256)

    def test_a_deb_without_a_digest_is_refused(self):
        with self.assertRaises(probe.ProbeError) as caught:
            probe.deb_asset(self.release(digest=""))
        self.assertIn("sha256", str(caught.exception))

    def test_a_release_without_the_architecture_is_refused(self):
        with self.assertRaises(probe.ProbeError) as caught:
            probe.deb_asset(self.release(arch="arm64"))
        self.assertIn("x86_64", str(caught.exception))

    def test_two_x86_64_debs_are_ambiguous(self):
        release = self.release()
        release["assets"].append(release["assets"][1])
        with self.assertRaises(probe.ProbeError) as caught:
            probe.deb_asset(release)
        self.assertIn("more than one", str(caught.exception))

    def test_the_release_cli_prints_a_tab_separated_line(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "release.json"
            path.write_text(json.dumps(self.release()), encoding="utf-8")
            done = subprocess.run(
                [sys.executable, str(PROBE), "release", "--json", str(path),
                 "--arch", "x86_64"],
                capture_output=True, text=True, timeout=30)
        self.assertEqual(0, done.returncode, done.stderr)
        self.assertEqual(3, len(done.stdout.strip().split("\t")))

    def test_the_emulator_cli_reads_stdin(self):
        done = subprocess.run(
            [sys.executable, str(PROBE), "emulator", "--devices", "-"],
            input="List of devices attached\nemulator-5554\tdevice\n",
            capture_output=True, text=True, timeout=30)
        self.assertEqual(0, done.returncode, done.stderr)
        self.assertEqual("emulator-5554", done.stdout.strip())


class WrapperPreflightTests(unittest.TestCase):
    def test_syntax(self):
        done = subprocess.run(["bash", "-n", str(SCRIPT)],
                              capture_output=True, text=True)
        self.assertEqual(0, done.returncode, done.stderr)

    def test_no_attached_emulator_fails_the_preflight(self):
        with tempfile.TemporaryDirectory() as directory:
            env = fake_tools(directory, devices="")
            done = run_wrapper(["--preflight", "--out",
                                str(Path(directory) / "out")], env)
        self.assertNotEqual(0, done.returncode)
        self.assertIn("no attached emulator", done.stderr)
        self.assertNotIn("preflight ok", done.stdout)

    def test_a_physical_serial_does_not_pass_the_preflight(self):
        with tempfile.TemporaryDirectory() as directory:
            env = fake_tools(directory, devices="0123456789ABCDEF\tdevice")
            done = run_wrapper(["--preflight", "--out",
                                str(Path(directory) / "out")], env)
        self.assertNotEqual(0, done.returncode)
        self.assertIn("no attached emulator", done.stderr)

    def test_an_attached_emulator_passes_the_preflight(self):
        with tempfile.TemporaryDirectory() as directory:
            env = fake_tools(directory, devices="emulator-5554\tdevice")
            done = run_wrapper(["--preflight", "--out",
                                str(Path(directory) / "out")], env)
        self.assertEqual(0, done.returncode, done.stderr)
        self.assertIn("preflight ok: emulator-5554", done.stdout)

    def test_a_non_x86_64_emulator_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            bin_dir = Path(directory) / "bin"
            env = fake_tools(directory, devices="emulator-5554\tdevice")
            (bin_dir / "adb").write_text(
                FAKE_ADB.replace("echo x86_64", "echo arm64-v8a"),
                encoding="utf-8")
            (bin_dir / "adb").chmod(0o755)
            done = run_wrapper(["--preflight", "--out",
                                str(Path(directory) / "out")], env)
        self.assertNotEqual(0, done.returncode)
        self.assertIn("x86_64 compatibility coverage", done.stderr)

    def test_a_non_positive_native_timeout_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            env = fake_tools(directory)
            done = run_wrapper(["--native-timeout", "0"], env)
        self.assertNotEqual(0, done.returncode)
        self.assertIn("positive integer", done.stderr)


class WrapperExitHandlingTests(unittest.TestCase):
    def test_check_test_status_passes_zero(self):
        done = subprocess.run(
            ["bash", "-c", "source '%s'; check_test_status 0" % SCRIPT],
            capture_output=True, text=True, timeout=30)
        self.assertEqual(0, done.returncode, done.stderr)

    def test_check_test_status_turns_77_into_a_failure(self):
        done = subprocess.run(
            ["bash", "-c", "source '%s'; check_test_status 77" % SCRIPT],
            capture_output=True, text=True, timeout=30)
        self.assertNotEqual(0, done.returncode)
        self.assertIn("exit 77", done.stderr)
        self.assertIn("skip is a failure", done.stderr)

    def test_check_test_status_turns_any_failure_into_a_failure(self):
        done = subprocess.run(
            ["bash", "-c", "source '%s'; check_test_status 1" % SCRIPT],
            capture_output=True, text=True, timeout=30)
        self.assertNotEqual(0, done.returncode)
        self.assertIn("failed (exit 1)", done.stderr)

    def make_apks(self, directory):
        apk = Path(directory) / "app-debug.apk"
        test_apk = Path(directory) / "app-debug-androidTest.apk"
        apk.write_bytes(b"apk")
        test_apk.write_bytes(b"test-apk")
        return apk, test_apk

    def test_a_77_from_the_e2e_script_fails_the_wrapper(self):
        with tempfile.TemporaryDirectory() as directory:
            env = fake_tools(directory, devices="emulator-5554\tdevice",
                             skip_e2e=True)
            apk, test_apk = self.make_apks(directory)
            done = run_wrapper([
                "--no-build", "--no-provision",
                "--out", str(Path(directory) / "out"),
                "--apk", str(apk), "--test-apk", str(test_apk),
            ], env)
        self.assertNotEqual(0, done.returncode)
        self.assertIn("exit 77", done.stderr)
        self.assertIn("skip is a failure", done.stderr)

    def test_a_missing_termux_fails_the_wrapper(self):
        with tempfile.TemporaryDirectory() as directory:
            env = fake_tools(directory, devices="emulator-5554\tdevice",
                             termux=False)
            apk, test_apk = self.make_apks(directory)
            done = run_wrapper([
                "--no-build", "--no-provision",
                "--out", str(Path(directory) / "out"),
                "--apk", str(apk), "--test-apk", str(test_apk),
            ], env)
        self.assertNotEqual(0, done.returncode)
        self.assertIn("Termux is not installed", done.stdout)
        self.assertIn("--require-device", done.stdout)


class AndroidE2ESkipTests(unittest.TestCase):
    def test_the_ui_only_filter_names_the_two_native_free_methods(self):
        spec = importlib.util.spec_from_file_location("android_e2e", E2E)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertIn("SetupFlowTest#aMainScreenOffersTheThreeActions",
                      module.UI_ONLY_CLASSES)
        self.assertIn("SetupFlowTest#bConsentDialogStatesTheDownload",
                      module.UI_ONLY_CLASSES)
        self.assertNotIn("cCheckReportsThroughTermux", module.UI_ONLY_CLASSES)

    def test_without_require_device_a_missing_device_is_a_77(self):
        with tempfile.TemporaryDirectory() as directory:
            env = fake_tools(directory, devices="")
            done = subprocess.run([sys.executable, str(E2E)], cwd=ROOT, env=env,
                                  capture_output=True, text=True, timeout=60)
        self.assertEqual(77, done.returncode, done.stderr)
        self.assertIn("SKIP:", done.stdout)

    def test_require_device_turns_the_skip_into_a_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            env = fake_tools(directory, devices="")
            done = subprocess.run(
                [sys.executable, str(E2E), "--require-device"], cwd=ROOT,
                env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(1, done.returncode, done.stderr)
        self.assertIn("FAIL:", done.stdout)
        self.assertIn("--require-device", done.stdout)


if __name__ == "__main__":
    unittest.main()
