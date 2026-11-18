#!/data/data/com.termux/files/usr/bin/bash
#
# Installs the Freebuff CLI natively in Termux: glibc-runner plus the pristine
# upstream binary, no proot.  Companion notes (including why each piece exists):
# freebuff-native-termux.md
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
# segfault on every launch (see section 5 of the notes).

set -euo pipefail

# Where the glibc packages come from.  Overridable for mirrors.
GLIBC_REPO=${FREEBUFF_GLIBC_REPO:-https://packages-cf.termux.dev/apt/termux-glibc}

# Where --download gets the release.  The npm metadata names the current version
# and the archive's sha256, so no version is hardcoded here; the archive is the
# same file the npm installer downloads.  Both URLs are overridable for mirrors.
FREEBUFF_METADATA_URL=${FREEBUFF_METADATA_URL:-https://registry.npmjs.org/freebuff/latest}
FREEBUFF_RELEASE_BASE=${FREEBUFF_RELEASE_BASE:-https://github.com/CodebuffAI/codebuff-community/releases/download}

# Default place the old proot-based install kept the binary.  Only used as a
# source when --from is not given.
PROOT_RFS=${PREFIX:-}/var/lib/proot-distro/containers/debian/rootfs

# Filled in by main() once the Termux checks pass; declared here so `set -u`
# cannot trip over them in the helpers.
CFG= BIN= GLIBC_DIR= WRAPPER= CACHE= PKGARCH= LOADER= IDX_PATH=
SHIM= SHIM_SRC= SHIM_TARGET= SHIM_PREBUILT=
FORCE=0 DRY_RUN=0 CHECK=0 COPY_CREDS=1 FROM= DOWNLOAD=0
CHANGED=0 MISSING=0

# The shim source sits next to this script.  Resolved without dirname(1), which
# a bare Termux install may not have.
SCRIPT_DIR=${BASH_SOURCE[0]%/*}
if [[ $SCRIPT_DIR == "${BASH_SOURCE[0]}" ]]; then SCRIPT_DIR=.; fi
SCRIPT_DIR=$(cd "$SCRIPT_DIR" && pwd)

MARKER='# managed by freebuff-native-termux.sh'

# ---------------------------------------------------------------- output -----

log()  { printf '%s\n' "$*"; }
ok()   { printf '[ok] %s\n' "$*"; }
act()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

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

# ------------------------------------------------------------------ args -----

parse_args() {
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

# ---------------------------------------------------------- environment -----

require_termux() {
    [[ -n ${PREFIX:-} ]] || die "PREFIX is not set; run this inside Termux, not in a desktop shell."
    # Every path below is derived from $PREFIX, so refuse anything that is not a
    # Termux userland rather than installing into the wrong place.
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
arch_triplet() {
    case $1 in
        aarch64|arm64) printf '%s %s\n' aarch64 ld-linux-aarch64.so.1 ;;
        x86_64|amd64)  printf '%s %s\n' x86_64  ld-linux-x86-64.so.2 ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------ http -----

fetch() { # url dest
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 20 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        die "neither curl nor wget is installed; run: pkg install curl"
    fi
}

ensure_tool() { # name
    if command -v "$1" >/dev/null 2>&1; then return 0; fi
    act "installing $1"
    if ((DRY_RUN)); then return 0; fi
    pkg install -y "$1" >/dev/null 2>&1 || die "could not install $1"
    CHANGED=$((CHANGED + 1))
}

# Sets IDX_PATH rather than printing it: callers run under $(...) and any
# progress line on stdout would end up inside the path.
fetch_index() {
    local xz=$CACHE/Packages.xz txt=$CACHE/Packages."$PKGARCH"
    mkdir -p "$CACHE"
    if ((FORCE)) || [[ ! -s $txt ]]; then
        ensure_tool xz
        act "downloading the glibc package index ($PKGARCH)"
        fetch "$GLIBC_REPO/dists/glibc/stable/binary-$PKGARCH/Packages.xz" "$xz" || return 1
        xz -dc "$xz" >"$txt" || return 1
        CHANGED=$((CHANGED + 1))
    fi
    IDX_PATH=$txt
}

# ------------------------------------------------- dependency resolution -----
#
# The glibc runtime is ~41 packages.  apt would order them, but apt cannot run
# when euid is 0.  So resolve the closure by hand from the Packages index: one
# tab-separated line per stanza, then a breadth-first walk over Depends.

index_tsv() { # Packages -> pkg \t version \t filename \t deps
    local line pkg='' ver='' fn='' deps=''
    emit() {
        if [[ -n $pkg ]]; then
            printf '%s\t%s\t%s\t%s\n' "$pkg" "$ver" "$fn" "$deps"
        fi
    }
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ -z $line ]]; then
            emit
            pkg='' ver='' fn='' deps=''
            continue
        fi
        case $line in
            'Package: '*)  pkg=${line#Package: } ;;
            'Version: '*)  ver=${line#Version: } ;;
            'Filename: '*) fn=${line#Filename: } ;;
            'Depends: '*|'Pre-Depends: '*)
                local more=${line#*: }
                deps=${deps:+$deps,}$more
                ;;
        esac
    done <"$1"
    emit
}

# resolve_closure <tsv> <package...> -> pkg \t version \t filename
resolve_closure() {
    local tsv=$1
    shift
    local -A ver_of=()
    local -A fn_of=()
    local -A deps_of=()
    local -A seen=()
    local pkg ver fn deps
    while IFS=$'\t' read -r pkg ver fn deps; do
        ver_of[$pkg]=$ver
        fn_of[$pkg]=$fn
        deps_of[$pkg]=$deps
    done <"$tsv"

    local -a queue=("$@")
    local -a alts=()
    while ((${#queue[@]})); do
        pkg=${queue[0]}
        queue=("${queue[@]:1}")
        if [[ -n ${seen[$pkg]:-} ]]; then continue; fi
        seen[$pkg]=1
        if [[ -z ${fn_of[$pkg]:-} ]]; then
            warn "package $pkg is not in the $PKGARCH index; skipping"
            continue
        fi
        printf '%s\t%s\t%s\n' "$pkg" "${ver_of[$pkg]}" "${fn_of[$pkg]}"
        IFS=',' read -r -a alts <<<"${deps_of[$pkg]:-}"
        local alt first
        for alt in "${alts[@]}"; do
            alt=${alt//[[:space:]]/}
            alt=${alt%%\(*}   # drop "(>= 1.0)" version constraints
            alt=${alt%%:*}    # drop ":any" multi-arch suffixes
            first=${alt%%|*}  # first alternative of "a | b"
            if [[ -n $first ]]; then queue+=("$first"); fi
        done
    done
}

# ---------------------------------------------------------------- glibc -----

glibc_ready() {
    [[ -e $GLIBC_DIR/lib/libc.so.6 ]] || return 1
    [[ -e $GLIBC_DIR/bin/ld.so || -e $GLIBC_DIR/lib/$LOADER ]] || return 1
}

add_glibc_repo() {
    local src=$PREFIX/etc/apt/sources.list.d/glibc.list
    if grep -qs 'termux-glibc' "$src"; then
        ok "glibc apt source already present"
        return 0
    fi
    act "adding the glibc apt source"
    if pkg install -y glibc-repo >/dev/null 2>&1 && grep -qs 'termux-glibc' "$src"; then
        CHANGED=$((CHANGED + 1))
        return 0
    fi
    # glibc-repo ships exactly one file, so writing it is equivalent when the
    # package cannot be installed (uid 0, stale index, offline mirror).
    warn "glibc-repo package unavailable; writing the source line directly"
    mkdir -p "${src%/*}"
    printf 'deb %s/ glibc stable\n' "$GLIBC_REPO" >"$src"
    CHANGED=$((CHANGED + 1))
}

install_glibc_apt() {
    add_glibc_repo
    # The new source has no index yet; without this pkg cannot find glibc-runner.
    pkg update -y >"$CACHE/apt-update.log" 2>&1 || warn "pkg update failed (see $CACHE/apt-update.log)"
    pkg install -y glibc-runner
}

install_glibc_dpkg() {
    fetch_index || die "cannot download the glibc index for $PKGARCH; is $GLIBC_REPO reachable?"
    local tsv=$CACHE/Packages."$PKGARCH".tsv
    index_tsv "$IDX_PATH" >"$tsv"

    local -a want=()
    local -a debs=()
    mapfile -t want < <(resolve_closure "$tsv" glibc-runner)
    ((${#want[@]})) || die "glibc-runner is not in the $PKGARCH index"

    local pkg ver fn have deb
    while IFS=$'\t' read -r pkg ver fn; do
        # Re-running should not re-download 72 MB of packages already present.
        have=$(dpkg-query -W -f '${Version}' "$pkg" 2>/dev/null || true)
        if [[ $have == "$ver" ]]; then
            ok "$pkg $ver already installed"
            continue
        fi
        mkdir -p "$CACHE/debs"
        deb=$CACHE/debs/${fn##*/}
        if [[ ! -s $deb ]]; then
            act "downloading $pkg $ver"
            fetch "$GLIBC_REPO/$fn" "$deb" || die "download failed: $GLIBC_REPO/$fn"
            CHANGED=$((CHANGED + 1))
        fi
        debs+=("$deb")
    done < <(printf '%s\n' "${want[@]}")

    if ((${#debs[@]})); then
        act "installing ${#debs[@]} package(s) with dpkg"
        if ! dpkg -i "${debs[@]}" >"$CACHE/dpkg.log" 2>&1; then
            warn "dpkg reported problems; finishing configuration (see $CACHE/dpkg.log)"
            dpkg --configure -a >>"$CACHE/dpkg.log" 2>&1 || true
        fi
        CHANGED=$((CHANGED + 1))
    fi
}

ensure_glibc() {
    if glibc_ready && ((!FORCE)); then
        ok "glibc runtime present ($GLIBC_DIR, loader $LOADER)"
        return 0
    fi
    if ((CHECK)); then
        warn "missing: glibc runtime in $GLIBC_DIR"
        MISSING=$((MISSING + 1))
        return 0
    fi
    if ((DRY_RUN)); then
        act "would install glibc-runner + glibc into $GLIBC_DIR ($PKGARCH)"
        return 0
    fi

    act "installing the glibc runtime into $GLIBC_DIR"
    mkdir -p "$CACHE"
    if ! install_glibc_apt; then
        warn "apt could not install glibc-runner; resolving the closure with dpkg instead"
    fi
    # apt failing silently (uid 0, wrong arch) is exactly the case the doc hit.
    if ! glibc_ready; then
        install_glibc_dpkg
    fi
    glibc_ready || die "glibc runtime is still incomplete: $GLIBC_DIR/lib/$LOADER is missing.
    See $CACHE/dpkg.log.  Do not 'fix' this by patching the freebuff binary."
    ok "glibc runtime ready ($GLIBC_DIR)"
}

# ------------------------------------------------------- binary + config -----

# The binary must be a pristine ELF that still asks for the glibc loader.  Only
# the first 8 KiB is read: .interp sits in the first page, and grepping 136 MB
# on a phone is slow.
binary_ok() { # [file], default $BIN
    local bin=${1:-$BIN}
    [[ -s $bin ]] || return 1
    [[ $(head -c 4 "$bin") == $'\177ELF' ]] || return 1
    head -c 8192 "$bin" | grep -qa 'ld-linux' || return 1
}

find_source() {
    local cand=()
    if [[ -n $FROM ]]; then
        # Accept either the manicode directory itself or a rootfs above it.
        cand+=("$FROM" "$FROM/root/.config/manicode")
    else
        cand+=("$PROOT_RFS/root/.config/manicode")
    fi
    local c
    for c in "${cand[@]}"; do
        if [[ -f $c/freebuff ]]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

copy_if_missing() { # src dst
    local src=$1 dst=$2
    if [[ -e $dst ]]; then
        ok "kept existing ${dst##*/}"
        return 0
    fi
    if ((DRY_RUN)); then
        act "would copy ${dst##*/} from $src"
        return 0
    fi
    cp -a "$src" "$dst"
    CHANGED=$((CHANGED + 1))
    act "copied ${dst##*/}"
}

# ---------------------------------------------------------------- download -----

# The release publishes one archive per CPU.  These names are the keys of the
# npm checksum object and the tail of the archive filename.
release_target() { # pkgarch
    case $1 in
        aarch64) printf 'linux-arm64\n' ;;
        x86_64)  printf 'linux-x64\n' ;;
        *) return 1 ;;
    esac
}

# Read a string from the compact npm metadata without jq: the document is
# machine-generated and each key appears once, and the values wanted here
# (version, hex checksums) are plain strings.
json_string() { # key file
    local m
    m=$(grep -o "\"$1\":\"[^\"]*\"" "$2" 2>/dev/null | head -n 1) || return 1
    [[ -n $m ]] || return 1
    m=${m#*:\"}
    printf '%s\n' "${m%\"}"
}

sha256_of() { # file
    local out
    if command -v sha256sum >/dev/null 2>&1; then
        out=$(sha256sum "$1") || return 1
        out=${out%% *}
    elif command -v shasum >/dev/null 2>&1; then
        out=$(shasum -a 256 "$1") || return 1
        out=${out%% *}
    elif command -v openssl >/dev/null 2>&1; then
        out=$(openssl dgst -sha256 "$1") || return 1
        out=${out##* }
    else
        return 1
    fi
    printf '%s\n' "$out"
}

# Fetch the current release, check it against the published sha256, and install
# the binary plus tree-sitter.wasm (the archive has no ripgrep).  The archive
# stays in $CACHE, so a repair run re-downloads only when the version changes or
# the cached file is damaged.
install_from_download() {
    local target ver sum url tgz meta dir got
    target=$(release_target "$PKGARCH") || die "no release archive for $PKGARCH"
    tgz=$CACHE/freebuff-$target.tar.gz
    meta=$CACHE/freebuff-latest.json

    if ((DRY_RUN)); then
        act "would download the latest freebuff release for $target"
        return 0
    fi
    command -v tar >/dev/null 2>&1 || die "tar is missing; run: pkg install tar"

    mkdir -p "$CACHE"
    act "resolving the current freebuff release"
    fetch "$FREEBUFF_METADATA_URL" "$meta" || die "cannot read $FREEBUFF_METADATA_URL
    (no network? --from DIR installs from a local copy instead)"
    ver=$(json_string version "$meta") || die "no version in $FREEBUFF_METADATA_URL"
    sum=$(json_string "$target" "$meta") ||
        die "the release metadata has no checksum for $target"
    url=$FREEBUFF_RELEASE_BASE/freebuff-v$ver/freebuff-$target.tar.gz

    got=''
    if [[ -s $tgz ]]; then got=$(sha256_of "$tgz" || true); fi
    if [[ -n $got && $got == "$sum" ]]; then
        ok "freebuff $ver archive already downloaded"
    else
        if [[ -e $tgz ]]; then
            warn "discarding a cached archive that does not match the checksum"
            rm -f "$tgz"
        fi
        act "downloading freebuff $ver ($target)"
        fetch "$url" "$tgz" || die "download failed: $url"
        CHANGED=$((CHANGED + 1))
        got=$(sha256_of "$tgz" || true)
        if [[ $got != "$sum" ]]; then
            rm -f "$tgz"
            die "checksum mismatch for $url
    expected $sum
    got      ${got:-<no sha256 tool; pkg install coreutils>}"
        fi
        ok "checksum verified (sha256 $sum)"
    fi

    dir=$CACHE/extract-$target
    rm -rf "$dir"
    mkdir -p "$dir"
    tar -xzf "$tgz" -C "$dir" || die "cannot extract $tgz"
    binary_ok "$dir/freebuff" || die "$url did not contain a usable freebuff binary"

    mkdir -p "$CFG"
    if [[ -e $BIN ]] && ! binary_ok; then
        warn "existing binary is unusable; moved aside to $(basename "$BIN").bak"
        mv -f "$BIN" "$BIN.bak"
    fi
    cp "$dir/freebuff" "$BIN"
    chmod 700 "$BIN"
    CHANGED=$((CHANGED + 1))

    # Ship the parser data that belongs to this binary version; a stale .wasm
    # from an older release would be silently wrong.
    if [[ -f $dir/tree-sitter.wasm ]]; then
        if [[ -f $CFG/tree-sitter.wasm ]] &&
           [[ $(sha256_of "$CFG/tree-sitter.wasm") == "$(sha256_of "$dir/tree-sitter.wasm")" ]]; then
            ok "tree-sitter.wasm up to date"
        else
            cp "$dir/tree-sitter.wasm" "$CFG/tree-sitter.wasm"
            CHANGED=$((CHANGED + 1))
            act "installed tree-sitter.wasm"
        fi
    fi
    rm -rf "$dir"
    ok "freebuff $ver installed ($BIN)"
}

# The release tarball ships no ripgrep, so a fresh --download has to get one.
# The native Termux package is a bionic binary and runs fine as a child process.
ensure_rg() {
    if [[ -f $CFG/rg ]]; then
        ok "ripgrep present (code search works)"
        return 0
    fi
    if [[ -x $PREFIX/bin/rg ]]; then
        ok "using ripgrep from $PREFIX/bin/rg"
        return 0
    fi
    if ((DRY_RUN)); then
        act "would install ripgrep"
        return 0
    fi
    if pkg install -y ripgrep >/dev/null 2>&1 && [[ -x $PREFIX/bin/rg ]]; then
        CHANGED=$((CHANGED + 1))
        ok "installed ripgrep ($PREFIX/bin/rg)"
        return 0
    fi
    warn "ripgrep is missing; code search will not work (run: pkg install ripgrep)"
}

ensure_config() {
    local src='' f
    # --download installs a fresh binary and must not silently harvest credentials
    # from an old proot rootfs; --from keeps that behaviour for offline moves.
    if ((!DOWNLOAD)); then src=$(find_source || true); fi

    if ((CHECK)); then
        if binary_ok; then
            ok "freebuff binary present ($(du -h "$BIN" | cut -f1))"
        else
            warn "missing or unusable: $BIN"
            MISSING=$((MISSING + 1))
        fi
        if [[ -f $CFG/rg || -x $PREFIX/bin/rg ]]; then
            ok "ripgrep present (code search works)"
        else
            warn "missing: ripgrep (install it with: pkg install ripgrep)"
            MISSING=$((MISSING + 1))
        fi
        if [[ ! -f $CFG/tree-sitter.wasm ]]; then
            warn "missing: $CFG/tree-sitter.wasm (parsing falls back, search still works)"
        fi
        return 0
    fi

    if binary_ok && ((!FORCE)); then
        ok "freebuff binary present ($(du -h "$BIN" | cut -f1))"
    elif ((DOWNLOAD)); then
        install_from_download
    else
        [[ -n $src ]] || die "no freebuff binary found to install.
    Pass --from with the directory holding the old copy, for example the
    root/.config/manicode of the proot Debian rootfs, or a backup of it.
    Or pass --download to fetch the official release."
        if ((DRY_RUN)); then
            act "would copy the binary and its data files from $src"
            return 0
        fi
        mkdir -p "$CFG"
        # Keep a broken copy instead of deleting it: it is the evidence needed to
        # tell a patched binary from a truncated one.
        if [[ -e $BIN ]]; then
            warn "existing binary is unusable; moved aside to $(basename "$BIN").bak"
            mv -f "$BIN" "$BIN.bak"
        fi
        act "copying the freebuff binary from $src"
        cp "$src/freebuff" "$BIN"
        chmod 700 "$BIN"
        CHANGED=$((CHANGED + 1))
    fi

    # Nothing to import from: whatever is already in $CFG stays as it is.
    if ((!DRY_RUN)) && [[ -n $src ]]; then
        # ripgrep runs natively as-is, which is what keeps the agent's code search
        # working; tree-sitter.wasm is needed for parsing.
        for f in rg tree-sitter.wasm; do
            if [[ -f $src/$f ]]; then copy_if_missing "$src/$f" "$CFG/$f"; fi
        done

        if ((COPY_CREDS)); then
            # Existing files win: they may be newer than the copy being imported (the
            # old install kept refreshing its token).
            for f in credentials.json settings.json device-key.json analytics-id.json freebuff-metadata.json; do
                if [[ -f $src/$f ]]; then copy_if_missing "$src/$f" "$CFG/$f"; fi
            done
            if [[ -d $src/projects && ! -d $CFG/projects ]]; then
                cp -a "$src/projects" "$CFG/projects"
                CHANGED=$((CHANGED + 1))
                act "copied projects/"
            fi
        else
            ok "skipped credentials and settings (--no-creds)"
        fi
    fi
    ensure_rg
}

# ------------------------------------------------------------ spawn shim -----
#
# Workaround for upstream issue #1688: freebuff re-execs itself for its
# terminal-command broker with `process.execPath`, which is the *glibc loader*
# when the CLI was started through one.  A small LD_PRELOAD object rewrites that
# single exec into `ld.so --library-path DIR BINARY --terminal-command-broker`
# and strips LD_PRELOAD from every child, so bionic tools can still start.
# shim/freebuff-spawn-shim.c documents the details.

shim_compiler() {
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

shim_ready() { [[ -s $SHIM ]]; }

ensure_shim() {
    if shim_ready && ((!FORCE)); then
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

    # Packaging ships an object per architecture so a .deb install needs no
    # compiler at all; check the magic anyway, because a text file here would be
    # fatal to Android's linker.
    if [[ -s $SHIM_PREBUILT ]]; then
        if [[ $(head -c 4 "$SHIM_PREBUILT") == $'\177ELF' ]]; then
            act "installing the prebuilt spawn shim"
            mkdir -p "${SHIM%/*}"
            cp "$SHIM_PREBUILT" "$SHIM.tmp"
            chmod 700 "$SHIM.tmp"
            mv -f "$SHIM.tmp" "$SHIM"
            CHANGED=$((CHANGED + 1))
            ok "spawn shim installed ($SHIM)"
            return 0
        fi
        warn "ignoring $SHIM_PREBUILT: not an ELF object"
    fi

    # A failed build is never fatal: without the shim the CLI still starts and
    # file tools work; only the shell-related tools stay broken.
    if [[ ! -s $SHIM_SRC ]]; then
        warn "no shim source at $SHIM_SRC"
        warn "skipping it; the agent's shell, git and code search will not work"
        return 0
    fi
    local cc
    if ! cc=$(shim_compiler); then
        warn "no C compiler (clang, gcc or cc) found; skipping the spawn shim"
        warn "install one (pkg install clang) and re-run, or set FREEBUFF_SHIM_CC"
        return 0
    fi

    act "building the spawn shim with $cc"
    mkdir -p "${SHIM%/*}"
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
                warn "skipping it; the agent's shell, git and code search will not work"
                return 0
            fi
            ;;
    esac
    # -nostdinc/-nostdlib: the source is freestanding, and Termux's include path
    # holds bionic headers that must not leak into a glibc object.
    cmd+=(-fPIC -shared -nostdlib -nostdinc -O2 -Wall -Wextra
          -o "$SHIM.tmp" "$SHIM_SRC")
    if ! "${cmd[@]}"; then
        rm -f "$SHIM.tmp"
        warn "could not build the spawn shim with $cc"
        warn "skipping it; the agent's shell, git and code search will not work"
        return 0
    fi
    chmod 700 "$SHIM.tmp"
    mv -f "$SHIM.tmp" "$SHIM"
    CHANGED=$((CHANGED + 1))
    ok "spawn shim built ($SHIM)"
}

# --------------------------------------------------------------- wrapper -----

wrapper_text() {
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

ensure_wrapper() {
    local want
    want=$(wrapper_text)

    if ((CHECK)); then
        if [[ ! -f $WRAPPER ]]; then
            warn "missing: wrapper at $WRAPPER"
            MISSING=$((MISSING + 1))
        elif ! grep -qF "$MARKER" "$WRAPPER"; then
            # Someone else's wrapper (the npm launcher, or the hand-written one
            # from the notes).  It may work, so do not call the install missing;
            # the next install run backs it up and replaces it.
            warn "unmanaged wrapper at $WRAPPER (install would back it up and replace it)"
        elif [[ $(cat "$WRAPPER") != "$want" ]]; then
            warn "wrapper out of date at $WRAPPER (install would update it)"
            MISSING=$((MISSING + 1))
        else
            ok "wrapper up to date ($WRAPPER)"
        fi
        return 0
    fi

    if [[ -f $WRAPPER ]] && grep -qF "$MARKER" "$WRAPPER"; then
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
        printf '    would write:\n'
        printf '%s\n' "$want" | while IFS= read -r line; do printf '    | %s\n' "$line"; done
        return 0
    fi
    mkdir -p "${WRAPPER%/*}"
    printf '%s\n' "$want" >"$WRAPPER.tmp"
    chmod 700 "$WRAPPER.tmp"
    mv -f "$WRAPPER.tmp" "$WRAPPER"
    CHANGED=$((CHANGED + 1))
    ok "wrapper installed ($WRAPPER)"
}

# ---------------------------------------------------------------- verify -----

verify() {
    local out
    if out=$(timeout 120 "$WRAPPER" --version 2>&1); then
        ok "freebuff --version -> $out"
        return 0
    fi
    warn "freebuff --version failed: ${out%%$'\n'*}"
    warn "run 'freebuff doctor' for detail; see section 5 of the notes"
    return 1
}

# ------------------------------------------------------------------ main -----

main() {
    parse_args "$@"
    require_termux

    local machine line
    machine=$(uname -m)
    if ! line=$(arch_triplet "$machine"); then
        die "unsupported CPU: $machine.
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

    local mode=install
    if ((CHECK)); then mode='check (read only)'; fi
    if ((DRY_RUN)); then mode='dry run'; fi
    log "freebuff native installer"
    log "  prefix : $PREFIX"
    log "  arch   : $machine ($PKGARCH, loader $LOADER)"
    log "  mode   : $mode"

    ensure_glibc
    ensure_config
    ensure_shim
    ensure_wrapper

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

    verify || exit 1
    ok "done, $CHANGED change(s) applied"
    log "  start it with: freebuff"
    log "  health check  : freebuff doctor"
}

# Sourcing this file must not run the installer, so the pure helpers
# (arch_triplet, index_tsv, resolve_closure) can be exercised on their own.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
