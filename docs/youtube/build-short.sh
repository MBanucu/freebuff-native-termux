#!/usr/bin/env bash
#
# Build the vertical Short from a device screen recording.
#
#   docs/youtube/build-short.sh DEMO.mp4 OUT.mp4
#
# DEMO is `adb shell screenrecord --size 720x1600` footage of the app: the main
# screen, a tap on "Check setup", and the report appearing.  The cut points
# below match that recording; adjust start/end if you re-record.
#
# Layout: 1080x1920.  The screen is scaled to fit between a headline and a
# footnote rather than cropped, so no part of the report is lost on the 20:9
# phone.

set -euo pipefail

DEMO=${1:?usage: build-short.sh DEMO.mp4 OUT.mp4}
OUT=${2:?usage: build-short.sh DEMO.mp4 OUT.mp4}
FONT=${FONT:-/system/fonts/Roboto-Regular.ttf}

# The screen is static while the check runs, so the clip is cut in two: the
# main screen, then the report filling in.  The wait is skipped, not sped up
# until it looks like a glitch.
FIRST_START=${FIRST_START:-3.6}    # first frame with the app, not the launcher
FIRST_END=${FIRST_END:-9.2}
FIRST_SPEED=${FIRST_SPEED:-1.8}
SECOND_START=${SECOND_START:-13.2} # the report starts to appear
SECOND_END=${SECOND_END:-17.5}
SECOND_SPEED=${SECOND_SPEED:-1.1}

ffmpeg -hide_banner -y \
    -f lavfi -i "color=c=0x101418:s=1080x1920:r=30:d=2.6" \
    -i "$DEMO" \
    -f lavfi -i "color=c=0x101418:s=1080x1920:r=30:d=3.4" \
    -filter_complex "
    [0:v]drawtext=fontfile=$FONT:text='Freebuff on Termux':fontcolor=white:fontsize=96:x=(w-text_w)/2:y=790,
         drawtext=fontfile=$FONT:text='native glibc  ·  no proot':fontcolor=0x3ddc84:fontsize=48:x=(w-text_w)/2:y=920,
         drawtext=fontfile=$FONT:text='no second userland':fontcolor=0x9aa4b2:fontsize=38:x=(w-text_w)/2:y=1000,
         fade=t=in:st=0:d=0.4[intro];

    [1:v]split=2[a][b];

    [a]trim=start=$FIRST_START:end=$FIRST_END,setpts=(PTS-STARTPTS)/$FIRST_SPEED,scale=702:-2,fps=30,
       pad=1080:1920:189:210:color=0x101418,
       drawbox=x=183:y=204:w=714:h=1572:color=0x2f3540:t=6,
       drawtext=fontfile=$FONT:text='it checks the real install':fontcolor=white:fontsize=44:x=(w-text_w)/2:y=96,
       drawtext=fontfile=$FONT:text='upstream binary  ·  no patching':fontcolor=0x9aa4b2:fontsize=32:x=(w-text_w)/2:y=1802[first];

    [b]trim=start=$SECOND_START:end=$SECOND_END,setpts=(PTS-STARTPTS)/$SECOND_SPEED,scale=702:-2,fps=30,
       pad=1080:1920:189:210:color=0x101418,
       drawbox=x=183:y=204:w=714:h=1572:color=0x2f3540:t=6,
       drawtext=fontfile=$FONT:text='all green  ·  exit 0':fontcolor=0x3ddc84:fontsize=44:x=(w-text_w)/2:y=96,
       drawtext=fontfile=$FONT:text='upstream binary  ·  no patching':fontcolor=0x9aa4b2:fontsize=32:x=(w-text_w)/2:y=1802[second];

    [2:v]drawtext=fontfile=$FONT:text='pkg install freebuff-native':fontcolor=0x3ddc84:fontsize=60:x=(w-text_w)/2:y=770,
         drawtext=fontfile=$FONT:text='signed APT repo  ·  F-Droid app in review':fontcolor=white:fontsize=40:x=(w-text_w)/2:y=880,
         drawtext=fontfile=$FONT:text='github.com/MBanucu/freebuff-native-termux':fontcolor=0x9aa4b2:fontsize=30:x=(w-text_w)/2:y=960,
         fade=t=out:st=2.6:d=0.8[outro];

    [intro][first][second][outro]concat=n=4:v=1:a=0,format=yuv420p[out]
    " \
    -map '[out]' -r 30 -c:v libx264 -preset medium -crf 20 -movflags +faststart \
    "$OUT"

printf 'built %s\n' "$OUT"
ffprobe -v error -show_entries format=duration,size -of default=nw=1 "$OUT"
