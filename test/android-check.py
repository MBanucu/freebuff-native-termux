#!/usr/bin/env python3
"""Static checks for the Android scaffold.

Prints one tab-separated line per check: "ok<TAB>message" or
"fail<TAB>message<TAB>detail", and exits nonzero if anything failed.

Nothing here needs an Android SDK; it catches the mistakes that are visible
without compiling: a manifest without the RUN_COMMAND permission, a string the
code uses but the resources lack, metadata that F-Droid would reject, and a
package name that does not match its directory.
"""

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ANDROID = ROOT / "android"
APP = ANDROID / "app" / "src" / "main"
NS = "{http://schemas.android.com/apk/res/android}"
JAVA = APP / "java" / "io" / "github" / "mbanucu" / "freebuffnative"
FASTLANE = ANDROID / "fastlane" / "metadata" / "android" / "en-US"

failed = 0


def check(condition, message, detail=""):
    global failed
    if condition:
        print("ok\t" + message)
    else:
        failed += 1
        print("fail\t" + message + "\t" + str(detail))


def read(path):
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        return ""


def parse(path):
    try:
        return ET.parse(path).getroot()
    except (OSError, ET.ParseError) as error:
        check(False, "parses: " + path.name, error)
        return None


# --- files -------------------------------------------------------------------

expected = [
    ANDROID / "settings.gradle.kts",
    ANDROID / "build.gradle.kts",
    ANDROID / "gradle.properties",
    ANDROID / "gradle" / "wrapper" / "gradle-wrapper.properties",
    ANDROID / "gradle" / "libs.versions.toml",
    ANDROID / "local.properties.example",
    ANDROID / "app" / "build.gradle.kts",
    APP / "AndroidManifest.xml",
    APP / "res" / "values" / "strings.xml",
    APP / "res" / "values" / "themes.xml",
    APP / "res" / "drawable" / "ic_launcher.xml",
    JAVA / "MainActivity.java",
    JAVA / "RunCommandReceiver.java",
    FASTLANE / "title.txt",
    FASTLANE / "short_description.txt",
    FASTLANE / "full_description.txt",
]
missing = [str(path.relative_to(ROOT)) for path in expected if not path.is_file()]
check(not missing, "every scaffold file exists", ", ".join(missing))

for path in sorted((APP / "res").rglob("*.xml")):
    parse(path)

manifest = parse(APP / "AndroidManifest.xml")
if manifest is not None:
    permissions = [p.get(NS + "name") for p in manifest.findall("uses-permission")]
    check("com.termux.permission.RUN_COMMAND" in permissions,
          "the manifest asks for Termux's RUN_COMMAND permission", permissions)
    check("android.permission.INTERNET" not in permissions,
          "the manifest asks for no internet permission", permissions)

    queries = manifest.find("queries")
    packages = [] if queries is None else [
        q.get(NS + "name") for q in queries.findall("package")]
    check("com.termux" in packages,
          "the manifest can see the Termux package on Android 11+", packages)

    application = manifest.find("application")
    check(application is not None, "the manifest has an application")
    if application is not None:
        check(application.get(NS + "allowBackup") == "false",
              "backup is disabled",
              application.get(NS + "allowBackup"))

        activity = application.find("activity")
        check(activity is not None and activity.get(NS + "exported") == "true",
              "the activity is exported",
              None if activity is None else activity.get(NS + "exported"))
        check(activity is not None
              and activity.get(NS + "name") == ".MainActivity"
              and (JAVA / "MainActivity.java").is_file(),
              "the launcher activity resolves to MainActivity")

        receiver = application.find("receiver")
        check(receiver is not None
              and receiver.get(NS + "exported") == "false"
              and receiver.get(NS + "name") == ".RunCommandReceiver",
              "the result receiver is internal",
              None if receiver is None else receiver.attrib)

        launcher = application.find("activity/intent-filter/category")
        check(launcher is not None
              and launcher.get(NS + "name") == "android.intent.category.LAUNCHER",
              "the activity has a launcher category")

# --- gradle ------------------------------------------------------------------

gradle = read(ANDROID / "app" / "build.gradle.kts")
catalog = read(ANDROID / "gradle" / "libs.versions.toml")
package = re.search(r'namespace\s*=\s*"([^"]+)"', gradle)


def catalog_version(name):
    match = re.search(
        r"^" + re.escape(name) + r'\s*=\s*"([^"]+)"', catalog, re.MULTILINE)
    return match.group(1) if match else None


app_id = re.search(r'applicationId\s*=\s*"([^"]+)"', gradle)
check(package is not None and package.group(1) == "io.github.mbanucu.freebuffnative",
      "the namespace is the app id's package",
      None if package is None else package.group(1))
check(app_id is not None and package is not None
      and app_id.group(1) == package.group(1),
      "the application id matches the namespace",
      None if app_id is None else app_id.group(1))

code = catalog_version("appVersionCode")
version = catalog_version("appVersionName")
check(catalog.strip() != "", "the version catalog exists")
check(code is not None, "the catalog sets a versionCode", code)
check(version is not None, "the catalog sets a versionName", version)

sdk = catalog_version("compileSdk")
target = catalog_version("targetSdk")
check(sdk is not None and sdk.isdigit() and int(sdk) >= 34,
      "compileSdk is current enough for F-Droid", sdk)
check(target is not None and target.isdigit() and int(target) >= 34,
      "targetSdk is current enough for F-Droid", target)

check('id = "com.android.application"' in catalog
      and 'version.ref = "agp"' in catalog,
      "the catalog exposes the Android plugin alias")
check("alias(libs.plugins.android.application)" in gradle,
      "the app applies the plugin through the catalog")
for module in ("androidx.test:runner", "androidx.test:rules",
               "androidx.test.ext:junit", "androidx.test.uiautomator:uiautomator"):
    check(module in catalog, "the catalog pins " + module)

wrapper = read(ANDROID / "gradle" / "wrapper" / "gradle-wrapper.properties")
check(re.search(r"^distributionSha256Sum=[0-9a-f]{64}$", wrapper,
                re.MULTILINE) is not None,
      "the wrapper pins the distribution checksum")
workflow = read(ROOT / ".github" / "workflows" / "android.yml")
check("gradle-version: '8.9'" not in workflow,
      "CI does not hard-code the wrapper version")
check("gradle-version:" not in workflow,
      "CI follows the wrapper version")
check("gradle/actions/wrapper-validation@" in workflow,
      "CI validates the committed wrapper jar")

check(not re.search(r"(?<!androidTest)\bimplementation\s*\(", gradle),
      "the app has no library dependencies", "found an implementation() line")
runtime = [line.strip() for line in gradle.splitlines()
           if re.match(r"\s*(implementation|api)\s*\(", line)]
check(not runtime, "nothing is added to the shipped APK", ", ".join(runtime))
check("androidTestImplementation" in gradle,
      "the end-to-end test is a test-only dependency")
check('testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"' in gradle,
      "the runner is configured for instrumentation")
check((ANDROID / "app" / "src" / "androidTest" / "java" / "io" / "github" /
       "mbanucu" / "freebuffnative" / "SetupFlowTest.java").is_file(),
      "the end-to-end test source exists")

if code is not None:
    changelog = FASTLANE / "changelogs" / (code + ".txt")
    check(changelog.is_file(),
          "a changelog exists for versionCode " + code,
          str(changelog.relative_to(ROOT)))

# --- resources ---------------------------------------------------------------

strings_root = parse(APP / "res" / "values" / "strings.xml")
strings = {}
if strings_root is not None:
    for item in strings_root.findall("string"):
        strings[item.get("name")] = (item.text or "")

sources = [read(path) for path in sorted(JAVA.glob("*.java"))]
used = set()
for source in sources:
    used.update(re.findall(r"R\.string\.(\w+)", source))
unknown = sorted(used - set(strings))
check(not unknown, "every string the code uses is defined", ", ".join(unknown))

empty = sorted(name for name, text in strings.items() if not text.strip())
check(not empty, "no string is empty", ", ".join(empty))

for name in ("app_name", "consent_message", "permission_message"):
    check(name in strings, "the resource defines " + name + "", "")

# --- java --------------------------------------------------------------------

for path in sorted(JAVA.glob("*.java")):
    source = read(path)
    declared = re.search(r"^package\s+([\w.]+);", source, re.MULTILINE)
    check(declared is not None and declared.group(1) == "io.github.mbanucu.freebuffnative",
          path.name + " declares the app package",
          None if declared is None else declared.group(1))
    check(source.count("{") == source.count("}"),
          path.name + " has balanced braces",
          "%d vs %d" % (source.count("{"), source.count("}")))
    check(len(source) > 0, path.name + " is not empty")

runner = read(JAVA / "MainActivity.java")
check("com.termux.permission.RUN_COMMAND" in runner or "RUN_COMMAND" in runner,
      "the activity sends RUN_COMMAND to Termux")
check("com.termux.RUN_COMMAND_PATH" in runner
      and "com.termux.RUN_COMMAND_PENDING_INTENT" in runner,
      "the intent carries the Termux extras")
check("freebuff-native --download" in runner,
      "setup uses the documented installer entry point")
check("https://mbanucu.github.io/freebuff-native-termux/install.sh" in runner,
      "setup uses the published repository")

# --- fdroiddata --------------------------------------------------------------

fdroid = read(ROOT / "fdroiddata" / "io.github.mbanucu.freebuffnative.yml")
check(fdroid.strip() != "", "the fdroiddata metadata exists")
for key in ("Categories:", "License: MIT", "SourceCode:", "RepoType: git",
            "Repo: https://github.com/MBanucu/freebuff-native-termux.git",
            "Builds:", "subdir: android", "AutoUpdateMode:",
            "UpdateCheckMode:", "MaintainerNotes:"):
    check(key in fdroid, "the metadata sets " + key.rstrip(":"))

# fdroiddata's tooling moves Summary out of the YAML; an AGP multi-module build
# needs an explicit output glob.
check(re.search(r"^Summary:", fdroid, re.MULTILINE) is None,
      "the summary is not duplicated in the metadata")
check("output: app/build/outputs/apk/release/*.apk" in fdroid,
      "the build points at the app module's apk")
summary = ROOT / "fdroiddata" / "io.github.mbanucu.freebuffnative" / "en-US" / "summary.txt"
check(summary.is_file(), "the localized summary exists")
check(summary.is_file()
      and summary.read_text().strip() == read(FASTLANE / "short_description.txt").strip(),
      "the localized summary matches the fastlane short description")
check("gradle:\n      - yes" in fdroid, "the build uses gradle")

if code is not None:
    check("versionCode: " + code in fdroid,
          "the metadata builds versionCode " + code)
if version is not None:
    check("versionName: " + version in fdroid,
          "the metadata builds versionName " + version)
    check("commit: android-v" + version in fdroid,
          "the metadata points at the app tag", "commit: android-v" + version)

# --- fastlane ----------------------------------------------------------------

title = read(FASTLANE / "title.txt").strip()
short = read(FASTLANE / "short_description.txt").strip()
full = read(FASTLANE / "full_description.txt").strip()

check(0 < len(title) <= 30, "the F-Droid title fits 30 characters", len(title))
check(0 < len(short) <= 80, "the short description fits 80 characters", len(short))
check(200 < len(full) <= 4000, "the full description fits 4000 characters", len(full))
check(title == strings.get("app_name", ""),
      "the listing title matches the app name", title)
check("MIT" in full and "Apache-2.0" in full,
      "the description states the licenses")

sys.exit(1 if failed else 0)
