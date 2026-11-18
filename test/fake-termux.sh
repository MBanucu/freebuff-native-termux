# shellcheck shell=bash

# A throwaway Termux prefix and a fake release server for installer tests.

SCRIPT=$ROOT/freebuff-native-termux.sh

loader_name() {
    case $1 in
        aarch64|arm64) printf 'ld-linux-aarch64.so.1\n' ;;
        x86_64|amd64)  printf 'ld-linux-x86-64.so.2\n' ;;
    esac
}

# Satisfies the installer's pristine-ELF check: magic plus the interpreter string
# in the first page.
write_fake_binary() { # path
    printf '\177ELF\002\001\001\000\000\000\000\000standalone bun\000/lib/ld-linux-x86-64.so.2\000' >"$1"
    chmod 700 "$1"
}

# The installer picks the release by host CPU; keep the fixture in step with it.
download_target() {
    case $(uname -m) in
        aarch64|arm64) printf 'linux-arm64\n' ;;
        x86_64|amd64)  printf 'linux-x64\n' ;;
    esac
}

# A fake release server: one tarball with the two files the real archive holds,
# and npm-shaped metadata naming its sha256.  install_fake_curl (below) maps the
# installer's URLs onto this directory, so no network is involved.
new_fake_release() {
    local target sum
    target=$(download_target)
    FAKE_HTTP=$WORK/http
    rm -rf "$WORK/release" "$FAKE_HTTP"
    mkdir -p "$WORK/release" "$FAKE_HTTP"
    write_fake_binary "$WORK/release/freebuff"
    printf 'wasm payload for tests\n' >"$WORK/release/tree-sitter.wasm"
    tar -czf "$FAKE_HTTP/freebuff-$target.tar.gz" -C "$WORK/release" freebuff tree-sitter.wasm
    sum=$(helper 'sha256_of_file "$2"' "$FAKE_HTTP/freebuff-$target.tar.gz")
    printf '{"name":"freebuff","version":"9.9.9","binaryChecksums":{"%s":"%s"}}\n' \
        "$target" "$sum" >"$FAKE_HTTP/latest"
}

install_fake_curl() {
    cat >"$PREFIX_DIR/bin/curl" <<'FAKECURL'
#!/bin/sh
# Serve $FAKE_HTTP/<basename of URL>; enough for download_file()'s -fL --retry ... -o.
out= url=
while [ $# -gt 0 ]; do
    case $1 in
        -o) out=$2; shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
[ -n "$out" ] && [ -n "$url" ] || exit 2
src=$FAKE_HTTP/${url##*/}
if [ ! -f "$src" ]; then
    echo "curl: (22) 404 for $url" >&2
    exit 22
fi
cp "$src" "$out"
FAKECURL
    chmod +x "$PREFIX_DIR/bin/curl"
}

FAKE='' PREFIX_DIR='' HOME_DIR=''

new_fake_termux() { # name
    local loader
    FAKE=$WORK/termux-$1
    PREFIX_DIR=$FAKE/data/data/com.termux/files/usr
    HOME_DIR=$FAKE/home
    loader=$(loader_name "$(uname -m)")
    if [[ -z $loader ]]; then
        printf 'SKIP: host arch %s is not one the installer supports\n' "$(uname -m)"
        exit 0
    fi

    mkdir -p "$PREFIX_DIR/bin" "$PREFIX_DIR/glibc/lib" "$PREFIX_DIR/glibc/bin" \
             "$HOME_DIR/.config/manicode" "$FAKE/tmp"

    # The generated wrapper hardcodes $PREFIX/bin/bash as its interpreter, so the
    # fake prefix needs a real bash behind that name.
    ln -s "$(command -v bash)" "$PREFIX_DIR/bin/bash"

    # dpkg only has to exist for the environment guard: the glibc tree below is
    # already complete, so the installer never reaches a package install.
    printf '#!/bin/sh\nexit 0\n' >"$PREFIX_DIR/bin/dpkg"
    chmod +x "$PREFIX_DIR/bin/dpkg"

    # The installer builds the LD_PRELOAD spawn shim with clang --target.  The
    # host compiler cannot do that (on Termux it is bionic-only), so the fake
    # prefix gets a clang that just writes the -o file.
    cat >"$PREFIX_DIR/bin/clang" <<'FAKE'
#!/bin/sh
out= src=
while [ $# -gt 0 ]; do
    case $1 in
        -o) out=$2; shift 2 ;;
        -*) shift ;;
        *) src=$1; shift ;;
    esac
done
[ -n "$out" ] || exit 1
printf 'fake shim from %s\n' "$src" >"$out"
FAKE
    chmod +x "$PREFIX_DIR/bin/clang"

    : >"$PREFIX_DIR/glibc/lib/libc.so.6"
    cat >"$PREFIX_DIR/glibc/lib/$loader" <<'STUB'
#!/bin/sh
# Stand-in for ld-linux: skip --library-path DIR, then require the binary.
while [ $# -gt 0 ]; do
    case $1 in
        --library-path) shift 2 ;;
        *) break ;;
    esac
done
if [ ! -f "$1" ]; then
    echo "ld.so: cannot open shared object file: $1" >&2
    exit 1
fi
shift
echo "freebuff 9.9.9-test${1:+ $1}"
STUB
    chmod +x "$PREFIX_DIR/glibc/lib/$loader"
    ln -sf "../lib/$loader" "$PREFIX_DIR/glibc/bin/ld.so"

    write_fake_binary "$HOME_DIR/.config/manicode/freebuff"
    : >"$HOME_DIR/.config/manicode/rg"
    : >"$HOME_DIR/.config/manicode/tree-sitter.wasm"
}

run_installer() { # args... against the current fake prefix
    env -i HOME="$HOME_DIR" PREFIX="$PREFIX_DIR" PATH="$PREFIX_DIR/bin:$PATH" \
        TMPDIR="$FAKE/tmp" TERM=dumb \
        FREEBUFF_METADATA_URL="${FREEBUFF_METADATA_URL:-https://fake.test/freebuff/latest}" \
        FREEBUFF_RELEASE_BASE="${FREEBUFF_RELEASE_BASE:-https://fake.test/releases}" \
        FAKE_HTTP="${FAKE_HTTP:-}" \
        bash "$SCRIPT" "$@"
}

# Run installer code in a subshell: the file sets `set -euo pipefail`, which must
# not leak into this suite.  $1 is the script, $2.. are passed through to the
# snippet, so the snippet can reach helper arguments as "$2", "$3", ...
helper() {
    local code
    code=$1
    shift
    bash -c "source \"\$1\"; $code" _ "$SCRIPT" "$@"
}
