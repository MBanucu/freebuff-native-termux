# Where to publish

F-Droid only indexes APKs built from source; Termux packages live in APT
repositories. That constraint decides the order of the channels below, and it is
why "get it on F-Droid" cannot mean "get the .deb on F-Droid".

| channel | what a user types | state |
| --- | --- | --- |
| Signed APT repository (GitHub Pages) | `pkg install freebuff-repo && pkg install freebuff-native` | live, both architectures, updates through `pkg` |
| Release debs | `pkg install ./freebuff-native_<version>_<arch>.deb` | live on `v1.1.0` |
| TUR | `pkg install freebuff-native` after `tur-repo` | recipe draft in `tur/`, request open at termux-user-repository/tur#3109 |
| F-Droid | install an app, then set up Termux | app built, tested on a device, tagged `android-v0.1.0`; merge request open at fdroid/fdroiddata!58019 |
| Upstream docs | a Termux line in freebuff's docs | comment on CodebuffAI/freebuff#1688; no PR yet |

## APT repository

`packaging/termux/repo/` builds the tree, `freebuff-repo` adds the source and the
key, and `.github/workflows/apt-repo.yml` publishes it on tags. The `github-pages`
environment accepts the `main` branch and `v*` tags; a tag deploy is rejected
otherwise, which is what happened on the first `v1.1.0` run.

The signing key lives only in the `APT_GPG_PRIVATE_KEY` secret. Losing it means a
new key and a new `freebuff-repo` release, so it should be backed up somewhere
the maintainer controls.

## TUR

The draft is a normal TUR recipe: it builds the tagged archive, compiles the
shim for the target architecture, and installs the modules next to the entry
point. Two questions decide whether it can be merged:

1. TUR policy declines packages that are "few lines of scripting code". The
   payload is ~1.3k lines of bash plus a C shim and a test suite, and the
   request says so explicitly.
2. The 136 MB binary is fetched at runtime. If TUR requires it in the package,
   the recipe needs a subpackage and a mirror, which changes the release process.

`arm` and `i686` are excluded: the installer resolves the glibc loader by name
and has no path for them.

## F-Droid

`android/` is a setup companion, not a freebuff distribution. It detects Termux,
shows the download budget, asks for consent, sends one command through
`RUN_COMMAND`, and reports `--check` output back.

Before a submission:

- ~~build it and run it on a device~~: CI compiles it, and `test/android-e2e.py`
  runs four instrumentation tests against a real Termux;
- ~~add screenshots~~: the e2e run captures them from the device;
- ~~tag the release~~: done, `android-v0.1.0`;
- ~~submit~~: the merge request is open at
  <https://gitlab.com/fdroid/fdroiddata/-/merge_requests/58019>; later updates
  bump the metadata and add a build entry per `android-v*` tag;
- expect the reviewer to ask why this is an app rather than a script — the
  answer is consent, detection, status, and recovery when Termux blocks
  commands, plus the precedent of Nix-on-Droid downloading its runtime outside
  F-Droid.

The app has no `INTERNET` permission. Nothing in it can download anything; the
installer in Termux does the work, visibly. The APK also has no library
dependencies: AndroidX and UI Automator are `androidTest` only.

## What actually drives adoption

A link from the upstream project reaches far more users than any repository
listing, because people start at freebuff's own install page. The package
listing is the thing that link can point at.
