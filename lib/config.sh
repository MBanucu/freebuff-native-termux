# shellcheck shell=bash

# The freebuff binary, its accompanying data, and ripgrep.
#
# The binary must be a pristine ELF that still asks for the glibc loader.  Only
# the first 8 KiB is read: .interp sits in the first page, and grepping 136 MB
# on a phone is slow.

freebuff_binary_is_valid() { # [file], default $BIN
    local bin=${1:-$BIN}
    [[ -s $bin ]] || return 1
    [[ $(head -c 4 "$bin") == $'\177ELF' ]] || return 1
    head -c 8192 "$bin" | grep -qa 'ld-linux' || return 1
}

freebuff_binary_size() {
    du -h "$BIN" | cut -f1
}

find_existing_install() {
    local cand=()
    if [[ -n $FROM ]]; then
        # Accept either the manicode directory itself or a rootfs above it.
        cand+=("$FROM" "$FROM/root/.config/manicode")
    else
        # Default place the old proot-based install kept the binary.  Only used
        # as a source when --from is not given.
        cand+=("$PREFIX/var/lib/proot-distro/containers/debian/rootfs/root/.config/manicode")
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

copy_file_if_missing() { # src dst
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

# Keep a broken copy instead of deleting it: it is the evidence needed to tell a
# patched binary from a truncated one.
backup_unusable_binary() {
    if [[ -e $BIN ]] && ! freebuff_binary_is_valid; then
        warn "existing binary is unusable; moved aside to $(basename "$BIN").bak"
        mv -f "$BIN" "$BIN.bak"
    fi
}

install_binary_file() { # source file
    mkdir -p "$CFG"
    cp "$1" "$BIN"
    chmod 700 "$BIN"
    CHANGED=$((CHANGED + 1))
}

# Parser data must match the binary version; a stale .wasm from an older release
# would be silently wrong.
sync_parser_data() { # directory holding tree-sitter.wasm
    local src=$1
    [[ -f $src/tree-sitter.wasm ]] || return 0
    if [[ -f $CFG/tree-sitter.wasm ]] &&
       [[ $(sha256_of_file "$CFG/tree-sitter.wasm") == "$(sha256_of_file "$src/tree-sitter.wasm")" ]]; then
        ok "tree-sitter.wasm up to date"
        return 0
    fi
    cp "$src/tree-sitter.wasm" "$CFG/tree-sitter.wasm"
    CHANGED=$((CHANGED + 1))
    act "installed tree-sitter.wasm"
}

check_config() {
    if freebuff_binary_is_valid; then
        ok "freebuff binary present ($(freebuff_binary_size))"
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
}

# The release tarball ships no ripgrep, so a fresh --download has to get one.
# The native Termux package is a bionic binary and runs fine as a child process.
ensure_ripgrep() {
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

import_existing_files() { # source directory
    local src=$1 f
    # ripgrep runs natively as-is, which is what keeps the agent's code search
    # working; tree-sitter.wasm is needed for parsing.
    for f in rg tree-sitter.wasm; do
        if [[ -f $src/$f ]]; then copy_file_if_missing "$src/$f" "$CFG/$f"; fi
    done

    if ((COPY_CREDS)); then
        # Existing files win: they may be newer than the copy being imported (the
        # old install kept refreshing its token).
        for f in credentials.json settings.json device-key.json analytics-id.json freebuff-metadata.json; do
            if [[ -f $src/$f ]]; then copy_file_if_missing "$src/$f" "$CFG/$f"; fi
        done
        if [[ -d $src/projects && ! -d $CFG/projects ]]; then
            cp -a "$src/projects" "$CFG/projects"
            CHANGED=$((CHANGED + 1))
            act "copied projects/"
        fi
    else
        ok "skipped credentials and settings (--no-creds)"
    fi
}

ensure_freebuff_binary() { # existing source directory, or empty
    local src=$1
    if freebuff_binary_is_valid && ((!FORCE)); then
        ok "freebuff binary present ($(freebuff_binary_size))"
    elif ((DOWNLOAD)); then
        install_release_download
    else
        [[ -n $src ]] || die "no freebuff binary found to install.
    Pass --from with the directory holding the old copy, for example the
    root/.config/manicode of the proot Debian rootfs, or a backup of it.
    Or pass --download to fetch the official release."
        if ((DRY_RUN)); then
            act "would copy the binary and its data files from $src"
            return 0
        fi
        backup_unusable_binary
        act "copying the freebuff binary from $src"
        install_binary_file "$src/freebuff"
    fi
}

ensure_config() {
    local src=''
    # --download installs a fresh binary and must not silently harvest credentials
    # from an old proot rootfs; --from keeps that behaviour for offline moves.
    if ((!DOWNLOAD)); then src=$(find_existing_install || true); fi

    if ((CHECK)); then
        check_config
        return 0
    fi

    ensure_freebuff_binary "$src"

    # Nothing to import from: whatever is already in $CFG stays as it is.
    if ((!DRY_RUN)) && [[ -n $src ]]; then
        import_existing_files "$src"
    fi
    ensure_ripgrep
}
