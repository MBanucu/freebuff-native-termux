#!/usr/bin/env bash
#
# First-run build entry point for Termux.
#
# Resolves the Android SDK ($ANDROID_HOME, $ANDROID_SDK_ROOT, or the Termux
# default $HOME/android-sdk), exports it for Gradle, points AGP at Termux's
# bionic aapt2 when the Maven one cannot run, and then runs the wrapper.
#
# Usage:
#   tools/termux-build.sh                       # assembleDebug
#   tools/termux-build.sh assembleDebugAndroidTest
#   tools/termux-build.sh --offline --console=plain assembleDebug
#   tools/termux-build.sh --check               # print the resolved env only
#
# Nothing here writes local.properties: the SDK is exported for this process,
# so a clean checkout needs no manual edit.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
android=$root/android

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

if [[ -n "${ANDROID_HOME:-}" ]]; then
    sdk=$ANDROID_HOME
elif [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then
    sdk=$ANDROID_SDK_ROOT
elif [[ -d "$HOME/android-sdk" ]]; then
    sdk=$HOME/android-sdk
else
    die "no Android SDK found. Export ANDROID_HOME (Termux users usually have it at $HOME/android-sdk) or install cmdline-tools and run: sdkmanager 'platforms;android-35'"
fi

[[ -d "$sdk" ]] || die "ANDROID_HOME points at '$sdk', which is not a directory"
[[ -d "$sdk/platforms" ]] || die "'$sdk' has no platforms/ directory; install a platform with: sdkmanager 'platforms;android-35'"
[[ -d "$sdk/build-tools" ]] || die "'$sdk' has no build-tools/ directory; install build tools with: sdkmanager 'build-tools;35.0.0'"

export ANDROID_HOME=$sdk
export ANDROID_SDK_ROOT=$sdk

if [[ "${1:-}" == --check ]]; then
    printf 'ANDROID_HOME=%s\n' "$sdk"
    printf 'aapt2=%s\n' "${PREFIX:+$PREFIX/bin/aapt2}"
    exit 0
fi

args=("$@")
if [[ ${#args[@]} -eq 0 ]]; then
    args=(assembleDebug)
fi

# AGP downloads a glibc aapt2 that cannot execute on bionic.  Termux ships a
# compatible one in $PREFIX/bin; prefer it unless the user already configured
# an override in ~/.gradle/gradle.properties or on the command line.
if [[ -n "${PREFIX:-}" && -x "$PREFIX/bin/aapt2" ]] \
    && ! grep -qs '^android\.aapt2FromMavenOverride=' "$HOME/.gradle/gradle.properties" 2>/dev/null \
    && [[ " ${args[*]} " != *android.aapt2FromMavenOverride* ]]; then
    args+=("-Pandroid.aapt2FromMavenOverride=$PREFIX/bin/aapt2")
fi

printf 'Using Android SDK %s\n' "$sdk" >&2
cd "$android"
# -Dandroid.home is AGP's documented system property.  Pass it explicitly so a
# reused Gradle daemon cannot hide the environment this script just resolved.
exec ./gradlew --console=plain "-Dandroid.home=$sdk" "${args[@]}"
