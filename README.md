# freebuff-native-termux

Run the Freebuff CLI natively inside Termux: glibc-runner plus the pristine
upstream binary, on the Android kernel, with no proot and no ptrace.

| file | what it is |
| --- | --- |
| `freebuff-native-termux.md` | the investigation: why the released binary cannot run as-is, every step, and what was actually observed on an unrooted device |
| `freebuff-native-termux.sh` | the same steps as an idempotent installer |
| `shim/freebuff-spawn-shim.c` | the `LD_PRELOAD` object that repairs freebuff's broker re-exec (upstream #1688) |
| `packaging/termux/build-deb.sh` | builds the Termux `.deb` (installer + prebuilt shim, no 136 MB payload) |
| `test/installer-test.sh` | the installer test suite the workflow runs |
| `test/shim-test.sh` | behavioural tests for the shim, with two small C fixtures in `test/shim/` |
| `test/package-test.sh` | builds a package with a throwaway prefix and inspects its contents |
| `.github/workflows/test.yml` | syntax, ShellCheck, tests and packaging on x86_64 and arm64 |
| `upstream-issue-1688.md` | snapshot of the reported upstream bug that the shim works around |

## Why it does not just run

The npm package is a launcher that unpacks a ~136 MB standalone Bun executable,
and that executable is **glibc**-linked (`/lib/ld-linux-aarch64.so.1`). Termux is
bionic and has no such loader, so `execve()` fails with `ENOENT` — which looks
like a missing binary but is really a missing interpreter.

The fix is to start the binary *through* a glibc loader that Termux does provide.
The binary is never modified: `patchelf`-ing its `PT_INTERP` makes the Bun
standalone executable segfault on every launch.

## Usage

```bash
./freebuff-native-termux.sh --check      # report status, change nothing
./freebuff-native-termux.sh --dry-run    # print the plan
./freebuff-native-termux.sh --download   # fetch the current release (needs network)
./freebuff-native-termux.sh              # install or repair from a local copy
./freebuff-native-termux.sh --from DIR   # import binary/credentials from DIR
```

`--download` resolves the current version through the npm metadata, verifies the
archive against its published sha256, and installs `freebuff` and
`tree-sitter.wasm` (the archive has no ripgrep, so the native `ripgrep` package
is installed if neither `~/.config/manicode/rg` nor `$PREFIX/bin/rg` exists).
`--from` remains the offline path; a plain install and `--from` also import
credentials, while `--download` deliberately leaves an old proot rootfs alone.

Re-running is the way to repair an install: each step detects what is already in
place, so a second run reports `0 change(s) applied`. A cached release archive is
re-used while its checksum still matches.

### Install from the `.deb`

Prebuilt packages for aarch64 and x86_64 are attached to the
[v1.0.0 release](https://github.com/MBanucu/freebuff-native-termux/releases/latest).
To build one locally:

```bash
bash packaging/termux/build-deb.sh
pkg install ./dist/freebuff-native_1.0.0_aarch64.deb   # or the x86_64 package
freebuff-native --download                             # first run: glibc + release
freebuff
```

The package is about 20 KB — installer, shim source and a prebuilt shim object,
no 136 MB binary. Its `postinst` finishes setup on its own when the glibc
runtime is already present; on a first install dpkg's lock prevents installing
packages from a maintainer script, so it prints the one command to run instead.
`dpkg -r` removes the wrapper and shim but keeps `~/.config/manicode` (binary,
credentials, projects); `dpkg -P` also removes the binary and `tree-sitter.wasm`.

## Tests

```bash
bash test/installer-test.sh   # installer: fake Termux prefix, no device needed
bash test/shim-test.sh        # shim: compiles it with the host cc
bash test/package-test.sh     # .deb: builds and inspects a package, no root
```

Each installer test builds a throwaway prefix under `mktemp -d` with a stub
glibc loader that asserts the binary it was handed exists, so the suite
exercises the real installer — shim build, wrapper generation, idempotency,
`--check`, `--dry-run`, `.bak` behaviour, and the `--download` flow against a
fake release server — without touching a device or downloading 400 MB.

The package test builds a `.deb` for a throwaway prefix and checks the control
metadata, the payload paths, that the packed shim is an ELF object, and that the
maintainer scripts parse.

The shim suite compiles `shim/freebuff-spawn-shim.c` plus a launcher and a fake
loader, preloads the shim, and checks the argv rewrite, the pass-through for
ordinary execs, `posix_spawn`, and that children never inherit `LD_PRELOAD`.

## The loader bug, and the shim that fixes it

Starting the binary *through* the loader makes `process.execPath` the loader
(`$PREFIX/glibc/lib/ld-linux-aarch64.so.1`), and freebuff re-execs itself for
its terminal-command broker with that path. The child became
`ld.so --terminal-command-broker`, died before writing its protocol file, and
every command failed with `terminal command broker protocol response was
missing`. `dirname(process.execPath)` also pointed the `rg` lookup at
`$PREFIX/glibc/lib/rg`. Reported upstream as
[CodebuffAI/freebuff#1688](https://github.com/CodebuffAI/freebuff/issues/1688);
the snapshot is in `upstream-issue-1688.md`.

The installer compiles `shim/freebuff-spawn-shim.c` to
`~/.config/manicode/freebuff-spawn-shim.so` and the wrapper preloads it. It
rewrites exactly that one exec into
`ld.so --library-path … ~/.config/manicode/freebuff --terminal-command-broker`
and strips `LD_PRELOAD` from every child, so bionic `sh`, `git` and `rg` still
run. The wrapper also exports `CODEBUFF_RG_PATH`, which covers code search.

- Shell, git and code search work natively now. Verified by driving the broker
  entry by hand (protocol file `{"ok":true,"exitCode":0}`) and by
  `test/shim-test.sh`.
- Building the shim needs a compiler that can emit a glibc object (on Termux,
  `clang`). Without one the installer warns and the CLI still runs, but the
  shell tools stay broken.
- It is a workaround pinned to the current broker spawn. The upstream fix —
  resolving the bundle independently of `process.execPath` — remains the real
  one.

## Caveats

- Measured from a plain Termux shell, `freebuff --version` is ~640 ms native vs
  ~3.1 s through `proot-distro login debian` (≈4.8×). Launch is still dominated
  by mapping the 136 MB binary. See section 6 of the notes.
- `aarch64` is the verified target. The `x86_64` path is implemented and tested in
  CI, but has not been run on a device.
