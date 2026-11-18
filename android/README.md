# freebuff-native for Android

A setup companion for the Termux package. F-Droid only carries APKs, so this is
the only shape an F-Droid listing can take: a small, dependency-free app that
detects Termux, explains the download, asks for consent, and hands one command
to Termux through `RUN_COMMAND`.

**Status: scaffold.** It has not been compiled yet — there is no Android SDK in
the environment where it was written. Do not submit it to F-Droid until it
builds and runs on a device. `bash test/android-test.sh` covers what can be
checked without a build (manifest, resources, metadata, consistency).

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

Requirements: JDK 17 and an Android SDK with platform 35 and build-tools 35.

```bash
cd android
gradle wrapper --gradle-version 8.9   # once; the wrapper jar is not committed
./gradlew assembleDebug                # app/build/outputs/apk/debug/
```

The result is `app/build/outputs/apk/debug/app-debug.apk`. There are no library
dependencies, so the SDK and the Android Gradle Plugin are the only downloads.

To install on a device:

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Then, in Termux, enable commands from other apps:

```bash
echo 'allow-external-apps=true' >> ~/.termux/termux.properties
termux-reload-settings
```

## Layout

```
android/
├── app/src/main/AndroidManifest.xml     permission, Termux query, receiver
├── app/src/main/java/…/MainActivity.java    status, consent, RUN_COMMAND
├── app/src/main/java/…/RunCommandReceiver.java  reads Termux's result bundle
├── app/src/main/res/…                   strings, theme, vector icon
├── fastlane/metadata/android/en-US/     F-Droid listing text and changelog
└── app/build.gradle.kts                 versionCode/versionName, no deps
```

## F-Droid submission checklist

1. Build and run it on a device; fix what the compiler catches.
2. Add screenshots to `fastlane/metadata/android/en-US/images/phoneScreenshots/`
   (F-Droid shows them; keep them honest — real UI, no mockups with fake data).
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
