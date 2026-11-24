#!/usr/bin/env bash
# Post-merge end-to-end test for the Android setup app on a hosted emulator.
#
# The emulator-e2e workflow runs this inside a fresh API 35 google_apis x86_64
# AVD.  It is also a plain shell script, so the same sequence can be run by hand
# against an attached emulator:
#
#   bash ci/emulator-e2e.sh --preflight       # only the fail-closed device check
#   bash ci/emulator-e2e.sh                   # full run (installs Termux + package)
#   bash ci/emulator-e2e.sh --skip-native-check
#
# This is x86_64 compatibility coverage, not the verified target: the release
# gate remains the self-hosted aarch64 device run.  A missing emulator, a
# missing Termux, a failed native install or test/android-e2e.py exit 77 fails
# the run.  The 540 MB native install has a bounded budget; if it exceeds that
# budget the UI/consent/denied classes still run and the native check is
# recorded as an explicit follow-up in native-check.txt, never as a pass.
#
# Artifacts (logs, instrumentation output, screenshots) are written under
# $EMULATOR_OUT (default: out/emulator) and uploaded by the workflow on failure.

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${EMULATOR_OUT:-$ROOT/out/emulator}"
CACHE="${EMULATOR_E2E_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/freebuff-native-e2e}"

# Pinned Termux debug build: run-as needs a debuggable package, and the
# universal APK carries the x86_64 bootstrap this AVD needs.
TERMUX_VERSION="v0.118.3"
TERMUX_APK_NAME="termux-app_${TERMUX_VERSION}+github-debug_universal.apk"
TERMUX_APK_URL="https://github.com/termux/termux-app/releases/download/${TERMUX_VERSION}/${TERMUX_APK_NAME}"
TERMUX_APK_SHA256="7600078440c3c34ef050bc009b00fc3215cb87ec4a449e01a696f74cf4249db2"
TERMUX_APK="$CACHE/$TERMUX_APK_NAME"

PACKAGE="io.github.mbanucu.freebuffnative"
TEST_PACKAGE="$PACKAGE.test"
PERMISSION="com.termux.permission.RUN_COMMAND"
TERMUX_PACKAGE="com.termux"
TERMUX_PREFIX="/data/data/com.termux/files/usr"
TERMUX_HOME="/data/data/com.termux/files/home"

API_LEVEL="35"
DEVICE_ABI="x86_64"
NATIVE_TIMEOUT_DEFAULT=720

APK_DEFAULT="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
TEST_APK_DEFAULT="$ROOT/android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"

MODE=run
BUILD=1
PROVISION=1
NATIVE=1
SERIAL_ARG=""
APK="$APK_DEFAULT"
TEST_APK="$TEST_APK_DEFAULT"
NATIVE_TIMEOUT="$NATIVE_TIMEOUT_DEFAULT"

SERIAL=""
API=""
ABI=""
TERMUX_COMPONENT=""
DEB=""
NATIVE_READY=0
NATIVE_REASON=""

usage() {
    cat <<'EOF'
Usage: bash ci/emulator-e2e.sh [options]

  --preflight             check for an attached emulator and exit
  --serial SERIAL         use this emulator instead of the first one
  --out DIR               artifact directory (default: out/emulator)
  --apk PATH              app APK (default: the Gradle build output)
  --test-apk PATH         androidTest APK (default: the Gradle build output)
  --skip-native-check     do not install freebuff-native; run UI/consent/denied
                          tests and record the native check as a follow-up
  --no-build              use the APKs already on disk
  --no-provision          do not install Termux, the package or the app
  --native-timeout SEC    budget for the native install (default: 720)
  -h, --help              print this help

Exit status: 0 only when the emulator gate and the selected instrumentation
tests pass.  A skip (including test/android-e2e.py exit 77) is a failure.
EOF
}

die() {
    printf 'emulator e2e: %s\n' "$*" >&2
    exit 1
}

log() {
    printf 'emulator e2e: %s\n' "$*" | tee -a "$OUT/run.log"
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is not in PATH${2:+; $2}"
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        python3 - "$1" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb") as handle:
    for chunk in iter(lambda: handle.read(1 << 20), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
    fi
}

fetch() { # url destination [sha256]
    local url=$1 dest=$2 want=${3:-} got
    mkdir -p "${dest%/*}"
    if [ -s "$dest" ]; then
        if [ -z "$want" ] || [ "$(sha256_file "$dest")" = "$want" ]; then
            log "using cached ${dest##*/}"
            return 0
        fi
        log "discarding a cached ${dest##*/} whose sha256 does not match"
        rm -f "$dest"
    fi
    log "downloading $url"
    if ! curl -fL --retry 3 --connect-timeout 20 -o "$dest.part" "$url"; then
        log "download failed: $url"
        rm -f "$dest.part"
        return 1
    fi
    mv "$dest.part" "$dest"
    if [ -n "$want" ]; then
        if ! got=$(sha256_file "$dest"); then
            log "cannot compute sha256 for $dest"
            rm -f "$dest"
            return 1
        fi
        if [ "$got" != "$want" ]; then
            log "sha256 mismatch for $url (expected $want, got $got)"
            rm -f "$dest"
            return 1
        fi
    fi
    return 0
}

check_test_status() { # exit status from test/android-e2e.py
    local status=$1
    case $status in
        0) ;;
        77) die "test/android-e2e.py skipped (exit 77); in post-merge CI a skip is a failure" ;;
        *) die "test/android-e2e.py failed (exit $status)" ;;
    esac
}

preflight() {
    need adb
    need python3

    local devices
    devices=$(adb devices) || die "adb devices failed"
    printf '%s\n' "$devices" > "$OUT/adb-devices.txt"

    if [ -n "$SERIAL_ARG" ]; then
        case $SERIAL_ARG in
            emulator-*) ;;
            *) die "serial '$SERIAL_ARG' is not an emulator-* serial" ;;
        esac
        printf '%s\n' "$devices" | awk -v s="$SERIAL_ARG" \
            '$1 == s && $2 == "device" { found = 1 } END { exit !found }' \
            || die "emulator $SERIAL_ARG is not attached in the device state"
        SERIAL=$SERIAL_ARG
    else
        SERIAL=$(printf '%s\n' "$devices" \
            | python3 "$ROOT/ci/emulator_probe.py" emulator --devices -) \
            || die "no attached emulator-* in the adb device state; a missing emulator fails the run"
    fi
    log "attached $SERIAL"

    API=$(adb -s "$SERIAL" shell getprop ro.build.version.sdk | tr -d '\r') \
        || die "could not read the emulator's API level"
    ABI=$(adb -s "$SERIAL" shell getprop ro.product.cpu.abi | tr -d '\r') \
        || die "could not read the emulator's CPU ABI"
    [ "$API" = "$API_LEVEL" ] \
        || die "emulator is API '${API:-unknown}', not API $API_LEVEL"
    [ "$ABI" = "$DEVICE_ABI" ] \
        || die "emulator is '${ABI:-unknown}', not $DEVICE_ABI; this job is x86_64 compatibility coverage"

    {
        printf 'serial=%s\napi=%s\nabi=%s\n' "$SERIAL" "$API" "$ABI"
        adb -s "$SERIAL" shell getprop ro.product.model | tr -d '\r' | sed 's/^/model=/'
    } > "$OUT/device.txt" 2>&1
}

build_app() {
    log "building assembleDebug and assembleDebugAndroidTest"
    local status
    set +e
    ( cd "$ROOT" && bash tools/termux-build.sh --no-daemon --console=plain \
        assembleDebug assembleDebugAndroidTest ) 2>&1 | tee "$OUT/build.txt"
    status=${PIPESTATUS[0]}
    set -e
    [ "$status" -eq 0 ] || die "the Gradle build failed (exit $status); see $OUT/build.txt"
}

verify_apks() {
    [ -s "$APK" ] || die "missing $APK (build it or pass --apk)"
    [ -s "$TEST_APK" ] || die "missing $TEST_APK (build it or pass --test-apk)"
}

termux_component() {
    local component
    component=$(adb -s "$SERIAL" shell cmd package resolve-activity --brief \
        "$TERMUX_PACKAGE" | tr -d '\r' | tail -n 1) \
        || die "could not ask the emulator for Termux's launcher activity"
    case $component in
        */*) printf '%s\n' "$component" ;;
        *) die "could not resolve Termux's launcher activity (got '${component:-nothing}')" ;;
    esac
}

wait_for_termux() {
    local i
    for ((i = 0; i < 120; i++)); do
        if adb -s "$SERIAL" shell \
                "run-as $TERMUX_PACKAGE sh -c 'test -x $TERMUX_PREFIX/bin/bash'" \
                >/dev/null 2>&1; then
            log "the Termux bootstrap is ready"
            return 0
        fi
        sleep 2
    done
    die "Termux did not finish its bootstrap within 240 s"
}

start_termux() {
    TERMUX_COMPONENT=$(termux_component)
    log "starting Termux ($TERMUX_COMPONENT) to install its bootstrap"
    adb -s "$SERIAL" shell am start -W -n "$TERMUX_COMPONENT" \
        > "$OUT/termux-start.txt" 2>&1 \
        || { cat "$OUT/termux-start.txt" >&2; die "could not start Termux"; }
    wait_for_termux
}

push_termux_file() { # local remote
    local local_file=$1 remote=$2 expected actual
    expected=$(sha256_file "$local_file") || die "cannot hash $local_file"
    adb -s "$SERIAL" exec-in run-as "$TERMUX_PACKAGE" sh -c "cat > $remote" \
        < "$local_file" \
        || die "could not copy $local_file to Termux:$remote"
    if ! actual=$(adb -s "$SERIAL" shell run-as "$TERMUX_PACKAGE" \
            /system/bin/env "LD_LIBRARY_PATH=$TERMUX_PREFIX/lib" \
            "$TERMUX_PREFIX/bin/sha256sum" "$remote" \
            | awk '{print $1}' | tr -d '\r'); then
        die "could not hash Termux:$remote"
    fi
    [ "$actual" = "$expected" ] \
        || die "Termux:$remote sha256 is '${actual:-missing}', expected $expected"
}

provision_termux() {
    fetch "$TERMUX_APK_URL" "$TERMUX_APK" "$TERMUX_APK_SHA256" \
        || die "could not fetch the debuggable Termux APK"

    # A dirty emulator can carry an older Termux with another signature.  The
    # suite needs a first run anyway, so remove it and start clean.
    adb -s "$SERIAL" uninstall "$TERMUX_PACKAGE" >/dev/null 2>&1 || true

    log "installing the debuggable Termux universal APK"
    adb -s "$SERIAL" install "$TERMUX_APK" > "$OUT/termux-install.txt" 2>&1 \
        || { cat "$OUT/termux-install.txt" >&2; die "adb install of Termux failed"; }
    grep -q '^Success' "$OUT/termux-install.txt" \
        || { cat "$OUT/termux-install.txt" >&2; die "adb install of Termux did not report Success"; }

    adb -s "$SERIAL" shell "run-as $TERMUX_PACKAGE sh -c true" >/dev/null 2>&1 \
        || die "Termux is not debuggable (run-as failed); the github-debug universal APK is required"

    start_termux

    log "enabling allow-external-apps in Termux"
    printf 'allow-external-apps=true\n' \
        | adb -s "$SERIAL" exec-in run-as "$TERMUX_PACKAGE" sh -c \
            "mkdir -p $TERMUX_HOME/.termux && cat > $TERMUX_HOME/.termux/termux.properties" \
        || die "could not write Termux's termux.properties"
    adb -s "$SERIAL" shell run-as "$TERMUX_PACKAGE" cat \
        "$TERMUX_HOME/.termux/termux.properties" \
        | tr -d '\r' > "$OUT/termux-properties.txt" 2>&1 \
        || die "could not read Termux's termux.properties"
    grep -qx 'allow-external-apps=true' "$OUT/termux-properties.txt" \
        || die "Termux's termux.properties does not contain allow-external-apps=true"

    # Termux reads its properties at startup; restart it after writing them.
    adb -s "$SERIAL" shell am force-stop "$TERMUX_PACKAGE" >/dev/null 2>&1 || true
    sleep 1
    adb -s "$SERIAL" shell am start -W -n "$TERMUX_COMPONENT" >/dev/null 2>&1 \
        || die "could not restart Termux after writing termux.properties"
}

download_native_deb() {
    local api="https://api.github.com/repos/MBanucu/freebuff-native-termux/releases/latest"
    local json="$OUT/release.json" line
    local -a headers=(-H 'Accept: application/vnd.github+json')
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    if ! curl -fsSL "${headers[@]}" "$api" -o "$json"; then
        log "the GitHub release API is unavailable; falling back to the documented APT installer"
        return 1
    fi
    if ! line=$(python3 "$ROOT/ci/emulator_probe.py" release --json "$json" \
            --arch "$DEVICE_ABI"); then
        log "the latest release has no usable $DEVICE_ABI .deb; falling back to the documented APT installer"
        return 1
    fi
    local name url sha256
    IFS=$'\t' read -r name url sha256 <<<"$line"
    DEB="$CACHE/$name"
    if ! fetch "$url" "$DEB" "$sha256"; then
        log "the $DEVICE_ABI .deb could not be downloaded; falling back to the documented APT installer"
        DEB=""
        return 1
    fi
    return 0
}

install_native() {
    need timeout "install coreutils"

    local deb_path=""
    if download_native_deb; then
        deb_path=$DEB
    fi

    push_termux_file "$ROOT/ci/termux-native-install.sh" \
        "$TERMUX_HOME/ci-termux-native-install.sh"

    local -a install_args=()
    if [ -n "$deb_path" ]; then
        push_termux_file "$deb_path" "$TERMUX_HOME/freebuff-native.deb"
        install_args=("$TERMUX_HOME/freebuff-native.deb")
    fi

    local -a remote=(adb -s "$SERIAL" exec-in run-as "$TERMUX_PACKAGE"
        /system/bin/env
        "HOME=$TERMUX_HOME" "PREFIX=$TERMUX_PREFIX" "TMPDIR=$TERMUX_PREFIX/tmp"
        "PATH=$TERMUX_PREFIX/bin:/system/bin:/system/xbin"
        "LD_LIBRARY_PATH=$TERMUX_PREFIX/lib"
        "$TERMUX_PREFIX/bin/bash" "$TERMUX_HOME/ci-termux-native-install.sh")

    log "installing freebuff-native in Termux (budget ${NATIVE_TIMEOUT}s)"
    local status
    set +e
    timeout "$NATIVE_TIMEOUT" "${remote[@]}" "${install_args[@]}" \
        2>&1 | tee "$OUT/native-install.txt"
    status=${PIPESTATUS[0]}
    set -e

    case $status in
        0)
            grep -q 'NATIVE INSTALL COMPLETE' "$OUT/native-install.txt" \
                || die "the Termux install exited 0 without running freebuff-native --check"
            NATIVE_READY=1
            NATIVE_REASON="freebuff-native --check exited 0"
            log "freebuff-native is installed and --check passed"
            ;;
        124)
            NATIVE_READY=0
            NATIVE_REASON="the x86_64 install exceeded its ${NATIVE_TIMEOUT}s budget"
            log "NATIVE CHECK: FOLLOW-UP -- $NATIVE_REASON"
            ;;
        *)
            die "the x86_64 freebuff-native install failed (exit $status); see $OUT/native-install.txt"
            ;;
    esac
}

install_app() {
    log "installing the app and androidTest APKs"
    adb -s "$SERIAL" uninstall "$PACKAGE" >/dev/null 2>&1 || true
    adb -s "$SERIAL" uninstall "$TEST_PACKAGE" >/dev/null 2>&1 || true
    adb -s "$SERIAL" install -r "$APK" > "$OUT/app-install.txt" 2>&1 \
        || { cat "$OUT/app-install.txt" >&2; die "adb install of the app APK failed"; }
    adb -s "$SERIAL" install -r "$TEST_APK" >> "$OUT/app-install.txt" 2>&1 \
        || { tail -n 20 "$OUT/app-install.txt" >&2; die "adb install of the androidTest APK failed"; }
    [ "$(grep -c '^Success' "$OUT/app-install.txt")" -eq 2 ] \
        || { tail -n 20 "$OUT/app-install.txt" >&2; die "both installs must report Success"; }

    adb -s "$SERIAL" shell pm list packages "$TEST_PACKAGE" \
        > "$OUT/pm-packages.txt" 2>&1
    grep -q "package:$TEST_PACKAGE" "$OUT/pm-packages.txt" \
        || { cat "$OUT/pm-packages.txt" >&2; die "the androidTest package is not installed"; }

    adb -s "$SERIAL" shell pm grant "$PACKAGE" "$PERMISSION" \
        > "$OUT/pm-grant.txt" 2>&1 \
        || { cat "$OUT/pm-grant.txt" >&2; die "pm grant $PERMISSION failed"; }
}

record_native_status() { # status reason
    printf 'status=%s\nreason=%s\n' "$1" "$2" > "$OUT/native-check.txt"
}

run_tests() {
    local -a cmd=(python3 "$ROOT/test/android-e2e.py" --require-device
        --apk "$APK" --test-apk "$TEST_APK"
        --screenshots "$OUT/screenshots")
    if [ "$NATIVE_READY" -ne 1 ]; then
        cmd+=(--skip-native)
    fi

    log "running test/android-e2e.py"
    local status
    set +e
    "${cmd[@]}" 2>&1 | tee "$OUT/instrumentation.txt"
    status=${PIPESTATUS[0]}
    set -e
    check_test_status "$status"
}

finish() {
    local status=$?
    if [ -n "${SERIAL:-}" ] && [ -d "${OUT:-}" ]; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 20 adb -s "$SERIAL" logcat -d -t 500 \
                > "$OUT/logcat.txt" 2>&1 || true
        else
            adb -s "$SERIAL" logcat -d -t 500 > "$OUT/logcat.txt" 2>&1 || true
        fi
        adb devices > "$OUT/adb-devices.txt" 2>&1 || true
    fi
    if [ "$status" -ne 0 ]; then
        printf 'emulator e2e: failed (exit %s); artifacts are in %s\n' \
            "$status" "$OUT" >&2
    fi
    exit "$status"
}

parse_args() {
    while (($#)); do
        case $1 in
            --preflight) MODE=preflight ;;
            --serial)
                (($# >= 2)) || die "--serial needs a value"
                SERIAL_ARG=$2
                shift
                ;;
            --serial=*) SERIAL_ARG=${1#*=} ;;
            --out)
                (($# >= 2)) || die "--out needs a value"
                OUT=$2
                shift
                ;;
            --out=*) OUT=${1#*=} ;;
            --apk)
                (($# >= 2)) || die "--apk needs a value"
                APK=$2
                shift
                ;;
            --apk=*) APK=${1#*=} ;;
            --test-apk)
                (($# >= 2)) || die "--test-apk needs a value"
                TEST_APK=$2
                shift
                ;;
            --test-apk=*) TEST_APK=${1#*=} ;;
            --skip-native-check) NATIVE=0 ;;
            --no-build) BUILD=0 ;;
            --no-provision) PROVISION=0 ;;
            --native-timeout)
                (($# >= 2)) || die "--native-timeout needs a value"
                NATIVE_TIMEOUT=$2
                shift
                ;;
            --native-timeout=*) NATIVE_TIMEOUT=${1#*=} ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument: $1 (try --help)" ;;
        esac
        shift
    done

    case $NATIVE_TIMEOUT in
        ''|*[!0-9]*|0) die "--native-timeout must be a positive integer, not '$NATIVE_TIMEOUT'" ;;
    esac
}

main() {
    parse_args "$@"
    mkdir -p "$OUT" "$CACHE"
    : > "$OUT/run.log"
    trap finish EXIT

    log "freebuff-native Android setup e2e (x86_64 compatibility coverage)"
    preflight

    if [ "$MODE" = preflight ]; then
        log "preflight ok: $SERIAL (API $API, $ABI)"
        return 0
    fi

    if [ "$BUILD" -eq 1 ]; then
        build_app
    fi
    verify_apks

    if [ "$PROVISION" -eq 1 ]; then
        need curl
        provision_termux
        if [ "$NATIVE" -eq 1 ]; then
            install_native
        else
            NATIVE_READY=0
            NATIVE_REASON="--skip-native-check: the native install check is a follow-up"
            log "NATIVE CHECK: FOLLOW-UP -- $NATIVE_REASON"
        fi
        install_app
    else
        NATIVE_READY=0
        NATIVE_REASON="--no-provision: Termux and freebuff-native were not installed by this wrapper"
        log "NATIVE CHECK: FOLLOW-UP -- $NATIVE_REASON"
    fi

    if [ "$NATIVE_READY" -eq 1 ]; then
        record_native_status covered "$NATIVE_REASON"
    else
        record_native_status follow-up "$NATIVE_REASON"
    fi

    run_tests

    if [ "$NATIVE_READY" -eq 1 ]; then
        log "ok (including the native install check)"
    else
        log "ok (UI/consent/denied only; the native check is a follow-up, not a pass)"
    fi
}

# Sourcing the script must not run it: the deviceless tests use check_test_status
# and the parsers directly.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
