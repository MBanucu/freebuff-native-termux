# shellcheck shell=bash

# Termux environment checks and CPU/loader mapping.

# Every path the installer writes is derived from $PREFIX, so refuse anything
# that is not a Termux userland rather than installing into the wrong place.
require_termux_environment() {
    [[ -n ${PREFIX:-} ]] || die "PREFIX is not set; run this inside Termux, not in a desktop shell."
    [[ ${PREFIX} == *com.termux* ]] || die "PREFIX=$PREFIX does not look like Termux; refusing to write to it."
    [[ -n ${HOME:-} ]] || die "HOME is not set."
    [[ -x ${PREFIX}/bin/bash ]] || die "${PREFIX}/bin/bash is missing; this is not a Termux userland."
    command -v dpkg >/dev/null 2>&1 || die "dpkg is missing; this is not a Termux userland."

    # Inside proot (or under sudo) geteuid is 0 and Termux's patched apt refuses
    # to run at all, so the glibc step has to go through dpkg.
    if [[ $(id -u) == 0 ]]; then
        warn "uid is 0: apt refuses there, so the dpkg fallback will be used"
    fi
}

# Map the kernel's machine name to a package architecture and the name of the
# glibc dynamic loader.  Returns non-zero for anything Freebuff has no build
# for: the npm package publishes only linux-arm64 and linux-x64.
arch_triplet() { # machine
    case $1 in
        aarch64|arm64) printf '%s %s\n' aarch64 ld-linux-aarch64.so.1 ;;
        x86_64|amd64)  printf '%s %s\n' x86_64  ld-linux-x86-64.so.2 ;;
        *) return 1 ;;
    esac
}
