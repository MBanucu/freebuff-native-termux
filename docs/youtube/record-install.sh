#!/data/data/com.termux/files/usr/bin/bash
#
# Record the app installing freebuff, with a timestamp for every step.
#
#   docs/youtube/record-install.sh DEMO.mp4 MARKERS.txt
#
# The markers are written on the device clock, which is also the clock the video
# is measured against; sync.py turns them into exact video times.  The recording
# has to start from a clean state: no package, no binary, no release cache.
#
# Milestones that matter, and why they can be timestamped at all:
#   app_launch        we launch the activity, so we know when
#   dialog_tap        the tap that opens the consent dialog
#   setup_tap         the tap that starts the install
#   download_start    the release archive appears in the installer cache
#   binary_appeared   the extracted binary lands in ~/.config/manicode
#   wrapper_appeared  $PREFIX/bin/freebuff is written
#   ready             `freebuff --version` runs (glibc + binary + shim + wrapper)
#   check_tap         the tap that runs the check
#   report_shown      the output text is on screen

set -uo pipefail

OUT=${1:?usage: record-install.sh DEMO.mp4 MARKERS.txt}
MARKERS=${2:?usage: record-install.sh DEMO.mp4 MARKERS.txt}
REMOTE=/sdcard/install-sync.mp4
# The installer runs under Termux's RUN_COMMAND service, whose TMPDIR is
# $PREFIX/tmp, not whatever TMPDIR this script inherits.
CACHE="$PREFIX/tmp/freebuff-native"
BIN=$HOME/.config/manicode/freebuff
WRAPPER=$PREFIX/bin/freebuff

if [ -e "$BIN" ]; then
    echo "the freebuff binary is already present; clear it first" >&2
    exit 2
fi

: >"$MARKERS"
mark() { printf '%s %s\n' "$(date +%s.%N)" "$1" >>"$MARKERS"; }

tap_text() {
    adb shell uiautomator dump /sdcard/u.xml >/dev/null 2>&1
    local b x1 y1 x2 y2
    b=$(adb shell cat /sdcard/u.xml | sed 's/></>\n</g' |
        grep -F "text=\"$1\"" |
        sed -E 's/.*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]".*/\1 \2 \3 \4/' |
        head -1)
    if [ -z "$b" ]; then
        echo "no element: $1" >&2
        return 1
    fi
    read -r x1 y1 x2 y2 <<<"$b"
    adb shell input tap $(((x1 + x2) / 2)) $(((y1 + y2) / 2))
}

wait_text() { # text timeout-seconds
    local deadline=$((SECONDS + $2))
    while [ "$SECONDS" -lt "$deadline" ]; do
        adb shell uiautomator dump /sdcard/u.xml >/dev/null 2>&1
        if adb shell cat /sdcard/u.xml | grep -qF "$1"; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

adb shell am force-stop io.github.mbanucu.freebuffnative
adb shell rm -f "$REMOTE"
mark record_start
adb shell screenrecord --size 720x1600 --bit-rate 6000000 --time-limit 175 "$REMOTE" &
record_pid=$!
sleep 1
mark recording_started

adb shell am start -W -n io.github.mbanucu.freebuffnative/.MainActivity >/dev/null
mark app_launch
wait_text "Set up freebuff-native" 15
tap_text "Set up freebuff-native" || exit 1
mark dialog_tap

wait_text "Download about 540 MB?" 10
sleep 2
tap_text "START SETUP" || exit 1
mark setup_tap

# The session opens with the software keyboard up; back closes it, not the shell.
for _ in 1 2 3 4; do
    sleep 1
    if adb shell dumpsys input_method | grep -q 'mInputShown=true'; then
        adb shell input keyevent 4
        mark keyboard_dismissed
    else
        break
    fi
done

cache_seen='' binary_seen='' wrapper_seen=''
for _ in $(seq 1 900); do
    if [ -z "$cache_seen" ] && [ -d "$CACHE" ] && [ -n "$(ls -A "$CACHE" 2>/dev/null)" ]; then
        cache_seen=1
        mark download_start
    fi
    if [ -z "$binary_seen" ] && [ -e "$BIN" ]; then
        binary_seen=1
        mark binary_appeared
    fi
    if [ -z "$wrapper_seen" ] && [ -e "$WRAPPER" ]; then
        wrapper_seen=1
        mark wrapper_appeared
    fi
    if [ -n "$wrapper_seen" ] && freebuff --version >/dev/null 2>&1; then
        mark ready
        break
    fi
    sleep 0.25
done

sleep 3
mark app_return
adb shell am start -n io.github.mbanucu.freebuffnative/.MainActivity >/dev/null
wait_text "Check setup" 15
tap_text "Check setup" || exit 1
mark check_tap
if wait_text "native install complete" 30; then
    mark report_shown
fi
sleep 3

adb shell pkill -INT screenrecord
wait "$record_pid" 2>/dev/null
mark record_stopped

adb pull "$REMOTE" "$OUT" 2>&1 | tail -1
adb logcat -d -v epoch -s FreebuffNative:I | tail -4 >>"$MARKERS"
ffprobe -v error -show_entries format=duration -of default=nw=1 "$OUT"
printf 'markers in %s\n' "$MARKERS"
