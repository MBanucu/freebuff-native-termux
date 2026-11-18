# Upstream: CodebuffAI/freebuff#1688

Snapshot of the issue filed on 2026-11-18:
<https://github.com/CodebuffAI/freebuff/issues/1688>

Status: still open upstream, but worked around locally by
`shim/freebuff-spawn-shim.c` (see the README); the text below is what was
reported, before that workaround existed.

Title: *Terminal broker and ripgrep break when the CLI is launched through an ELF
loader (process.execPath is the loader)*

---

### What happened

I run the standalone `freebuff` binary through an explicit ELF interpreter instead of exec'ing it directly (glibc-runner on Termux/Android, no proot). The CLI starts fine, and the in-process file tools work (read/write/edit), but **every tool that spawns a process fails**:

```
Terminal command broker failed: terminal command broker protocol response was missing

Restart Freebuff and try again.
```

`code_search` fails the same way:

```
Failed to execute ripgrep: ENOENT: no such file or directory,
posix_spawn '/data/data/com.termux/files/usr/glibc/lib/rg'.
Vendored ripgrep not found; ensure @codebuff/sdk is up-to-date or set CODEBUFF_RG_PATH.
```

`freebuff doctor` passes, because it never exercises the broker.

This is not a request for official Termux support — the bug is generic to any launch that goes through a loader rather than direct `execve()` of the bundle, which is also how some Nix wrappers and sandboxed launchers work.

### Steps to reproduce

Any Linux, with the standalone binary:

```sh
# works (direct exec):
~/.config/manicode/freebuff

# starts, but every tool that spawns a command fails:
$PREFIX/glibc/bin/ld.so --library-path $PREFIX/glibc/lib ~/.config/manicode/freebuff
```

Then ask the agent to run any command (e.g. `echo ok`). File tools keep working; shell/git/code search do not.

Environment: Termux (unrooted), Android 15, aarch64; freebuff 0.2.36 standalone binary (npm launcher output) run through glibc 2.44 from glibc-runner 2.0-3.

### Why it fails

When a program is started as `ld.so prog`, the kernel's main executable is the loader, so `/proc/self/exe` — and therefore `process.execPath` — is the loader, not the bundle:

```
$ $PREFIX/glibc/bin/ld.so --library-path $PREFIX/glibc/lib $PREFIX/glibc/bin/bash -c 'readlink /proc/$$/exe'
/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1
```

`cli/src/utils/terminal-command-broker.ts` (`defaultBrokerInvocation`) spawns the broker with `executable: process.execPath`. The child that actually runs is therefore:

```
$ $PREFIX/glibc/bin/ld.so --terminal-command-broker
ld.so: unrecognized option '--terminal-command-broker'
```

`ld.so` exits immediately without writing the protocol file. Because the exec itself succeeds (it is the loader that fails), no spawn `error` is emitted; the parent only sees the missing result file and reports `protocol response was missing`.

`cli/src/native/ripgrep.ts` makes the same assumption: in compiled mode it extracts/looks for `rg` in `path.dirname(process.execPath)`, i.e. `$PREFIX/glibc/lib/rg`, which does not exist — hence the `posix_spawn .../glibc/lib/rg` ENOENT. `packages/code-map/src/init-node.ts` and `cli/src/pre-init/tree-sitter-wasm.ts` also derive asset locations from `dirname(process.execPath)`.

### Suggested fix

- Preferred: run the broker in-process (or as a worker) instead of re-exec'ing the bundle.
- If a separate process is required, resolve the bundle path independently of `process.execPath` — e.g. `process.argv[0]`/`process.argv0` when it points at the bundle, or detect a loader (`ld-linux*`, `ld.so*`) and re-exec through it: `[execPath, '--library-path', dirname(execPath), bundlePath, TERMINAL_COMMAND_BROKER_FLAG]`.
- Or expose an override for the broker command, mirroring `CODEBUFF_RG_PATH`, so launchers that exec via a loader can supply the correct command line.
- Apply the same resolution to the `dirname(process.execPath)` lookups for `rg` and `tree-sitter.wasm`.

### Workaround

`CODEBUFF_RG_PATH=~/.config/manicode/rg` fixes code search only. Nothing I can set in this environment fixes the broker, because its executable path comes from `process.execPath`; the CLI has to be launched through proot instead, which defeats the point of running it natively.

### Logs

Terminal tool result as surfaced in the session:

```
Terminal command broker failed: terminal command broker protocol response was missing

Restart Freebuff and try again.
```

Repeating the call produces the same result; restarting Freebuff does not change it.
