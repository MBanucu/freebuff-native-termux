#!/usr/bin/env bash
#
# Build the "install it too" vertical Short.
#
#   docs/youtube/build-short-install.sh DEMO.mp4 OUT.mp4
#
# DEMO is an 83 s 720x1600 recording of: the app with nothing installed, the
# consent dialog, Termux running the install (package, then the 136 MB download),
# and the app's check afterwards.  Timings are variables; re-record and adjust.
#
# The app screens are shown inside a frame (nothing cropped), the terminal is
# shown full-bleed because it is text and needs the width.

set -euo pipefail

DEMO=${1:?usage: build-short-install.sh DEMO.mp4 OUT.mp4}
OUT=${2:?usage: build-short-install.sh DEMO.mp4 OUT.mp4}
FONT=${FONT:-/system/fonts/Roboto-Regular.ttf}

# sync.py writes these from the recording's markers, so the cuts land on the
# events instead of on numbers guessed from sampled frames.
if [ -n "${TIMELINE:-}" ] && [ -f "$TIMELINE" ]; then
    # shellcheck source=/dev/null
    . "$TIMELINE"
fi
APP_IN=${APP_IN:-2.0};           APP_OUT=${APP_OUT:-3.8}
DIALOG_IN=${DIALOG_IN:-7.5};     DIALOG_OUT=${DIALOG_OUT:-10.5}
INSTALL_IN=${INSTALL_IN:-14.5};  INSTALL_OUT=${INSTALL_OUT:-53.5}
INSTALL_SPLIT=${INSTALL_SPLIT:-48.5}
REP_IN=${REP_IN:-60.3};          REP_OUT=${REP_OUT:-63.0}

# Nothing between INSTALL_IN and INSTALL_OUT is dropped: the package and the
# download are fast-forwarded, and the last seconds before the wrapper play at
# normal speed so the checksum and install lines can be read.
FAST_SPEED=${FAST_SPEED:-5}
SLOW_SPEED=${SLOW_SPEED:-1}

APP="scale=702:-2,pad=1080:1920:189:210:color=0x101418,drawbox=x=183:y=204:w=714:h=1572:color=0x2f3540:t=6"
TERM="scale=1080:-1,crop=1080:1750:0:250,pad=1080:1920:0:170:color=0x0b0e12"

cap() { # text [colour]
    printf "drawtext=fontfile=%s:text='%s':fontcolor=%s:fontsize=40:x=(w-text_w)/2:y=48:box=1:boxcolor=0x0b0e12@0.85:boxborderw=18" \
        "$FONT" "$1" "${2:-white}"
}

ffmpeg -hide_banner -y \
    -f lavfi -i "color=c=0x101418:s=1080x1920:r=30:d=2.2" \
    -i "$DEMO" \
    -f lavfi -i "color=c=0x101418:s=1080x1920:r=30:d=3.2" \
    -filter_complex "
    [0:v]drawtext=fontfile=$FONT:text='Freebuff on Termux':fontcolor=white:fontsize=92:x=(w-text_w)/2:y=780,
         drawtext=fontfile=$FONT:text='installing it, on camera':fontcolor=0x3ddc84:fontsize=46:x=(w-text_w)/2:y=900,
         fade=t=in:st=0:d=0.3[intro];

    [1:v]split=5[a][b][c][d][e];

    [a]trim=start=$APP_IN:end=$APP_OUT,setpts=PTS-STARTPTS,fps=30,$APP,$(cap 'nothing installed yet')[s1];
    [b]trim=start=$DIALOG_IN:end=$DIALOG_OUT,setpts=PTS-STARTPTS,fps=30,$APP,$(cap 'one dialog, real numbers')[s2];
    [c]trim=start=$INSTALL_IN:end=$INSTALL_SPLIT,setpts=(PTS-STARTPTS)/$FAST_SPEED,fps=30,$TERM,$(cap 'package  ·  136 MB' 0x3ddc84)[s3];
    [d]trim=start=$INSTALL_SPLIT:end=$INSTALL_OUT,setpts=(PTS-STARTPTS)/$SLOW_SPEED,fps=30,$TERM,$(cap '136 MB  ·  checksum  ·  wrapper' 0x3ddc84)[s4];
    [e]trim=start=$REP_IN:end=$REP_OUT,setpts=PTS-STARTPTS,fps=30,$APP,$(cap 'then it checks itself' 0x3ddc84)[s5];

    [2:v]drawtext=fontfile=$FONT:text='pkg install freebuff-native':fontcolor=0x3ddc84:fontsize=58:x=(w-text_w)/2:y=760,
         drawtext=fontfile=$FONT:text='signed APT repo  ·  F-Droid app in review':fontcolor=white:fontsize=38:x=(w-text_w)/2:y=866,
         drawtext=fontfile=$FONT:text='github.com/MBanucu/freebuff-native-termux':fontcolor=0x9aa4b2:fontsize=30:x=(w-text_w)/2:y=944,
         fade=t=out:st=2.4:d=0.8[outro];

    [intro][s1][s2][s3][s4][s5][outro]concat=n=7:v=1:a=0,format=yuv420p[out]
    " \
    -map '[out]' -r 30 -c:v libx264 -preset medium -crf 20 -movflags +faststart \
    "$OUT"

printf 'built %s\n' "$OUT"
ffprobe -v error -show_entries format=duration,size -of default=nw=1 "$OUT"
