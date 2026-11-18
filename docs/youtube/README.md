# YouTube Shorts

Two cuts, both from real device footage (no mockups):

| file | length | what it shows |
| --- | --- | --- |
| `freebuff-native-install-short.mp4` | 22 s | uninstalled → consent dialog → the real 136 MB download → check report |
| `freebuff-native-short.mp4` | 14 s | the check report only; shorter hook |

Publish the install cut first: the download is the part people do not believe.

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
| 2.2–4.0 | app, nothing installed | nothing installed yet |
| 4.0–6.4 | consent dialog | one dialog, real numbers |
| 6.4–9.0 | `pkg install` in Termux | one command to Termux |
| 9.0–13.0 | download, 9x | 136 MB, sha256 checked |
| 13.0–15.0 | end of install | no proot, no compiler |
| 15.0–18.2 | check report | then it checks itself |
| 18.2–22.0 | end card | `pkg install freebuff-native` |

The download is compressed 9x rather than trimmed: the percentage counter still
moves, which reads as "this is doing work" instead of a loading bar that jumps.

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

# record: main screen -> consent -> setup -> check
adb shell screenrecord --size 720x1600 --bit-rate 6000000 --time-limit 175 /sdcard/install.mp4 &
# (drive the app; script used here: record-install.sh in the session temp dir)
adb shell pkill -INT screenrecord

bash docs/youtube/build-short-install.sh install.mp4 docs/youtube/freebuff-native-install-short.mp4
```

Cut points are variables at the top of both build scripts; a re-record normally
only needs new timings. The recording is 720x1600; the scripts scale it to fit the
1080x1920 canvas, and the terminal segments are cropped full-bleed because text
needs the width.
