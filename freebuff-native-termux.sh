#!/data/data/com.termux/files/usr/bin/bash
#
# Installs the Freebuff CLI natively in Termux: glibc-runner plus the pristine
# upstream binary, no proot.  Companion investigation (why each piece exists):
# docs/investigation.md
#
# Idempotent.  Every step looks at what is already on disk and does only the work
# that is still missing, so re-running repairs an install instead of duplicating
# it, and a second run right after the first is a no-op.
#
# Usage:
#   ./freebuff-native-termux.sh              install or repair
#   ./freebuff-native-termux.sh --check      report status, change nothing (exit 1 if incomplete)
#   ./freebuff-native-termux.sh --dry-run    print what would happen, change nothing
#   ./freebuff-native-termux.sh --force      redo the glibc runtime and the wrapper
#   ./freebuff-native-termux.sh --from DIR   copy binary/credentials from DIR
#   ./freebuff-native-termux.sh --download   fetch the official release for this CPU
#   ./freebuff-native-termux.sh --no-creds   do not copy credentials and settings
#
# --download resolves the current release through the npm metadata, verifies the
# archive's sha256, and installs the binary plus tree-sitter.wasm.  It needs
# network access; --from remains the offline path.
#
# The binary is never modified.  It is started *by* the glibc loader, because
# patching its PT_INTERP with patchelf makes the Bun standalone executable
# segfault on every launch (see section 5 of docs/investigation.md).
#
# The work lives in lib/, one file per concern:
#   common.sh   messages, downloads, package installs, hashing
#   termux.sh   environment checks and CPU/loader mapping
#   glibc.sh    package index, dependency closure, runtime installation
#   config.sh   the freebuff binary, parser data, credentials and ripgrep
#   release.sh  the official release download and checksum
#   shim.sh     the LD_PRELOAD spawn shim (upstream #1688)
#   wrapper.sh  the generated launcher and the final health check

set -euo pipefail

# Filled in by init_paths() once the Termux checks pass.  Declared empty so the
# individual helpers (and the test harness that sources single functions) can be
# used under `set -u` without ordering assumptions.
declare CFG='' BIN='' GLIBC_DIR='' WRAPPER='' CACHE='' PKGARCH='' LOADER=''
declare IDX_PATH='' MACHINE='' SHIM='' SHIM_SRC='' SHIM_TARGET='' SHIM_PREBUILT=''
declare RELEASE_TARGET='' RELEASE_VERSION='' RELEASE_SUM='' RELEASE_URL=''
FORCE=0 DRY_RUN=0 CHECK=0 COPY_CREDS=1 FROM='' DOWNLOAD=0
CHANGED=0 MISSING=0

# Resolved without dirname(1), which a bare Termux install may not have.
SCRIPT_DIR=${BASH_SOURCE[0]%/*}
if [[ $SCRIPT_DIR == "${BASH_SOURCE[0]}" ]]; then SCRIPT_DIR=.; fi
SCRIPT_DIR=$(cd "$SCRIPT_DIR" && pwd)

for module in common termux glibc config release shim wrapper; do
    if [[ ! -f $SCRIPT_DIR/lib/$module.sh ]]; then
        printf '[x] missing installer module: %s\n' "$SCRIPT_DIR/lib/$module.sh" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/$module.sh"
done

# Print the header's Usage block without depending on sed/awk: a bare Termux
# install has neither.
usage() {
    local line p=0
    while IFS= read -r line; do
        if [[ $line == '# Usage:'* ]]; then p=1; fi
        ((p)) || continue
        [[ $line == '#' ]] && break
        [[ $line == '#'* ]] || break
        line=${line#\#}
        printf '%s\n' "${line# }"
    done <"$0"
}

parse_cli_args() {
    while (($#)); do
        case $1 in
            -n|--dry-run) DRY_RUN=1 ;;
            -c|--check)   CHECK=1 ;;
            -f|--force)   FORCE=1 ;;
            --download)   DOWNLOAD=1 ;;
            --no-creds)   COPY_CREDS=0 ;;
            --from)
                (($# >= 2)) || die "--from needs a directory"
                FROM=$2
                shift
                ;;
            --from=*) FROM=${1#--from=} ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown option: $1 (try --help)" ;;
        esac
        shift
    done
    # --check must not change anything, so it wins over --force.
    if ((CHECK)); then FORCE=0; fi
    if ((DOWNLOAD)) && [[ -n $FROM ]]; then
        die "--download and --from cannot be combined; pick one source"
    fi
}

init_paths() {
    local line
    MACHINE=$(uname -m)
    if ! line=$(arch_triplet "$MACHINE"); then
        die "unsupported CPU: $MACHINE.
    Freebuff publishes only linux-arm64 and linux-x64 builds, and the native path
    needs a 64-bit userland (glibc-runner cannot mix 32-bit packages into one)."
    fi
    read -r PKGARCH LOADER <<<"$line"

    CFG=$HOME/.config/manicode
    BIN=$CFG/freebuff
    GLIBC_DIR=$PREFIX/glibc
    WRAPPER=$PREFIX/bin/freebuff
    CACHE=${TMPDIR:-$PREFIX/tmp}/freebuff-native
    SHIM=$CFG/freebuff-spawn-shim.so
    SHIM_SRC=$SCRIPT_DIR/shim/freebuff-spawn-shim.c
    SHIM_PREBUILT=$SCRIPT_DIR/shim/prebuilt/$PKGARCH/freebuff-spawn-shim.so
    SHIM_TARGET=$PKGARCH-linux-gnu
}

print_banner() {
    local mode=install
    if ((CHECK)); then mode='check (read only)'; fi
    if ((DRY_RUN)); then mode='dry run'; fi
    log "freebuff native installer"
    log "  prefix : $PREFIX"
    log "  arch   : $MACHINE ($PKGARCH, loader $LOADER)"
    log "  mode   : $mode"
}

finish_install() {
    if ((CHECK)); then
        if ((MISSING)); then
            warn "$MISSING item(s) missing; re-run without --check to install"
            exit 1
        fi
        ok "native install complete"
        exit 0
    fi
    if ((DRY_RUN)); then
        log "dry run: nothing was changed"
        exit 0
    fi

    verify_installation || exit 1
    ok "done, $CHANGED change(s) applied"
    log "  start it with: freebuff"
    log "  health check  : freebuff doctor"
}

main() {
    parse_cli_args "$@"
    require_termux_environment
    init_paths
    print_banner

    ensure_glibc
    ensure_config
    ensure_shim
    ensure_wrapper
    finish_install
}

# Sourcing this file must not run the installer, so the pure helpers
# (arch_triplet, packages_to_tsv, resolve_package_closure) can be exercised.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
