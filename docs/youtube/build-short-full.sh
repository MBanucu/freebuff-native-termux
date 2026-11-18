#!/usr/bin/env bash
#
# Build the single "whole thing" Short: app install, terminal install, freebuff
# doing a task.
#
#   TIMELINE=docs/youtube/timeline.env \
#   docs/youtube/build-short-full.sh INSTALL.mp4 USAGE.mp4 OUT.mp4
#
# INSTALL.mp4 is the recording behind build-short-install.sh (app + install);
# USAGE.mp4 is the recording behind build-short-usage.sh (the agent working).
# TIMELINE.env pins the install cuts to the markers; the usage cuts are the
# segments of that recording.

set -euo pipefail

INSTALL=${1:?usage: build-short-full.sh INSTALL.mp4 USAGE.mp4 OUT.mp4}
USAGE=${2:?usage: build-short-full.sh INSTALL.mp4 USAGE.mp4 OUT.mp4}
OUT=${3:?usage: build-short-full.sh INSTALL.mp4 USAGE.mp4 OUT.mp4}
FONT=${FONT:-/system/fonts/Roboto-Regular.ttf}

if [ -n "${TIMELINE:-}" ] && [ -f "$TIMELINE" ]; then
    # shellcheck source=/dev/null
    . "$TIMELINE"
fi
APP_IN=${APP_IN:-1.68};           APP_OUT=${APP_OUT:-3.88}
DIALOG_IN=${DIALOG_IN:-5.64};     DIALOG_OUT=${DIALOG_OUT:-8.59}
INSTALL_IN=${INSTALL_IN:-13.91};  INSTALL_SPLIT=${INSTALL_SPLIT:-48.64}
INSTALL_OUT=${INSTALL_OUT:-53.43}

BANNER_IN=${BANNER_IN:-0.8};      BANNER_OUT=${BANNER_OUT:-3.2}
REPLY_IN=${REPLY_IN:-3.6};        REPLY_OUT=${REPLY_OUT:-21.5}
DONE_IN=${DONE_IN:-21.5};         DONE_OUT=${DONE_OUT:-23.5}
FAST_SPEED=${FAST_SPEED:-5};      REPLY_SPEED=${REPLY_SPEED:-1.35}

APP="scale=702:-2,pad=1080:1920:189:210:color=0x101418,drawbox=x=183:y=204:w=714:h=1572:color=0x2f3540:t=6"
TERM="scale=1080:-1,crop=1080:1750:0:250,pad=1080:1920:0:170:color=0x0b0e12"

cap() { # text [colour]
    printf "drawtext=fontfile=%s:text='%s':fontcolor=%s:fontsize=40:x=(w-text_w)/2:y=48:box=1:boxcolor=0x0b0e12@0.85:boxborderw=18" \
        "$FONT" "$1" "${2:-white}"
}

ffmpeg -hide_banner -y \
    -f lavfi -i "color=c=0x101418:s=1080x1920:r=30:d=2.2" \
    -i "$INSTALL" \
    -i "$USAGE" \
    -f lavfi -i "color=c=0x101418:s=1080x1920:r=30:d=3.4" \
    -filter_complex "
    [0:v]drawtext=fontfile=$FONT:text='Freebuff on Termux':fontcolor=white:fontsize=90:x=(w-text_w)/2:y=770,
         drawtext=fontfile=$FONT:text='install it  ·  then use it':fontcolor=0x3ddc84:fontsize=44:x=(w-text_w)/2:y=890,
         fade=t=in:st=0:d=0.3[intro];

    [1:v]split=4[a][b][c][d];

    [a]trim=start=$APP_IN:end=$APP_OUT,setpts=PTS-STARTPTS,fps=30,$APP,$(cap 'nothing installed yet')[s1];
    [b]trim=start=$DIALOG_IN:end=$DIALOG_OUT,setpts=PTS-STARTPTS,fps=30,$APP,$(cap 'the app asks  ·  then sends one command')[s2];
    [c]trim=start=$INSTALL_IN:end=$INSTALL_SPLIT,setpts=(PTS-STARTPTS)/$FAST_SPEED,fps=30,$TERM,$(cap 'package  ·  136 MB download' 0x3ddc84)[s3];
    [d]trim=start=$INSTALL_SPLIT:end=$INSTALL_OUT,setpts=PTS-STARTPTS,fps=30,$TERM,$(cap 'checksum  ·  shim  ·  wrapper' 0x3ddc84)[s4];

    [2:v]split=3[e][f][g];

    [e]trim=start=$BANNER_IN:end=$BANNER_OUT,setpts=PTS-STARTPTS,fps=30,$TERM,$(cap 'now  ·  one real task')[s5];
    [f]trim=start=$REPLY_IN:end=$REPLY_OUT,setpts=(PTS-STARTPTS)/$REPLY_SPEED,fps=30,$TERM,$(cap 'it writes  ·  runs  ·  checks' 0x3ddc84)[s6];
    [g]trim=start=$DONE_IN:end=$DONE_OUT,setpts=PTS-STARTPTS,fps=30,$TERM,$(cap 'done  ·  exit 0' 0x3ddc84)[s7];

    [3:v]drawtext=fontfile=$FONT:text='pkg install freebuff-native':fontcolor=0x3ddc84:fontsize=56:x=(w-text_w)/2:y=750,
         drawtext=fontfile=$FONT:text='signed APT repo  ·  F-Droid app in review':fontcolor=white:fontsize=36:x=(w-text_w)/2:y=854,
         drawtext=fontfile=$FONT:text='github.com/MBanucu/freebuff-native-termux':fontcolor=0x9aa4b2:fontsize=28:x=(w-text_w)/2:y=930,
         fade=t=out:st=2.6:d=0.8[outro];

    [intro][s1][s2][s3][s4][s5][s6][s7][outro]concat=n=9:v=1:a=0,format=yuv420p[out]
    " \
    -map '[out]' -r 30 -c:v libx264 -preset medium -crf 20 -movflags +faststart \
    "$OUT"

printf 'built %s\n' "$OUT"
ffprobe -v error -show_entries format=duration,size -of default=nw=1 "$OUT"
