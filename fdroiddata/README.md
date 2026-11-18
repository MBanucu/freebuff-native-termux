# Submitting to F-Droid

`io.github.mbanucu.freebuffnative.yml` is the metadata file for
[fdroiddata](https://gitlab.com/fdroid/fdroiddata), F-Droid's app repository.
It is ready to submit; nothing in this repository has to change first.

## How to submit

F-Droid's data lives on GitLab (the GitHub repository is a mirror), and nothing
here has a GitLab token.

One command, if you have a personal access token with the `api` scope
(GitLab → Settings → Access Tokens):

```bash
GL_TOKEN=glpat-… python3 fdroiddata/submit.py            # fork, branch, file, MR
GL_TOKEN=glpat-… python3 fdroiddata/submit.py --rfp      # and a packaging request
python3 fdroiddata/submit.py --dry-run                   # show the calls first
```

The script prints the merge request URL. Re-running reuses the fork and reports
an existing branch, file or MR instead of overwriting.

By hand, if you prefer:

1. Register on GitLab and fork `https://gitlab.com/fdroid/fdroiddata`.
2. In the fork, add this file as `metadata/io.github.mbanucu.freebuffnative.yml`.
3. Open a merge request against `fdroid/fdroiddata` with the text below.

First-time contributors are also asked to open a request at
<https://gitlab.com/fdroid/rfp/-/issues>; the script's `--rfp` does that.

## Merge request text

```markdown
New app: freebuff-native (io.github.mbanucu.freebuffnative)

Setup companion for the freebuff-native Termux package. The app detects Termux,
shows the download budget, asks for consent, and hands one command to Termux
through RUN_COMMAND; it then reports the installer's own `--check` output.

- Source: https://github.com/MBanucu/freebuff-native-termux (MIT), subdir `android`
- Build: `gradle`, wrapper 8.9, AGP 8.7.3, compileSdk 35, minSdk 24
- No dependencies in the APK (AndroidX/UI Automator are androidTest only)
- No INTERNET permission: Termux performs the download the app describes
- The app has a `fastlane/` directory inside `android/` with title, descriptions,
  changelog and screenshots taken on a device by the instrumentation test

The README documents why this is an app and not a one-line script: detection,
consent with real sizes, a status report from the installer, and recovery when
Termux's `allow-external-apps` setting blocks commands.

Update checks are manual (`UpdateCheckMode: None`) because the repository also
publishes a Termux package with its own `v*` tags; the maintainer notes explain
this.
```

## After it is merged

- `fdroid build io.github.mbanucu.freebuffnative:1` reproduces the build locally.
- Bump `Builds`, `CurrentVersion` and `CurrentVersionCode` in the YAML together
  with the next `android-v*` tag; that is the whole update.

## Before clicking submit

- `versionName`/`versionCode` in `android/app/build.gradle.kts` must match the
  `Builds` entry, and the changelog file must exist for that versionCode.
- The tag must exist on GitHub and point at a commit that builds. `android-v0.1.0`
  is that tag; check `git ls-remote --tags` before submitting.
- `bash test/android-test.sh` verifies the metadata fields that can be checked
  locally.
