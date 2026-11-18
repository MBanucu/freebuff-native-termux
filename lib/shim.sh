# shellcheck shell=bash

# The LD_PRELOAD spawn shim (upstream issue #1688).
#
# freebuff re-execs itself for its terminal-command broker with
# `process.execPath`, which is the *glibc loader* when the CLI was started
# through one.  A small LD_PRELOAD object rewrites that single exec into
# `ld.so --library-path DIR BINARY --terminal-command-broker` and strips
# LD_PRELOAD from every child, so bionic tools can still start.
# shim/freebuff-spawn-shim.c documents the details.

shim_is_present() { [[ -s $SHIM ]]; }

find_shim_compiler() {
    local c
    if [[ -n ${FREEBUFF_SHIM_CC:-} ]]; then
        printf '%s\n' "$FREEBUFF_SHIM_CC"
        return 0
    fi
    for c in clang gcc cc; do
        if command -v "$c" >/dev/null 2>&1; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

# Packaging ships an object per architecture so a .deb install needs no
# compiler.  Check the magic anyway, because Android's linker treats a text file
# in LD_PRELOAD as fatal.
install_prebuilt_shim() {
    [[ -s $SHIM_PREBUILT ]] || return 1
    if [[ $(head -c 4 "$SHIM_PREBUILT") != $'\177ELF' ]]; then
        warn "ignoring $SHIM_PREBUILT: not an ELF object"
        return 1
    fi
    act "installing the prebuilt spawn shim"
    mkdir -p "${SHIM%/*}"
    cp "$SHIM_PREBUILT" "$SHIM.tmp"
    chmod 700 "$SHIM.tmp"
    mv -f "$SHIM.tmp" "$SHIM"
    CHANGED=$((CHANGED + 1))
    ok "spawn shim installed ($SHIM)"
    return 0
}

compile_shim() { # compiler
    local cc=$1
    local -a cmd=("$cc")
    # Termux's compiler defaults to a bionic target; the shim is loaded by the
    # glibc loader, so it must be a glibc-userland object.  gcc/cc have no
    # --target here, and do not need one on a glibc host.
    case ${cc##*/} in
        *clang*) cmd+=(--target="$SHIM_TARGET") ;;
        *)
            # A Termux gcc/cc would produce a bionic object that the glibc loader
            # cannot preload; that is worse than no shim at all.
            if "$cc" -dM -E - </dev/null 2>/dev/null | grep -q '__ANDROID__'; then
                warn "$cc targets Android/bionic; a preloadable shim needs clang"
                return 1
            fi
            ;;
    esac

    act "building the spawn shim with $cc"
    mkdir -p "${SHIM%/*}"
    # -nostdinc/-nostdlib: the source is freestanding, and Termux's include path
    # holds bionic headers that must not leak into a glibc object.
    cmd+=(-fPIC -shared -nostdlib -nostdinc -O2 -Wall -Wextra
          -o "$SHIM.tmp" "$SHIM_SRC")
    if ! "${cmd[@]}"; then
        rm -f "$SHIM.tmp"
        warn "could not build the spawn shim with $cc"
        return 1
    fi
    chmod 700 "$SHIM.tmp"
    mv -f "$SHIM.tmp" "$SHIM"
    CHANGED=$((CHANGED + 1))
    ok "spawn shim built ($SHIM)"
}

# A failed build is never fatal: without the shim the CLI still starts and file
# tools work; only the shell-related tools stay broken.
ensure_shim() {
    if shim_is_present && ((!FORCE)); then
        ok "spawn shim present ($SHIM)"
        return 0
    fi
    if ((CHECK)); then
        warn "missing: spawn shim at $SHIM (the agent's shell would not work)"
        MISSING=$((MISSING + 1))
        return 0
    fi
    if ((DRY_RUN)); then
        if [[ -s $SHIM_PREBUILT ]]; then
            act "would install the prebuilt spawn shim ($SHIM_PREBUILT)"
        else
            act "would build the spawn shim from $SHIM_SRC"
        fi
        return 0
    fi

    if install_prebuilt_shim; then return 0; fi

    if [[ ! -s $SHIM_SRC ]]; then
        warn "no shim source at $SHIM_SRC"
        warn "skipping it; the agent's shell, git and code search will not work"
        return 0
    fi
    local cc
    if ! cc=$(find_shim_compiler); then
        warn "no C compiler (clang, gcc or cc) found; skipping the spawn shim"
        warn "install one (pkg install clang) and re-run, or set FREEBUFF_SHIM_CC"
        return 0
    fi

    if ! compile_shim "$cc"; then
        warn "skipping it; the agent's shell, git and code search will not work"
    fi
}
