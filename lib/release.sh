# shellcheck shell=bash

# The official freebuff release: metadata, archive, checksum and installation.
#
# --download resolves the current version through the npm metadata (which also
# publishes the archive's sha256), fetches the matching GitHub release, and
# installs freebuff plus tree-sitter.wasm.  The archive has no ripgrep.

FREEBUFF_METADATA_URL=${FREEBUFF_METADATA_URL:-https://registry.npmjs.org/freebuff/latest}
FREEBUFF_RELEASE_BASE=${FREEBUFF_RELEASE_BASE:-https://github.com/CodebuffAI/codebuff-community/releases/download}

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
read_json_string() { # key file
    local m
    m=$(grep -o "\"$1\":\"[^\"]*\"" "$2" 2>/dev/null | head -n 1) || return 1
    [[ -n $m ]] || return 1
    m=${m#*:\"}
    printf '%s\n' "${m%\"}"
}

# Fill the RELEASE_* globals for this CPU.  The metadata is small, so it is
# fetched on every download attempt; the archive itself is what gets cached.
resolve_release() { # pkgarch
    local target meta
    target=$(release_target "$1") || die "no release archive for $1"
    meta=$CACHE/freebuff-latest.json

    act "resolving the current freebuff release"
    download_file "$FREEBUFF_METADATA_URL" "$meta" || die "cannot read $FREEBUFF_METADATA_URL
    (no network? --from DIR installs from a local copy instead)"
    RELEASE_TARGET=$target
    RELEASE_VERSION=$(read_json_string version "$meta") || die "no version in $FREEBUFF_METADATA_URL"
    RELEASE_SUM=$(read_json_string "$target" "$meta") ||
        die "the release metadata has no checksum for $target"
    RELEASE_URL=$FREEBUFF_RELEASE_BASE/freebuff-v$RELEASE_VERSION/freebuff-$target.tar.gz
}

release_archive_matches() { # file sha256
    local got
    [[ -s $1 ]] || return 1
    got=$(sha256_of_file "$1" || true)
    [[ -n $got && $got == "$2" ]]
}

download_release_archive() { # url sha256 destination
    local url=$1 sum=$2 dest=$3 got
    if release_archive_matches "$dest" "$sum"; then
        ok "freebuff $RELEASE_VERSION archive already downloaded"
        return 0
    fi
    if [[ -e $dest ]]; then
        warn "discarding a cached archive that does not match the checksum"
        rm -f "$dest"
    fi
    act "downloading freebuff $RELEASE_VERSION ($RELEASE_TARGET)"
    download_file "$url" "$dest" || die "download failed: $url"
    CHANGED=$((CHANGED + 1))

    got=$(sha256_of_file "$dest" || true)
    if [[ $got != "$sum" ]]; then
        rm -f "$dest"
        die "checksum mismatch for $url
    expected $sum
    got      ${got:-<no sha256 tool; pkg install coreutils>}"
    fi
    ok "checksum verified (sha256 $sum)"
}

extract_release_archive() { # archive directory
    rm -rf "$2"
    mkdir -p "$2"
    tar -xzf "$1" -C "$2" || die "cannot extract $1"
    freebuff_binary_is_valid "$2/freebuff" ||
        die "$RELEASE_URL did not contain a usable freebuff binary"
}

install_release_files() { # directory version
    local dir=$1 version=$2
    mkdir -p "$CFG"
    backup_unusable_binary
    install_binary_file "$dir/freebuff"
    sync_parser_data "$dir"
    ok "freebuff $version installed ($BIN)"
}

# Fetch the current release, check it against the published sha256, and install
# the binary plus tree-sitter.wasm.  The archive stays in $CACHE, so a repair
# run re-downloads only when the version changes or the cached file is damaged.
install_release_download() {
    local target tgz dir
    target=$(release_target "$PKGARCH") || die "no release archive for $PKGARCH"
    if ((DRY_RUN)); then
        act "would download the latest freebuff release for $target"
        return 0
    fi
    command -v tar >/dev/null 2>&1 || die "tar is missing; run: pkg install tar"

    mkdir -p "$CACHE"
    resolve_release "$PKGARCH"
    tgz=$CACHE/freebuff-$RELEASE_TARGET.tar.gz
    download_release_archive "$RELEASE_URL" "$RELEASE_SUM" "$tgz"

    dir=$CACHE/extract-$RELEASE_TARGET
    extract_release_archive "$tgz" "$dir"
    install_release_files "$dir" "$RELEASE_VERSION"
    rm -rf "$dir"
}
