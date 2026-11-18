# YouTube Short

`freebuff-native-short.mp4` — 1080x1920, 14 s, silent, 218 KB. Built from a real
screen recording of the app on a device, not from mockups.

## Title

```
Freebuff runs natively on Termux (no proot) #Shorts
```

Alternatives, if you want a more personal framing:

- `I ran a 136 MB coding agent on Android without proot #Shorts`
- `A coding agent that runs on the Android kernel #Shorts`

## Description

```
Freebuff is a coding agent shipped as a glibc binary, so on Android it usually
means proot: a second userland, extra memory, and a broken shell for the agent.

This runs the official binary on the Android kernel through Termux's glibc
runtime. A small LD_PRELOAD shim repairs the terminal-command broker re-exec
(upstream CodebuffAI/freebuff#1688), so the agent's shell, git and code search
work natively.

Install, in Termux:
  pkg install freebuff-repo
  pkg install freebuff-native
  freebuff-native --download

Source, installer, shim and the investigation notes:
https://github.com/MBanucu/freebuff-native-termux

F-Droid app (setup companion) is in review: fdroid/fdroiddata!58019

#Termux #Android #Freebuff #CodingAgent #Linux #FOSS
```

## Beats

| time | screen | caption |
| --- | --- | --- |
| 0.0–2.6 | title card | Freebuff on Termux / native glibc · no proot |
| 2.6–5.7 | app main screen | it checks the real install |
| 5.7–9.6 | report filling in | all green · exit 0 |
| 9.6–14.0 | end card | `pkg install freebuff-native` |

The wait between the tap and the report is cut out, not sped up: the screen is
static there, and a static screen at 2x still looks static.

## Upload checklist

- Upload as-is; vertical and under three minutes is what makes it a Short.
- The file is silent on purpose — add music in the YouTube app (licensed tracks)
  rather than embedding a track that would be claimed.
- Thumbnail: the frame around 8 s shows the full report; pick it manually.
- Pin a comment with the three install commands; Shorts descriptions are easy to
  miss.
- Mention the F-Droid review only as "in review" until it is actually merged.

## Rebuilding it

The recording is not committed (it is device-specific). To reproduce:

```bash
# 1. record on the phone, while the app is frontmost and Termux is set up
adb shell screenrecord --size 720x1600 --bit-rate 6000000 --time-limit 60 /sdcard/demo.mp4 &
sleep 3
adb shell am start -W -n io.github.mbanucu.freebuffnative/.MainActivity
sleep 3
adb shell input tap 720 1068         # "Check setup"
sleep 9
adb shell pkill -INT screenrecord
adb pull /sdcard/demo.mp4 demo.mp4

# 2. compose
bash docs/youtube/build-short.sh demo.mp4 docs/youtube/freebuff-native-short.mp4
```

The cut points are variables at the top of `build-short.sh`, so a different
recording only needs new timings, not a different filter graph.
