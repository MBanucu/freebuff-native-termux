# Freebuff on Termux, native (no proot)

How `freebuff` was moved off `proot-distro login debian` and onto Termux's own
glibc runtime, so it runs directly on the Android kernel with no syscall
interception.

Result: `freebuff --version` → `0.2.36`, `freebuff doctor` → exit 0, and the
agent's shell works: the broker re-exec is rewritten by a small `LD_PRELOAD`
shim (section 8). All of it runs from a plain Termux shell, no proot.

---

## 1. Why it could not run before

The npm package `freebuff@0.2.36` is only a launcher. It unpacks a ~136 MB
standalone Bun executable and runs it. That executable is a **glibc** ARM64
binary:

```
$ readelf -lW ~/.config/manicode/freebuff | grep -i interpreter
      [Requesting program interpreter: /lib/ld-linux-aarch64.so.1]
$ readelf -dW ~/.config/manicode/freebuff | grep -cE 'RUNPATH|RPATH'
0
```

Termux binaries are linked against **bionic**, and there is no
`/lib/ld-linux-aarch64.so.1` on Android. When the kernel goes to load that
interpreter and finds nothing, `execve()` returns `ENOENT` — the "file not
found" that looks like a missing binary but is really a missing loader. The npm
package publishes only `linux-x64`, `linux-arm64`, `darwin-*`, `win32-*`
builds, so there is no musl/Android variant to install instead.

The old workaround was to boot a whole Debian rootfs with proot and run the
binary inside it, which works but taxes **every syscall** through ptrace path
translation.

## 2. What "native" means here

`glibc-runner` installs a complete glibc userland under `$PREFIX/glibc` and a
loader at `$PREFIX/glibc/lib/ld-linux-aarch64.so.1`. Invoking that loader
explicitly makes the kernel start a glibc process normally: glibc's own
`ld.so` resolves the libraries, and the process runs as a normal Android
process. No proot, no ptrace, no fake root, no bind mounts.

The key rule: **the binary is never modified.** It is executed *by* the loader
rather than having its `PT_INTERP` rewritten.

## 3. Exact steps performed

The same steps are automated, idempotently, by `./freebuff-native-termux.sh`
(`--check` to report, `--dry-run` to preview). The narrative below is what that
script does and why.

Environment: unrooted Android, Termux, `$PREFIX=/data/data/com.termux/files/usr`.
All commands below were run from Termux (uid = the Termux app). Note that
Termux's patched `apt`/`apt-get` refuse to run as uid 0, and inside proot the
real uid is the Termux app while `geteuid()` reports 0 — so `apt` refuses with
"Ability to run this command as root has been disabled permanently for safety
purposes." `dpkg` has no such check and was used directly.

### 3.1 Add the glibc repository

The `glibc-repo` package (`1.0`, `all`) installs one file,
`$PREFIX/etc/apt/sources.list.d/glibc.list`:

```
deb https://packages-cf.termux.dev/apt/termux-glibc/ glibc stable
```

Get its `.deb` from that repo's `Packages` index and install it:

```bash
dpkg -i glibc-repo_1.0_all.deb
```

### 3.2 Install glibc-runner and its dependency closure

Two options. On a **plain Termux shell** (not inside proot, so not uid 0):

```bash
pkg install glibc-runner
```

If `apt` is unavailable because the shell is uid 0 (this is what happened
here), resolve and install manually:

```bash
# 1. fetch and decompress the index for the glibc dist
curl -sO https://packages-cf.termux.dev/apt/termux-glibc/dists/glibc/stable/binary-aarch64/Packages.xz
xz -d Packages.xz

# 2. resolve glibc-runner + glibc and, recursively, everything in their Depends
#    (41 packages / 72.1 MB in this run), then download each .deb and install:

dpkg -i /path/to/debs/*.deb
```

Installed result:

| package | version |
|---|---|
| `glibc-runner` | `2.0-3` |
| `glibc` | `2.44` |
| total `glibc*` packages | 42 |

This creates `$PREFIX/glibc/{bin,lib,etc}` (**402 MB**), the loader
`$PREFIX/glibc/lib/ld-linux-aarch64.so.1` (242,560 bytes), and the `grun`
helper at `$PREFIX/bin/grun`.

### 3.3 Put the binary and its config where Termux can see them

The binary was previously only inside the Debian rootfs. It was copied, not
moved, and **unmodified**:

```bash
RFS=$PREFIX/var/lib/proot-distro/containers/debian/rootfs
mkdir -p ~/.config/manicode
cp $RFS/root/.config/manicode/freebuff ~/.config/manicode/freebuff
cp $RFS/root/.config/manicode/rg       ~/.config/manicode/rg
cp $RFS/root/.config/manicode/tree-sitter.wasm ~/.config/manicode/
cp $RFS/root/.config/manicode/{credentials.json,settings.json,device-key.json,analytics-id.json,freebuff-metadata.json} ~/.config/manicode/
cp -r $RFS/root/.config/manicode/projects ~/.config/manicode/ 2>/dev/null
```

Copying the credentials/config is what keeps you logged in. `rg` (ripgrep
15.2.0) runs natively as-is, so code search inside the agent works.

### 3.4 Replace the launcher with a native wrapper

`$PREFIX/bin/freebuff` was overwritten with (mode 700):

```bash
#!/data/data/com.termux/files/usr/bin/bash
# Freebuff CLI, native. The released binary is glibc-linked, so it runs on
# Termux's glibc loader (glibc-runner) on the Android kernel directly - no
# proot, no syscall interception. The binary lives where Freebuff's own
# updater keeps it (~/.config/manicode/freebuff).
unset LD_PRELOAD
export FREEBUFF_NATIVE_LOADER="$PREFIX/glibc/bin/ld.so"
export FREEBUFF_NATIVE_LIBDIR="$PREFIX/glibc/lib"
export FREEBUFF_NATIVE_BINARY="$HOME/.config/manicode/freebuff"
if [[ -f "$HOME/.config/manicode/freebuff-spawn-shim.so" ]] &&
   [[ $(head -c 4 "$HOME/.config/manicode/freebuff-spawn-shim.so" 2>/dev/null) == $'\177ELF' ]]; then
    export LD_PRELOAD="$HOME/.config/manicode/freebuff-spawn-shim.so"
fi
if [[ -f "$HOME/.config/manicode/rg" ]]; then
    export CODEBUFF_RG_PATH="$HOME/.config/manicode/rg"
fi
exec "$PREFIX/glibc/bin/ld.so" --library-path "$PREFIX/glibc/lib" \
    "$HOME/.config/manicode/freebuff" "$@"
```

Three details matter:

* `unset LD_PRELOAD` — Termux exports
  `libtermux-exec-ld-preload.so`. Under a glibc process it fails with
  `error while loading shared libraries: .../glibc/lib/libc.so: invalid ELF header`
  (bionic `.so` loaded by glibc's loader), exit 127.
* `--library-path` — the binary has no `RUNPATH`, so the loader must be told
  where glibc's `libc.so.6`, `libm`, `libpthread` live.
* `FREEBUFF_NATIVE_*` and the conditional `LD_PRELOAD` configure the spawn
  shim below. The ELF check keeps a truncated or foreign shim from being
  preloaded, because Android's linker treats a bad `LD_PRELOAD` as fatal
  (glibc only warns).

`$PREFIX/glibc/bin/ld.so` is a symlink to `../lib/ld-linux-aarch64.so.1`.

### The spawn shim (upstream issue #1688)

Starting through the loader makes `process.execPath` the loader, which breaks
freebuff's terminal-command broker and its `rg` lookup (section 8).
`shim/freebuff-spawn-shim.c` is a small `LD_PRELOAD` object that fixes the
first one at the exec boundary: it rewrites the broker's re-exec into

```
ld.so --library-path $PREFIX/glibc/lib ~/.config/manicode/freebuff \
      --terminal-command-broker
```

and strips `LD_PRELOAD` from every child environment, so bionic tools (`sh`,
`git`, `rg`, …) start normally. Nothing else is intercepted, and the 136 MB
binary is not touched. `CODEBUFF_RG_PATH` (above) covers ripgrep.

Build and install it with:

```bash
clang --target=aarch64-linux-gnu -fPIC -shared -nostdlib -nostdinc -O2 \
    -o ~/.config/manicode/freebuff-spawn-shim.so \
    shim/freebuff-spawn-shim.c
```

The installer does this automatically, with clang preferred and a glibc host
`cc`/`gcc` as fallback; it refuses a compiler that targets Android, because
that object could not be preloaded by the glibc loader. If no suitable
compiler exists it warns and continues: the CLI still runs, only the shell
tools stay broken. `FREEBUFF_SHIM_LOG=/path/to/log` makes the shim append what
it rewrote (`rewrote broker exec …`); add `FREEBUFF_SHIM_TRACE=1` to log every
exec path, which is how you confirm it is interposing freebuff itself. To
confirm the preload, `LD_DEBUG=libs freebuff --version 2>&1 | grep spawn-shim`
prints `calling init: …/freebuff-spawn-shim.so`.

### 3.5 DNS

Nothing had to be done. `$PREFIX/glibc/etc/resolv.conf` is already a symlink to
`$PREFIX/etc/resolv.conf` (Termux's, containing `8.8.8.8` / `8.8.4.4`).
Verified from the glibc stack directly:

```
$ $PREFIX/glibc/bin/bash -c 'exec 3<>/dev/tcp/freebuff.com/443 && echo ok'
ok            # ~60 ms
```

(Note: `api.freebuff.com` does not resolve — that hostname does not exist; the
bionic resolver fails on it too. That is not a DNS fault.)

## 4. Verification (what was actually run and observed)

| check | result |
|---|---|
| `freebuff --version` | `0.2.36`, exit 0 |
| `freebuff --help` | renders, exit 0 |
| `freebuff doctor` | exit 0, `5–6 checks passed`, one warning: inotify watch limit 4096 |
| `run_terminal_command` | works: the broker re-exec is rewritten through the loader by the shim; protocol file `{"ok":true,"exitCode":0}` |
| `code_search` | works: the wrapper exports `CODEBUFF_RG_PATH` |
| `LD_DEBUG=libs freebuff --version` | `calling init: …/freebuff-spawn-shim.so` — the wrapper preloads it |
| from a project dir (`~/projects/wifidebug`) | works; cwd is just the cwd, no `/work` bind needed |
| `~/.config/manicode/rg --version` | `ripgrep 15.2.0`, exit 0 |
| glibc DNS | `freebuff.com` resolves/connects in ~60 ms |
| with `LD_PRELOAD` set in the env | works (wrapper unsets it) |

`doctor` intermittently reports `git`/`clock`/`network`/`tls` as "check took too
long"; it varied between runs and is load-related, not a functional failure.
The inotify warning (4096) is an Android system limit and needs root to raise.

## 5. Pitfalls (both cost real time)

1. **Never `patchelf` the binary, and never run `grun -c` on it.** Rewriting
   the ELF (`--set-interpreter` / `--set-rpath`) makes Bun's standalone
   executable segfault on every launch (exit 139), including when started via
   the loader. The fix was restoring the pristine copy from the rootfs and
   confirming with `readelf` (interpreter back to `/lib/ld-linux-aarch64.so.1`,
   zero `RUNPATH` entries). Always launch *through* the loader.
2. **Termux's `LD_PRELOAD` breaks glibc binaries** — see 3.4. It points at
   `libtermux-exec-ld-preload.so`, a bionic object a glibc process cannot load.
   The wrapper unsets it, then preloads only its own glibc-built spawn shim.

Also: `grun --set` does not exist in `glibc-runner 2.0-3`; its flags are
`--help --info --shell --teg --configure(-c) --findlib --no-linker --debug`.

## 6. Startup time: native is measurably faster

An earlier draft of this note reported "no speedup demonstrated". That
measurement was taken from **inside a proot session**, so the "native" launcher
was still being traced by proot; launch cost was dominated by noise and the
comparison could not show anything.

Measured from a plain Termux shell (no proot), `freebuff --version`, back to back
on the same device and session:

| launcher | median | range | runs |
|---|---|---|---|
| `proot-distro login debian -- … freebuff` | 3055 ms | 1867–3305 ms | 5 |
| native wrapper | 640 ms | 617–660 ms | 10 |

That is about 2.4 s (≈4.8×) less per launch, and a much tighter spread. Mapping
the 136 MB binary still dominates the native launch; what disappears is the
proot login plus ptrace translation of every syscall (and of every child the
agent spawns).

This only measures process launch. It says nothing about interactive startup
time once the TUI is running. Reproduce it yourself from a **fresh Termux
session** (not inside proot):

```bash
cd ~/projects
time freebuff --version
```

## 7. Current state and how to undo

* `$PREFIX/bin/freebuff` — native wrapper (above).
* `~/.config/manicode/freebuff-spawn-shim.so` — the `LD_PRELOAD` shim (section 8).
* `~/.config/manicode/` — binary (136,816,784 bytes, pristine), `rg`,
  `tree-sitter.wasm`, credentials, settings, projects.
* `$PREFIX/glibc/` — 402 MB glibc runtime.
* The **Debian container was kept on purpose**: `$PREFIX/bin/nixd` forwards
  `nix` into it (Nix's `/nix` store cannot live in Android's read-only `/`), so
  removing the container would remove the Nix toolchain. It is now the only
  script on `PATH` that still uses proot.
* The old proot-based freebuff wrapper was deleted, because it was dead once
  `freebuff` no longer needed the container.

To go back to proot-based freebuff, recreate a wrapper like:

```bash
#!/data/data/com.termux/files/usr/bin/bash
exec proot-distro login debian --bind "$PWD:/work" -- \
    bash -lc 'exec /root/.config/manicode/freebuff "$@"' freebuff "$@"
```

(The npm-installed launcher is still inside the container at
`/opt/node/lib/node_modules/freebuff`, and `/usr/local/bin/freebuff` there still
points at it; it is simply unused now.)

To drop the glibc runtime entirely: `rm -rf $PREFIX/glibc` and remove the
`glibc-repo` source file — but then the native wrapper stops working.

## 8. The `process.execPath` bug (#1688) and the spawn shim

`freebuff --version`, `--help`, `doctor` and the in-process file tools all
worked from the start, but every tool that spawns a process failed. This was
found after the fact, by asking the agent to run `echo ok`; the earlier
verification in section 4 never exercised the broker, which is why the install
looked complete.

Symptom, repeated on every attempt:

```
Terminal command broker failed: terminal command broker protocol response was missing

Restart Freebuff and try again.
```

`code_search` failed separately:

```
Failed to execute ripgrep: ENOENT: no such file or directory,
posix_spawn '/data/data/com.termux/files/usr/glibc/lib/rg'.
Vendored ripgrep not found; ensure @codebuff/sdk is up-to-date or set CODEBUFF_RG_PATH.
```

### Cause

Launching through the loader changes what the kernel considers the executable:

```
$ $PREFIX/glibc/bin/ld.so --library-path $PREFIX/glibc/lib $PREFIX/glibc/bin/bash \
    -c 'readlink /proc/$$/exe'
/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1
```

Bun derives `process.execPath` from `/proc/self/exe`, so inside freebuff it is
the loader, not the 136 MB bundle. The bundle then does:

* `cli/src/utils/terminal-command-broker.ts` — spawns the broker with
  `executable: process.execPath` and the flag `--terminal-command-broker`.
  What actually runs is `ld.so --terminal-command-broker`, which prints
  `ld.so: unrecognized option '--terminal-command-broker'` and exits. The exec
  itself succeeds, so no spawn error is reported; the parent only notices that
  the result file was never written.
* `cli/src/native/ripgrep.ts` — extracts/looks for `rg` in
  `path.dirname(process.execPath)`, i.e. `$PREFIX/glibc/lib/rg`. Same assumption
  in `packages/code-map/src/init-node.ts` (`tree-sitter.wasm`) and
  `cli/src/pre-init/tree-sitter-wasm.ts`.

This is not specific to Termux: any launcher that execs the bundle through an
explicit interpreter (glibc-runner, some Nix wrappers, sandboxes) hits it.

### The shim

Nothing in the environment can override the broker's executable, so the
workaround lives one layer down, in the process itself:
`shim/freebuff-spawn-shim.c` is a freestanding `LD_PRELOAD` object (no libc
headers — Termux's include path is bionic and must not leak into a glibc
object) that interposes `execve`, plus `posix_spawn`/`posix_spawnp` defensively.
The binary imports `execve@GLIBC_2.17`, which is why the first hook is the one
that matters.

On the one exec whose `path` is the loader **and** whose argv contains
`--terminal-command-broker`, it rewrites:

```
ld.so --terminal-command-broker
```

into:

```
ld.so --library-path $PREFIX/glibc/lib ~/.config/manicode/freebuff \
      --terminal-command-broker
```

Everything else passes through untouched. Every child environment also loses
`LD_PRELOAD`, because bionic tools (`sh`, `git`, `rg`) cannot load the glibc
shim; the wrapper exports the three paths the shim needs
(`FREEBUFF_NATIVE_LOADER`, `FREEBUFF_NATIVE_LIBDIR`, `FREEBUFF_NATIVE_BINARY`).
`CODEBUFF_RG_PATH` is set the same way, which fixes `code_search` without a
shim rewrite.

Observed on the device, driving the broker entry exactly as freebuff spawns it:

```
$ env LD_PRELOAD=~/.config/manicode/freebuff-spawn-shim.so … \
    $PREFIX/glibc/lib/ld-linux-aarch64.so.1 --library-path $PREFIX/glibc/lib \
    $PREFIX/glibc/bin/bash -c 'exec "$FREEBUFF_NATIVE_LOADER" --terminal-command-broker' \
    < request.json
E2E_OK
$ cat protocol.json
{"ok":true,"exitCode":0}
$ cat shim.log
[spawn-shim] rewrote broker exec through the loader
```

The same command without the shim still fails with
`ld.so: unrecognized option '--terminal-command-broker'` and writes no protocol
file, which is the original bug.

That only proves the loader side. The other half is that freebuff's own spawns
really go through the interposed `execve`: with `FREEBUFF_SHIM_TRACE` set, a
plain `freebuff doctor` (which runs `node`, `ps` and `git`) shows them arriving
at the hook, so the broker re-exec cannot bypass it:

```
$ FREEBUFF_SHIM_LOG=$TMPDIR/shim.log FREEBUFF_SHIM_TRACE=1 freebuff doctor
…
No problems found. 8 checks passed.
$ cat $TMPDIR/shim.log
[exec] /data/data/com.termux/files/usr/bin/node
[exec] /data/data/com.termux/files/usr/bin/ps
[exec] /data/data/com.termux/files/usr/bin/git
[exec] /data/data/com.termux/files/usr/bin/git
```

`test/shim-test.sh` compiles the shim and two fixtures with the host compiler
and asserts the rewrite (both hooks), the argument order, the pass-through for
a non-broker exec, and the `LD_PRELOAD` stripping, so the behaviour is covered
without freebuff or a device.

### Limits

* Building the shim needs a compiler that can emit a glibc object: on Termux,
  `clang` (the installer builds `--target=aarch64-linux-gnu`). If none is
  available the installer warns and leaves the shell tools broken rather than
  producing something the loader cannot preload.
* This is a workaround, not a fix: a freebuff update that changes how the
  broker is spawned could bypass the hook. The upstream request (resolve the
  bundle independently of `process.execPath`) is the durable fix.
* The shim is exercised on aarch64; the x86_64 build is only covered by CI.

Reported upstream as [CodebuffAI/freebuff#1688](https://github.com/CodebuffAI/freebuff/issues/1688).



## 9. Fetching the binary (`--download`) and the `.deb`

`--download` is the online counterpart of `--from`. It reads
`https://registry.npmjs.org/freebuff/latest`, takes `version` and the checksum in
`binaryChecksums` for this CPU, then fetches

```
https://github.com/CodebuffAI/codebuff-community/releases/download/freebuff-v<version>/freebuff-linux-<linux-arm64|linux-x64>.tar.gz
```

That is the same archive the npm launcher downloads (51,193,657 B compressed for
0.2.36, sha256 `ed752a…`). It is verified before use and cached in
`$TMPDIR/freebuff-native`, so repairing an install does not re-fetch 49 MB while
the published checksum still matches. The archive holds `freebuff` (136,816,784
B) and `tree-sitter.wasm` (205,488 B) but no `rg`: when no
`~/.config/manicode/rg` is present, the installer falls back to the native
`ripgrep` package and the wrapper points `CODEBUFF_RG_PATH` at `$PREFIX/bin/rg`.

`--download` also stays away from an old proot rootfs: unlike `--from`, it does
not silently import credentials from it (the binary and settings already in
`~/.config/manicode` are kept).

### The package

`packaging/termux/build-deb.sh` produces
`dist/freebuff-native_<version>_<arch>.deb`, about 20 KB:

```
$PREFIX/bin/freebuff-native                         launcher
$PREFIX/lib/freebuff-native/freebuff-native.sh      installer
$PREFIX/lib/freebuff-native/shim/…                  source + prebuilt object
$PREFIX/share/doc/freebuff-native/README.md
```

The shim object is built at package time with `clang --target=<arch>-linux-gnu`
(the source is freestanding, so no sysroot is needed) and stored under
`shim/prebuilt/<arch>/`, which is exactly where the installer looks first. A
package install therefore needs no compiler at all.

The binary is not packaged. `postinst` runs `freebuff-native --download` only
when the glibc runtime is already in `$PREFIX/glibc`: dpkg holds its lock while
maintainer scripts run, so a first-time `glibc-runner` install cannot happen
there. In that case it prints the single follow-up command instead. A network
failure never fails the dpkg transaction.

`dpkg -r` removes the wrapper and the generated shim and keeps
`~/.config/manicode` (binary, credentials, projects); `dpkg -P` also removes the
binary and `tree-sitter.wasm`. This is deliberate: the 136 MB download is
expensive on a phone, and credentials are user data.
