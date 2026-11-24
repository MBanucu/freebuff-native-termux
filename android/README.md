# freebuff-native for Android

A setup companion for the Termux package. F-Droid only carries APKs, so this is
the only shape an F-Droid listing can take: a small, dependency-free app that
detects Termux, explains the download, asks for consent, and hands one command
to Termux through `RUN_COMMAND`.

**Status: builds and runs.** CI compiles the APK and the test APK; the
instrumentation test has run on an aarch64 device against a real Termux, and the
screenshots in `fastlane/` come from that run. Post-merge CI also runs the UI,
consent and denied-permission tests on an API 35 x86_64 emulator and attempts
the native install check there. What remains before an F-Droid submission is a
tagged release and the `fdroiddata` merge request.

## What it does

- Detects whether Termux is installed (and says so, instead of failing later).
- Shows the full download budget before anything runs: the package (~30 KB),
  the glibc runtime (~400 MB installed), and the freebuff release (~136 MB).
- Sends this to Termux, only after the consent dialog:

  ```bash
  curl -fsSL https://mbanucu.github.io/freebuff-native-termux/install.sh | bash
  pkg install -y freebuff-native
  freebuff-native --download
  ```

- Reports the result of `freebuff-native --check` in the app.
- Explains Termux's `allow-external-apps` setting when Termux refuses a command,
  and copies the fix to the clipboard.

## What it deliberately does not do

- No bundled freebuff, no mirror, no re-hosted binary: the release is fetched
  from GitHub by the installer and verified against its published sha256.
- No `INTERNET` permission, so the app cannot phone home even by accident.
- No background services, no accounts, no analytics, no ads.
- No pretending to be a terminal: the real work happens in Termux, where the
  user can see it.

## Build

Versions live in `gradle/libs.versions.toml` (AGP 8.7.3, Gradle wrapper 8.9,
compileSdk 35). On Termux, the wrapper resolves the SDK and the bionic aapt2:

```bash
tools/termux-build.sh assembleDebug assembleDebugAndroidTest
```

Without the script, export the SDK yourself (or copy
`local.properties.example` to `local.properties`):

```bash
export ANDROID_HOME="$HOME/android-sdk"
cd android
./gradlew assembleDebug assembleDebugAndroidTest
```

The results are `app-debug.apk` and `app-debug-androidTest.apk`. The shipped app
has no library dependencies; the test APK carries the AndroidX test runner and
UI Automator, and nothing from it enters the app. See
`../docs/termux-build.md` for the toolchain decision and configuration-cache
measurements.

To install on a device:

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Then, in Termux, enable commands from other apps:

```bash
echo 'allow-external-apps=true' >> ~/.termux/termux.properties
termux-reload-settings
```

## End-to-end test

The test drives the app through accessibility on a real device, so it asserts
what a user would see:

```bash
python3 test/android-e2e.py --apk android/app/build/outputs/apk/debug/app-debug.apk \
    --test-apk android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk \
    --screenshots android/fastlane/metadata/android/en-US/images/phoneScreenshots
```

It installs both APKs, runs `SetupFlowTest` (buttons, consent dialog, a real
RUN_COMMAND round trip through Termux), then revokes the permission and runs
`DeniedPermissionTest` in a second pass, because revoking kills the app process
and the runner with it. Every wait is an accessibility event; the whole run takes
about 20 seconds, most of which is installing the APKs.

### Emulator coverage

`.github/workflows/emulator-e2e.yml` runs the same flow after a merge on an API
35 x86_64 AVD: a debuggable Termux with `allow-external-apps=true`, the x86_64
`freebuff-native` package, and `test/android-e2e.py --screenshots`. It is
**compatibility coverage, not the release gate**; the exact aarch64 device run
remains the verified target. The job fails on a missing emulator, a missing
Termux or exit 77, and records the native check as a follow-up when the 540 MB
download does not fit its budget.

## Layout

```
android/
├── app/src/main/AndroidManifest.xml     permission, Termux query, receiver
├── app/src/main/java/…/MainActivity.java    status, consent, RUN_COMMAND
├── app/src/main/java/…/RunCommandReceiver.java  reads Termux's result bundle
├── app/src/androidTest/java/…/SetupFlowTest.java  the end-to-end test
├── app/src/main/res/…                   strings, theme, vector icon
├── fastlane/metadata/android/en-US/     F-Droid listing text and changelog
├── gradle/libs.versions.toml            the only place AGP/SDK/version/test deps live
├── gradle/wrapper/                      Gradle 8.9 wrapper, pinned by sha256
├── local.properties.example             SDK location template (local.properties is gitignored)
└── app/build.gradle.kts                 reads the catalog, no runtime deps
```

## F-Droid submission checklist

1. ~~Build and run it on a device.~~ Done; the test APK and the screenshots are
   produced by `test/android-e2e.py`.
2. ~~Add screenshots.~~ Done — they are captured by the test, not mocked up.
3. Tag the release that contains this app and point `Update Check Mode` at tags.
4. Open a merge request against `fdroiddata` with `builds`/`srclibs` for this
   repo, `subdir=android`, and `gradle=yes`.
5. Expect the reviewer to ask why this is an app rather than a one-line script.
   The answer is in "What it does": consent, detection, a status report from the
   installer's own `--check`, and a recovery path when Termux blocks commands —
   none of which a script on a web page can do.
6. Point the reviewer at the precedent: Nix-on-Droid also downloads a runtime
   outside F-Droid, with explicit consent.

## License

MIT, same as the rest of the repository. See `../LICENSE`.
