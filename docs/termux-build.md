# Building the Android app on Termux

The setup app in `android/` builds on this phone with the JDK and the Android
SDK that are already installed; the only trap is that Gradle cannot see the SDK
and the Maven `aapt2` is a glibc binary that cannot run on bionic.

## One command

```bash
# From the repository root:
tools/termux-build.sh                       # assembleDebug
tools/termux-build.sh --offline assembleDebug assembleDebugAndroidTest
tools/termux-build.sh --check               # show the resolved SDK/aapt2
```

The script:

1. uses `$ANDROID_HOME`, then `$ANDROID_SDK_ROOT`, then the Termux default
   `$HOME/android-sdk`;
2. exports `ANDROID_HOME` and validates that `platforms/` and `build-tools/`
   exist;
3. passes `-Pandroid.aapt2FromMavenOverride=$PREFIX/bin/aapt2` when the Termux
   aapt2 is available and no override is configured in
   `~/.gradle/gradle.properties`;
4. passes `-Dandroid.home` (AGP's documented system property) and runs
   `android/gradlew` with the arguments you gave, defaulting to
   `assembleDebug`.

The explicit `-Dandroid.home` also survives a Gradle daemon that was started
earlier without `ANDROID_HOME`; Gradle does not refresh a reused daemon's
environment. It never writes `local.properties`, so a clean checkout stays
clean.

## Building without the script

```bash
export ANDROID_HOME="$HOME/android-sdk"
cd android
./gradlew --offline assembleDebug
```

`-Dandroid.home="$HOME/android-sdk"` is an equivalent AGP system property and is
what `tools/termux-build.sh` passes, so a reused daemon cannot hide it.

If neither `ANDROID_HOME`/`ANDROID_SDK_ROOT` nor `sdk.dir` is set, the build now
stops during settings evaluation with one message:

```
Android SDK not found: set ANDROID_HOME, or sdk.dir in android/local.properties.

On Termux, use the documented wrapper (it finds $HOME/android-sdk and
the bionic aapt2 for you):

    tools/termux-build.sh assembleDebug
...
```

For an IDE or a local file, copy `android/local.properties.example` to
`android/local.properties` and set `sdk.dir`. `local.properties` is gitignored.

## Requirements

- JDK 21 (Termux's `openjdk-21`); the app targets Java 17 bytecode.
- Android SDK with `platforms/android-35` and `build-tools/35.0.0` (the wrapper
  and CI use the same levels).
- Network on the first run, or an already populated `~/.gradle` cache for
  `--offline`.

## Toolchain decision: stay on AGP 8.7.3 / Gradle 8.9

The issue allowed moving to AGP 9.5.2 / Gradle 9.9.2. That upgrade is
**deferred**, deliberately:

- A scratch copy was tried offline on 2026-11-24: AGP 9.5.2 on the cached
  Gradle 9.9.2 distribution produced `BUILD SUCCESSFUL in 1m 16s` with
  `compileSdk 35`, so the phone can run it. But it also needs SDK Build Tools
  36.0.0, and F-Droid's buildserver availability has not been verified. Changing
  the app metadata without that verification risks the listing.
- AGP 9.5.2 emits `Configuration.setVisible`/Gradle-10 deprecation warnings;
  the current 8.7.3 line builds with none.
- AGP 9 also changes the plugin/Kotlin baseline. The app is dependency-free
  Java, so the upgrade buys nothing here.
- The 8.9 wrapper distribution is cached on this phone, so offline builds work
  today; the 8.9 wrapper checksum below is verified.

The alternative remains a single follow-up: bump `agp` in
`android/gradle/libs.versions.toml`, the wrapper URL/checksum, and the fdroiddata
merge-request text together, after a successful `fdroid build` with Build Tools
36.0.0.

## Wrapper integrity

`android/gradle/wrapper/gradle-wrapper.properties` now pins:

```
distributionUrl=https\://services.gradle.org/distributions/gradle-8.9-bin.zip
distributionSha256Sum=d725d707bfabd4dfdc958c624003b3c80accc03f7037b5122c4b1d0ef15cecab
```

That is the checksum published at
<https://services.gradle.org/distributions/gradle-8.9-bin.zip.sha256> and it was
re-computed locally against the downloaded archive. CI runs
`gradle/actions/wrapper-validation@v4`, and `setup-gradle` has no
`gradle-version` input, so it uses the committed wrapper rather than a
hard-coded version.

## Dependency boundary

All versions are pinned exactly in `android/gradle/libs.versions.toml`: AGP,
`compileSdk`/`minSdk`/`targetSdk`, `versionCode`/`versionName`, and the four
`androidx.test` artifacts (`runner`, `rules`, `ext:junit`, `uiautomator`). The
app APK itself has no dependencies; those four are `androidTestImplementation`
only.

Dependency verification metadata is **not** committed. Generating it on Termux
records the aarch64 `aapt2` and AGP build-tool artifacts, but F-Droid's x86_64
buildserver resolves different platform classifiers; a global
`verification-metadata.xml` would make an otherwise-valid F-Droid build fail
with a checksum error. Locking every AGP configuration has the same
platform/configuration risk. The chosen boundary is exact catalog versions with
one place to review, plus the locked Gradle distribution; a
`--write-verification-metadata` run can still be used locally when auditing a
specific dependency update:

```bash
cd android
./gradlew --write-verification-metadata sha256 assembleDebugAndroidTest
```

## Configuration cache and deprecations

`org.gradle.configuration-cache=true` is enabled in `android/gradle.properties`.

Measured on this phone (Termux aarch64, Android 15, JDK 21):

| run | command | result |
| --- | --- | --- |
| cold, no cache entry, fresh daemon | `tools/termux-build.sh --offline assembleDebug assembleDebugAndroidTest` | `BUILD SUCCESSFUL in 22s`, 58 tasks up-to-date, cache entry stored, 23s wall |
| warm, cache reused | same command | `BUILD SUCCESSFUL in 1s`, 58 tasks up-to-date, cache entry reused, 1.8s wall |

The first full compile on this host (no `build/` output either) took 44s.

`--warning-mode all` reports no project-owned Gradle 10 deprecations. The one
warning is AGP's own `android.aapt2FromMavenOverride is experimental`, which is
the documented Termux workaround and is owned by the user-level
`~/.gradle/gradle.properties` (or by the script's `-P` flag), not by this
project.

## What is still missing

- A self-hosted Termux runner in CI. The ubuntu job can compile the app, but it
  cannot reproduce the bionic `aapt2`/first-run SDK path. `tools/termux-build.sh`
  is the documented smoke build for now.
- The AGP 9.5 / Gradle 9.9.2 evaluation, pending a verified F-Droid build with
  Build Tools 36.0.0.
