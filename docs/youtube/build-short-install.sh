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

    [1:v]split=6[a][b][c][d][e][f];

    [a]trim=start=2.0:end=3.8,setpts=PTS-STARTPTS,fps=30,$APP,$(cap 'nothing installed yet')[s1];
    [b]trim=start=8.0:end=10.4,setpts=PTS-STARTPTS,fps=30,$APP,$(cap 'one dialog, real numbers')[s2];
    [c]trim=start=27.0:end=29.6,setpts=PTS-STARTPTS,fps=30,$TERM,$(cap 'one command to Termux')[s3];
    [d]trim=start=32.0:end=68.0,setpts=(PTS-STARTPTS)/9,fps=30,$TERM,$(cap '136 MB, sha256 checked' 0x3ddc84)[s4];
    [e]trim=start=68.0:end=72.0,setpts=(PTS-STARTPTS)/2,fps=30,$TERM,$(cap 'no proot, no compiler')[s5];
    [f]trim=start=77.6:end=80.8,setpts=PTS-STARTPTS,fps=30,$APP,$(cap 'then it checks itself' 0x3ddc84)[s6];

    [2:v]drawtext=fontfile=$FONT:text='pkg install freebuff-native':fontcolor=0x3ddc84:fontsize=58:x=(w-text_w)/2:y=760,
         drawtext=fontfile=$FONT:text='signed APT repo  ·  F-Droid app in review':fontcolor=white:fontsize=38:x=(w-text_w)/2:y=866,
         drawtext=fontfile=$FONT:text='github.com/MBanucu/freebuff-native-termux':fontcolor=0x9aa4b2:fontsize=30:x=(w-text_w)/2:y=944,
         fade=t=out:st=2.4:d=0.8[outro];

    [intro][s1][s2][s3][s4][s5][s6][outro]concat=n=8:v=1:a=0,format=yuv420p[out]
    " \
    -map '[out]' -r 30 -c:v libx264 -preset medium -crf 20 -movflags +faststart \
    "$OUT"

printf 'built %s\n' "$OUT"
ffprobe -v error -show_entries format=duration,size -of default=nw=1 "$OUT"
