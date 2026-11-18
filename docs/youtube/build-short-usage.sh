#!/usr/bin/env bash
#
# Build the "freebuff doing a task" vertical Short.
#
#   docs/youtube/build-short-usage.sh DEMO.mp4 OUT.mp4
#
# DEMO is a 720x1600 recording of a Termux session running freebuff: the banner,
# the prompt being typed, and the agent writing and running hello.py.  The
# timings are the segments of that run.

set -euo pipefail

DEMO=${1:?usage: build-short-usage.sh DEMO.mp4 OUT.mp4}
OUT=${2:?usage: build-short-usage.sh DEMO.mp4 OUT.mp4}
FONT=${FONT:-/system/fonts/Roboto-Regular.ttf}

# The TUI is text: crop it full-bleed and keep a band for the caption.
TERM="scale=1080:-1,crop=1080:1750:0:250,pad=1080:1920:0:170:color=0x0b0e12"

BANNER_IN=${BANNER_IN:-0.8};    BANNER_OUT=${BANNER_OUT:-3.2}
PROMPT_IN=${PROMPT_IN:-3.6};    PROMPT_OUT=${PROMPT_OUT:-6.0}
REPLY_IN=${REPLY_IN:-6.0};      REPLY_OUT=${REPLY_OUT:-21.5}
DONE_IN=${DONE_IN:-21.5};       DONE_OUT=${DONE_OUT:-23.5}
REPLY_SPEED=${REPLY_SPEED:-1.35}

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
         drawtext=fontfile=$FONT:text='one real task, on the phone':fontcolor=0x3ddc84:fontsize=44:x=(w-text_w)/2:y=900,
         fade=t=in:st=0:d=0.3[intro];

    [1:v]split=4[a][b][c][d];

    [a]trim=start=$BANNER_IN:end=$BANNER_OUT,setpts=PTS-STARTPTS,fps=30,$TERM,$(cap 'the same binary, natively')[s1];
    [b]trim=start=$PROMPT_IN:end=$PROMPT_OUT,setpts=PTS-STARTPTS,fps=30,$TERM,$(cap 'ask for a file')[s2];
    [c]trim=start=$REPLY_IN:end=$REPLY_OUT,setpts=(PTS-STARTPTS)/$REPLY_SPEED,fps=30,$TERM,$(cap 'it writes  ·  runs  ·  checks' 0x3ddc84)[s3];
    [d]trim=start=$DONE_IN:end=$DONE_OUT,setpts=PTS-STARTPTS,fps=30,$TERM,$(cap 'done  ·  exit 0' 0x3ddc84)[s4];

    [2:v]drawtext=fontfile=$FONT:text='pkg install freebuff-native':fontcolor=0x3ddc84:fontsize=58:x=(w-text_w)/2:y=760,
         drawtext=fontfile=$FONT:text='signed APT repo  ·  F-Droid app in review':fontcolor=white:fontsize=38:x=(w-text_w)/2:y=866,
         drawtext=fontfile=$FONT:text='github.com/MBanucu/freebuff-native-termux':fontcolor=0x9aa4b2:fontsize=30:x=(w-text_w)/2:y=944,
         fade=t=out:st=2.4:d=0.8[outro];

    [intro][s1][s2][s3][s4][outro]concat=n=6:v=1:a=0,format=yuv420p[out]
    " \
    -map '[out]' -r 30 -c:v libx264 -preset medium -crf 20 -movflags +faststart \
    "$OUT"

printf 'built %s\n' "$OUT"
ffprobe -v error -show_entries format=duration,size -of default=nw=1 "$OUT"
