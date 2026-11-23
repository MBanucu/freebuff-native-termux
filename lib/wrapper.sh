# shellcheck shell=bash

# The generated `freebuff` wrapper and the final health check.

MARKER='# managed by freebuff-native-termux.sh'

render_wrapper() {
    local loader=$GLIBC_DIR/bin/ld.so
    [[ -e $loader ]] || loader=$GLIBC_DIR/lib/$LOADER
    cat <<EOF
#!$PREFIX/bin/bash
$MARKER
# Freebuff CLI, native.  The released binary is glibc-linked, so it is started by
# Termux's glibc loader on the Android kernel directly: no proot, no syscall
# interception, and no child process (rg, git, shells) path-translated.
#
# The binary stays pristine at ~/.config/manicode/freebuff and is never patchelf'd.
#
# Base launch, two details:
#   unset LD_PRELOAD   Termux exports libtermux-exec-ld-preload.so; under a glibc
#                      process that bionic .so fails to load ("invalid ELF header").
#   --library-path     the binary has no RUNPATH, so the loader must be told where
#                      libc.so.6, libm and libpthread live.
unset LD_PRELOAD
export FREEBUFF_NATIVE_LOADER="$loader"
export FREEBUFF_NATIVE_LIBDIR="$GLIBC_DIR/lib"
export FREEBUFF_NATIVE_BINARY="\$HOME/.config/manicode/freebuff"
# Upstream issue #1688: freebuff re-execs itself for its terminal-command broker
# with process.execPath, which is the loader here, so that child dies before it
# writes its result file.  The shim rewrites that one exec through the loader and
# strips LD_PRELOAD from every child, so bionic tools (sh, git, rg) still start.
# Without it the CLI runs, but the agent has no shell.
# The ELF check matters: Android's linker treats an unloadable LD_PRELOAD as
# fatal (glibc only warns), so a truncated or foreign shim would take the CLI
# down with it.  Skip it instead and stay in the degraded mode.
if [[ -f "\$HOME/.config/manicode/freebuff-spawn-shim.so" ]] &&
   [[ \$(head -c 4 "\$HOME/.config/manicode/freebuff-spawn-shim.so" 2>/dev/null) == \$'\177ELF' ]]; then
    export LD_PRELOAD="\$HOME/.config/manicode/freebuff-spawn-shim.so"
fi
# In compiled mode freebuff looks for ripgrep in dirname(process.execPath), i.e.
# $GLIBC_DIR/lib; point it at the copy that ships in ~/.config/manicode, or at
# the native Termux package when the release was installed with --download.
if [[ -f "\$HOME/.config/manicode/rg" ]]; then
    export CODEBUFF_RG_PATH="\$HOME/.config/manicode/rg"
elif [[ -x "$PREFIX/bin/rg" ]]; then
    export CODEBUFF_RG_PATH="$PREFIX/bin/rg"
fi
exec "$loader" --library-path "$GLIBC_DIR/lib" \\
    "\$HOME/.config/manicode/freebuff" "\$@"
EOF
}

wrapper_is_managed() {
    grep -qF "$MARKER" "$WRAPPER" 2>/dev/null
}

check_wrapper() { # expected wrapper text
    if [[ ! -f $WRAPPER ]]; then
        warn "missing: wrapper at $WRAPPER"
        MISSING=$((MISSING + 1))
    elif ! wrapper_is_managed; then
        # Someone else's wrapper (the npm launcher, or the hand-written one from
        # investigation).  It may work, so do not call the install missing; the next
        # install run backs it up and replaces it.
        warn "unmanaged wrapper at $WRAPPER (install would back it up and replace it)"
    elif [[ $(cat "$WRAPPER") != "$1" ]]; then
        warn "wrapper out of date at $WRAPPER (install would update it)"
        MISSING=$((MISSING + 1))
    else
        ok "wrapper up to date ($WRAPPER)"
    fi
}

preview_wrapper() { # expected wrapper text
    printf '    would write:\n'
    printf '%s\n' "$1" | while IFS= read -r line; do printf '    | %s\n' "$line"; done
}

write_wrapper() { # expected wrapper text
    mkdir -p "${WRAPPER%/*}"
    printf '%s\n' "$1" >"$WRAPPER.tmp"
    chmod 700 "$WRAPPER.tmp"
    mv -f "$WRAPPER.tmp" "$WRAPPER"
    CHANGED=$((CHANGED + 1))
    ok "wrapper installed ($WRAPPER)"
}

ensure_wrapper() {
    local want
    want=$(render_wrapper)

    if ((CHECK)); then
        check_wrapper "$want"
        return 0
    fi

    if [[ -f $WRAPPER ]] && wrapper_is_managed; then
        if [[ $(cat "$WRAPPER") == "$want" ]] && ((!FORCE)); then
            ok "wrapper up to date ($WRAPPER)"
            return 0
        fi
        act "updating the wrapper"
    elif [[ -e $WRAPPER ]]; then
        # Someone else's freebuff script (the npm launcher): keep it recoverable.
        warn "replacing unmanaged $WRAPPER (backed up to $(basename "$WRAPPER").bak)"
        if ((!DRY_RUN)); then
            mv -f "$WRAPPER" "$WRAPPER.bak"
        fi
    else
        act "installing the wrapper at $WRAPPER"
    fi

    if ((DRY_RUN)); then
        preview_wrapper "$want"
        return 0
    fi
    write_wrapper "$want"
}

verify_installation() {
    local out
    # No controlling terminal for the health check: the TUI-capable binary
    # otherwise stops on terminal I/O when the install runs inside a real
    # Termux session, leaving dpkg half-configured forever.
    if out=$(timeout -k 5 120 "$WRAPPER" --version </dev/null 2>&1); then
        ok "freebuff --version -> $out"
        return 0
    fi
    warn "freebuff --version failed: ${out%%$'\n'*}"
    warn "run 'freebuff doctor' for detail; see section 5 of docs/investigation.md"
    return 1
}
