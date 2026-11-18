# YouTube Shorts

Two cuts, both from real device footage (no mockups):

| file | length | what it shows |
| --- | --- | --- |
| `freebuff-native-install-short.mp4` | 26 s | uninstalled → consent dialog → package + real 136 MB download → checksum, shim, wrapper → check report |
| `freebuff-native-usage-short.mp4` | 23 s | freebuff writing and running a Python script on the phone |
| `freebuff-native-short.mp4` | 14 s | the check report only; shorter hook |

Publish the install cut first (the download is the part people do not believe), then the usage cut as proof that it works.

## Title

```
Installing a 136 MB coding agent on Android, natively #Shorts
```

Alternatives:

- `Freebuff on Termux: 136 MB, no proot #Shorts`
- `A coding agent on the Android kernel, install included #Shorts`

## Description

```
Freebuff is a coding agent shipped as a glibc binary, so on Android it usually
means proot: a second userland, extra memory, and a broken shell for the agent.

This installs the official binary onto the Android kernel through Termux's glibc
runtime. A small LD_PRELOAD shim repairs the terminal-command broker re-exec
(upstream CodebuffAI/freebuff#1688), so the agent's shell, git and code search
work natively.

Install, in Termux:
  pkg install freebuff-repo
  pkg install freebuff-native
  freebuff-native --download

Source, installer, shim and the investigation notes:
https://github.com/MBanucu/freebuff-native-termux

The setup app is in review for F-Droid: fdroid/fdroiddata!58019

#Termux #Android #Freebuff #CodingAgent #Linux #FOSS
```

## Beats, install cut

| time | screen | caption |
| --- | --- | --- |
| 0.0–2.2 | title | Freebuff on Termux / installing it, on camera |
| 2.2–4.4 | app, nothing installed | nothing installed yet |
| 4.4–7.3 | consent dialog | one dialog, real numbers |
| 7.3–14.3 | `pkg` + download, 5× | package → 136 MB |
| 14.3–19.1 | checksum, install, shim, wrapper, 1× | 136 MB → checksum → wrapper |
| 19.1–22.9 | check report | then it checks itself |
| 22.9–26.4 | end card | `pkg install freebuff-native` |

The install is one continuous interval: nothing is dropped between the keyboard
going away and the wrapper landing. The first part is fast-forwarded 5×, the last
five seconds play at normal speed so `checksum verified`, `freebuff 0.2.36
installed`, `spawn shim installed` and `wrapper installed` can be read.

## How the timings are measured

Not by sampling frames. `record-install.sh` writes a marker with the device clock
for every action (launch, taps, check) and for every filesystem milestone the
installer reaches: the release archive appearing in `$PREFIX/tmp/freebuff-native`,
the extracted binary appearing in `~/.config/manicode`, `$PREFIX/bin/freebuff`
being written, and `freebuff --version` working.

`sync.py` converts those epochs to video time. The encoder starts slightly after
`record_start`, so one visual event calibrates the difference — the screen change
from Termux to the app, whose request time is known — and every marker is shifted
by that offset. The result is written to `timeline.env` (committed from the take
above), and `build-short-install.sh` reads it, so the cuts land on the events.

Two caveats worth keeping in mind:

- Markers are taken after the command returns, so they lag the visible change by
  the command's own latency. `am start -W` waits for the first frame, which puts
  the launch anchor ~0.4 s late; the cuts keep 0.3–0.5 s of margin because of it.
- The recorder must look in `$PREFIX/tmp/freebuff-native`, not `$TMPDIR`: the
  installer runs under Termux's RUN_COMMAND service, which has its own `TMPDIR`.

## Beats, usage cut

| time | screen | caption |
| --- | --- | --- |
| 0.0–2.2 | title | Freebuff on Termux / one real task, on the phone |
| 2.2–4.6 | freebuff banner | the same binary, natively |
| 4.6–7.0 | the task appears | ask for a file |
| 7.0–19.6 | thinking, file created, run, answer | it writes · runs · checks |
| 19.6–21.6 | the finished answer | done · exit 0 |
| 21.6–23.5 | end card | `pkg install freebuff-native` |

The task is real: freebuff creates `fib.py`, runs `python3 fib.py`, and reports
`exit code 0` with the first ten Fibonacci numbers. The keyboard is dismissed
before recording, so the TUI fills the frame.

## Beats, check cut

| time | screen | caption |
| --- | --- | --- |
| 0.0–2.6 | title | Freebuff on Termux |
| 2.6–5.7 | app main screen | it checks the real install |
| 5.7–9.6 | report filling in | all green · exit 0 |
| 9.6–14.0 | end card | `pkg install freebuff-native` |

## Upload checklist

- Vertical and under three minutes; 22 s is comfortable for a Short.
- The files are silent on purpose — add music in the YouTube app (licensed
  tracks) instead of embedding a track that would be claimed.
- Thumbnail: install cut, the frame at ~10 s (download in progress); check cut,
  the report frame.
- Pin a comment with the three install commands.
- Say "in review" for F-Droid until the merge request lands.

## Rebuilding

The recordings are not committed. To reproduce the install cut:

```bash
# from a clean state: no package, no binary, no release cache
pkg uninstall -y freebuff-native
rm -rf "$PREFIX/tmp/freebuff-native" ~/.config/manicode/freebuff

# record with markers
bash docs/youtube/record-install.sh install.mp4 markers.txt

# turn the markers into cut points, then compose
python3 docs/youtube/sync.py install.mp4 markers.txt timeline.env
TIMELINE=timeline.env bash docs/youtube/build-short-install.sh install.mp4 \
    docs/youtube/freebuff-native-install-short.mp4
```

The usage cut is recorded from a Termux session running `freebuff`: open a new
session, start freebuff, hide the keyboard (BACK), then record, type the task
through `adb shell input text`, and stop after the answer settles.

Cut points are variables at the top of every build script; a re-record normally
only needs new timings. The recording is 720x1600; the scripts scale it to fit the
1080x1920 canvas, and the terminal segments are cropped full-bleed because text
needs the width.
