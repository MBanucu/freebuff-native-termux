#!/usr/bin/env bash
#
# Tests for freebuff-native-termux.sh, runnable on any Linux/macOS bash.
#
# Nothing here needs Termux.  The installer only requires $PREFIX, $HOME, a bash,
# a dpkg on PATH and a glibc loader tree, so every test builds a throwaway "fake
# Termux" prefix and points the installer at it.  Real device paths are never
# touched, and the ~400 MB glibc runtime is replaced by a stub loader that
# asserts the binary it was handed actually exists.  The prefix also gets a fake
# clang that just creates the -o file, so the shim build is exercised without
# needing a cross compiler.
#
# Usage: bash test/installer-test.sh

set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$HERE/freebuff-native-termux.sh
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t freebuff-test)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

begin() { printf '\n# %s\n' "$1"; }
ok()    { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
notok() {
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n' "$1"
    if [[ -n ${2:-} ]]; then printf '       %s\n' "$2"; fi
}

expect_status() { # want actual description
    if [[ $1 == "$2" ]]; then
        ok "$3"
    else
        notok "$3" "wanted exit $1, got $2"
    fi
}

expect_eq() { # want actual description
    if [[ $1 == "$2" ]]; then
        ok "$3"
    else
        notok "$3" "wanted '$1', got '$2'"
    fi
}

expect_contains() { # haystack needle description
    case $1 in
        *"$2"*) ok "$3" ;;
        *) notok "$3" "output does not contain '$2'" ;;
    esac
}

# ------------------------------------------------------------------ fixtures --

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
    sum=$(helper 'sha256_of "$2"' "$FAKE_HTTP/freebuff-$target.tar.gz")
    printf '{"name":"freebuff","version":"9.9.9","binaryChecksums":{"%s":"%s"}}\n' \
        "$target" "$sum" >"$FAKE_HTTP/latest"
}

install_fake_curl() {
    cat >"$PREFIX_DIR/bin/curl" <<'FAKECURL'
#!/bin/sh
# Serve $FAKE_HTTP/<basename of URL>; enough for fetch()'s -fL --retry ... -o.
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

FAKE= PREFIX_DIR= HOME_DIR=

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

# --------------------------------------------------------------------- tests --

begin 'syntax and cli'
bash -n "$SCRIPT"
expect_status 0 $? 'installer parses'

bash -n "$HERE/test/installer-test.sh"
expect_status 0 $? 'test suite parses'

out=$(bash "$SCRIPT" --help 2>&1)
expect_status 0 $? '--help exits 0'
expect_contains "$out" '--from' '--help documents --from'

out=$(bash "$SCRIPT" --bogus 2>&1)
expect_status 1 $? 'unknown option exits 1'
expect_contains "$out" 'unknown option' 'unknown option is reported'

out=$(bash "$SCRIPT" --download --from /tmp 2>&1)
expect_status 1 $? '--download with --from is rejected'
expect_contains "$out" 'cannot be combined' 'the conflict is explained'

begin 'refuses environments it must not touch'
out=$(env -u PREFIX bash "$SCRIPT" 2>&1)
expect_status 1 $? 'fails without PREFIX'
expect_contains "$out" 'Termux' 'explains that it needs Termux'

out=$(PREFIX=/opt/not-termux bash "$SCRIPT" 2>&1)
expect_status 1 $? 'fails on a non-Termux PREFIX'
expect_contains "$out" 'refusing' 'says it refuses that prefix'

begin 'arch detection'
expect_eq 'aarch64 ld-linux-aarch64.so.1' "$(helper 'arch_triplet aarch64')" 'aarch64 -> arm64 loader'
expect_eq 'x86_64 ld-linux-x86-64.so.2' "$(helper 'arch_triplet x86_64')" 'x86_64 -> x86-64 loader'
expect_eq 'aarch64 ld-linux-aarch64.so.1' "$(helper 'arch_triplet arm64')" 'arm64 alias works'
expect_eq '' "$(helper 'arch_triplet armv7l || true')" 'armv7l rejected (no 32-bit build)'
expect_eq '' "$(helper 'arch_triplet i686 || true')" 'i686 rejected (no 32-bit build)'

begin 'dependency resolver'
# glibc's Pre-Depends has no version constraint before the "|", so taking the
# wrong branch (or not splitting alternatives) drops libz from the closure.
cat >"$WORK/Packages" <<'PKG'
Package: glibc-runner
Version: 2.0-3
Depends: glibc (>= 2.44), bash
Filename: pool/main/g/glibc-runner/glibc-runner_2.0-3_aarch64.deb

Package: glibc
Version: 2.44
Pre-Depends: libz | liby
Filename: pool/main/g/glibc/glibc_2.44_aarch64.deb

Package: bash
Version: 5.2.37-1
Depends: libcap-ng (>= 0.8)
Filename: pool/main/b/bash/bash_5.2.37-1_aarch64.deb

Package: libcap-ng
Version: 0.8.5
Filename: pool/main/l/libcap-ng/libcap-ng_0.8.5_aarch64.deb

Package: libz
Version: 1.3
Filename: pool/main/l/libz/libz_1.3_aarch64.deb
PKG
helper 'PKGARCH=aarch64; index_tsv "$2" > "$3"; resolve_closure "$3" glibc-runner > "$4"' \
    "$WORK/Packages" "$WORK/tsv" "$WORK/closure"
expect_status 0 $? 'resolver runs'
expect_eq 5 "$(grep -c '' "$WORK/tsv")" 'parsed every stanza'
expect_eq 5 "$(grep -c '' "$WORK/closure")" 'closure has 5 packages'
expect_eq 0 "$(cut -f1 "$WORK/closure" | sort | uniq -d | grep -c '')" 'no duplicates in the closure'
cut -f1 "$WORK/closure" | grep -qx 'libz'
expect_status 0 $? 'takes the first alternative of "libz | liby"'
cut -f1 "$WORK/closure" | grep -qx 'glibc-runner'
expect_status 0 $? 'includes the requested root package'
cut -f1 "$WORK/closure" | grep -qx 'liby'
expect_status 1 $? 'does not resolve the unused alternative'

begin 'install into a fake Termux'
new_fake_termux a
out=$(run_installer 2>&1)
expect_status 0 $? 'install exits 0'
expect_contains "$out" 'wrapper installed' 'wrapper written'
expect_contains "$out" 'spawn shim built' 'spawn shim built'

[[ -f $PREFIX_DIR/bin/freebuff ]]
expect_status 0 $? 'wrapper exists'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" "exec \"$PREFIX_DIR/glibc/bin/ld.so\"" \
    'wrapper execs the glibc loader'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" 'unset LD_PRELOAD' 'wrapper clears LD_PRELOAD'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" 'managed by freebuff-native-termux.sh' 'wrapper is marked'

[[ -s $HOME_DIR/.config/manicode/freebuff-spawn-shim.so ]]
expect_status 0 $? 'shim object exists'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" \
    'export LD_PRELOAD="$HOME/.config/manicode/freebuff-spawn-shim.so"' \
    'wrapper preloads the shim'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" \
    "export FREEBUFF_NATIVE_LOADER=\"$PREFIX_DIR/glibc/bin/ld.so\"" \
    'wrapper tells the shim which loader to use'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" \
    "export FREEBUFF_NATIVE_LIBDIR=\"$PREFIX_DIR/glibc/lib\"" \
    'wrapper tells the shim the library path'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" \
    'export FREEBUFF_NATIVE_BINARY="$HOME/.config/manicode/freebuff"' \
    'wrapper tells the shim which binary to re-exec'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" \
    'export CODEBUFF_RG_PATH="$HOME/.config/manicode/rg"' \
    'wrapper points code search at the local ripgrep'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" 'head -c 4' \
    'wrapper refuses to preload a non-ELF shim'

out=$(env HOME="$HOME_DIR" "$PREFIX_DIR/bin/freebuff" --version 2>&1)
expect_status 0 $? 'wrapper runs'
expect_contains "$out" '9.9.9-test' 'wrapper reaches the binary'

out=$(env HOME="$WORK/no-such-home" "$PREFIX_DIR/bin/freebuff" --version 2>&1)
expect_status 1 $? 'wrapper fails when HOME has no binary (the path is real, not faked)'

begin 'second run changes nothing'
out=$(run_installer 2>&1)
expect_status 0 $? 'second run exits 0'
expect_contains "$out" 'spawn shim present' 'shim recognised as current'
expect_contains "$out" 'wrapper up to date' 'wrapper recognised as current'
expect_contains "$out" '0 change(s) applied' 'no changes applied'

begin '--check'
run_installer --check >/dev/null 2>&1
expect_status 0 $? '--check passes on a complete install'

rm -f "$PREFIX_DIR/bin/freebuff"
out=$(run_installer --check 2>&1)
expect_status 1 $? '--check fails when the wrapper is missing'
expect_contains "$out" 'missing: wrapper' '--check names what is missing'
[[ ! -f $PREFIX_DIR/bin/freebuff ]]
expect_status 0 $? '--check does not repair'

begin '--dry-run'
out=$(run_installer --dry-run 2>&1)
expect_status 0 $? '--dry-run exits 0'
expect_contains "$out" 'would write' '--dry-run shows the wrapper'
[[ ! -f $PREFIX_DIR/bin/freebuff ]]
expect_status 0 $? '--dry-run writes nothing'

begin 'unmanaged wrapper is preserved'
printf '#!/bin/sh\necho old npm launcher\n' >"$PREFIX_DIR/bin/freebuff"
out=$(run_installer 2>&1)
expect_status 0 $? 'install over an unmanaged wrapper exits 0'
[[ -f $PREFIX_DIR/bin/freebuff.bak ]]
expect_status 0 $? 'old wrapper kept as .bak'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff.bak")" 'old npm launcher' '.bak holds the original'

begin '--check with an unmanaged wrapper'
new_fake_termux d
run_installer >/dev/null 2>&1
printf '#!/bin/sh\necho old npm launcher\n' >"$PREFIX_DIR/bin/freebuff"
out=$(run_installer --check 2>&1)
expect_status 0 $? '--check passes when an unmanaged wrapper is present'
expect_contains "$out" 'unmanaged wrapper' '--check says the wrapper is unmanaged'
[[ ! -f $PREFIX_DIR/bin/freebuff.bak ]]
expect_status 0 $? '--check does not touch the unmanaged wrapper'

begin '--check with a stale managed wrapper'
new_fake_termux e
run_installer >/dev/null 2>&1
printf '# stale edit\n' >>"$PREFIX_DIR/bin/freebuff"
out=$(run_installer --check 2>&1)
expect_status 1 $? '--check fails when the managed wrapper is stale'
expect_contains "$out" 'out of date' '--check reports the stale wrapper'

begin '--check and --dry-run without the shim'
new_fake_termux f
run_installer >/dev/null 2>&1
rm -f "$HOME_DIR/.config/manicode/freebuff-spawn-shim.so"
out=$(run_installer --check 2>&1)
expect_status 1 $? '--check fails when the shim is missing'
expect_contains "$out" 'missing: spawn shim' '--check names the missing shim'
[[ ! -f $HOME_DIR/.config/manicode/freebuff-spawn-shim.so ]]
expect_status 0 $? '--check does not build the shim'

out=$(run_installer --dry-run 2>&1)
expect_status 0 $? '--dry-run exits 0 without the shim'
expect_contains "$out" 'would build the spawn shim' '--dry-run announces the shim'
[[ ! -f $HOME_DIR/.config/manicode/freebuff-spawn-shim.so ]]
expect_status 0 $? '--dry-run does not build the shim'

begin 'a shim that cannot be built is not fatal'
new_fake_termux g
out=$(helper 'SHIM="$2/freebuff-spawn-shim.so"; SHIM_SRC="$3"; SHIM_TARGET=aarch64-linux-gnu; FREEBUFF_SHIM_CC=/nonexistent/cc ensure_shim' \
    "$HOME_DIR/.config/manicode" "$HERE/shim/freebuff-spawn-shim.c" 2>&1)
expect_status 0 $? 'ensure_shim succeeds when the compiler is missing'
expect_contains "$out" 'could not build the spawn shim' 'the failed build is reported'
expect_contains "$out" 'will not work' 'it says what stops working'
[[ ! -e $HOME_DIR/.config/manicode/freebuff-spawn-shim.so ]]
expect_status 0 $? 'no half-built shim is left behind'

out=$(helper 'SHIM="$2/freebuff-spawn-shim.so"; SHIM_SRC="$2/no-such-shim.c" ensure_shim' \
    "$HOME_DIR/.config/manicode" 2>&1)
expect_status 0 $? 'ensure_shim succeeds without the source'
expect_contains "$out" 'no shim source' 'the missing source is reported'

begin 'prebuilt spawn shim'
new_fake_termux l
mkdir -p "$WORK/prebuilt"
printf '\177ELF\002\001\001fake prebuilt shim\n' >"$WORK/prebuilt/freebuff-spawn-shim.so"
out=$(helper 'SHIM="$2/freebuff-spawn-shim.so"; SHIM_PREBUILT="$3"; SHIM_SRC=/nonexistent; ensure_shim' \
    "$HOME_DIR/.config/manicode" "$WORK/prebuilt/freebuff-spawn-shim.so" 2>&1)
expect_status 0 $? 'ensure_shim succeeds with a prebuilt object'
expect_contains "$out" 'installing the prebuilt spawn shim' 'the prebuilt object is preferred'
expect_contains "$(cat "$HOME_DIR/.config/manicode/freebuff-spawn-shim.so")" 'fake prebuilt shim' \
    'the prebuilt object is copied into place'

printf 'not an elf\n' >"$WORK/prebuilt/bad.so"
out=$(helper 'SHIM="$2/out.so"; SHIM_PREBUILT="$3"; SHIM_SRC=/nonexistent; ensure_shim' \
    "$HOME_DIR/.config/manicode" "$WORK/prebuilt/bad.so" 2>&1)
expect_status 0 $? 'ensure_shim survives a non-ELF prebuilt object'
expect_contains "$out" 'not an ELF object' 'the bad prebuilt object is refused'
expect_contains "$out" 'no shim source' 'it falls back to the source path'
[[ ! -e $HOME_DIR/.config/manicode/out.so ]]
expect_status 0 $? 'nothing is installed from a bad prebuilt object'

begin 'repair'
new_fake_termux b
printf 'not an elf at all\n' >"$HOME_DIR/.config/manicode/freebuff"
mkdir -p "$WORK/src"
write_fake_binary "$WORK/src/freebuff"
out=$(run_installer --from "$WORK/src" 2>&1)
expect_status 0 $? 'installer repairs an unusable binary'
[[ -f $HOME_DIR/.config/manicode/freebuff.bak ]]
expect_status 0 $? 'unusable binary moved aside, not deleted'
expect_contains "$out" 'copying the freebuff binary' 'binary re-imported'

begin 'missing binary is a clear error'
new_fake_termux c
rm -f "$HOME_DIR/.config/manicode/freebuff"
out=$(run_installer 2>&1)
expect_status 1 $? 'dies when no binary can be found'
expect_contains "$out" '--from' 'error suggests --from'
expect_contains "$out" '--download' 'error also suggests --download'

begin '--download'
new_fake_termux h
target=$(download_target)
rm -f "$HOME_DIR/.config/manicode/freebuff" \
      "$HOME_DIR/.config/manicode/rg" \
      "$HOME_DIR/.config/manicode/tree-sitter.wasm"
new_fake_release
install_fake_curl
# --download must not silently harvest credentials from an old proot rootfs.
old=$PREFIX_DIR/var/lib/proot-distro/containers/debian/rootfs/root/.config/manicode
mkdir -p "$old"
printf 'old creds\n' >"$old/credentials.json"

out=$(run_installer --download 2>&1)
expect_status 0 $? '--download install exits 0'
expect_contains "$out" 'checksum verified' 'the archive checksum is verified'
expect_contains "$out" 'freebuff 9.9.9 installed' 'the installed version is reported'
[[ $(head -c 4 "$HOME_DIR/.config/manicode/freebuff") == $'\177ELF' ]]
expect_status 0 $? 'the downloaded binary is an ELF'
[[ -f $HOME_DIR/.config/manicode/tree-sitter.wasm ]]
expect_status 0 $? 'tree-sitter.wasm is installed'
expect_contains "$(cat "$HOME_DIR/.config/manicode/tree-sitter.wasm")" 'wasm payload' \
    'the wasm comes from the archive'
[[ ! -f $HOME_DIR/.config/manicode/credentials.json ]]
expect_status 0 $? '--download leaves proot credentials alone'
expect_contains "$out" 'pkg install ripgrep' 'missing ripgrep is a warning, not a failure'

rm -f "$HOME_DIR/.config/manicode/freebuff"
out=$(run_installer --download 2>&1)
expect_status 0 $? 'repairing with --download exits 0'
expect_contains "$out" 'archive already downloaded' 'the cached archive is reused'
expect_contains "$out" 'tree-sitter.wasm up to date' 'matching wasm is left untouched'

out=$(run_installer --download 2>&1)
expect_status 0 $? 'a complete --download install re-runs cleanly'
expect_contains "$out" '0 change(s) applied' 'second run applies no changes'

begin '--download rejects a bad archive'
cp "$FAKE_HTTP/freebuff-$target.tar.gz" "$WORK/good.tgz"
printf 'not a tarball\n' >"$FAKE_HTTP/freebuff-$target.tar.gz"
rm -f "$HOME_DIR/.config/manicode/freebuff" \
      "$FAKE/tmp/freebuff-native/freebuff-$target.tar.gz"
out=$(run_installer --download 2>&1)
expect_status 1 $? 'a checksum mismatch is fatal'
expect_contains "$out" 'checksum mismatch' 'the mismatch is named'
[[ ! -f $HOME_DIR/.config/manicode/freebuff ]]
expect_status 0 $? 'no binary is installed from a bad archive'
[[ ! -e $FAKE/tmp/freebuff-native/freebuff-$target.tar.gz ]]
expect_status 0 $? 'the corrupt cache entry is discarded'
cp "$WORK/good.tgz" "$FAKE_HTTP/freebuff-$target.tar.gz"

begin '--download without the release metadata'
mv "$FAKE_HTTP/latest" "$FAKE_HTTP/latest.off"
rm -f "$HOME_DIR/.config/manicode/freebuff"
out=$(run_installer --download 2>&1)
expect_status 1 $? 'an unreachable metadata file is fatal'
expect_contains "$out" '--from' 'the error points at the offline path'
mv "$FAKE_HTTP/latest.off" "$FAKE_HTTP/latest"

begin '--download --dry-run'
new_fake_termux i
rm -f "$HOME_DIR/.config/manicode/freebuff"
out=$(run_installer --download --dry-run 2>&1)
expect_status 0 $? '--download --dry-run exits 0'
expect_contains "$out" 'would download the latest freebuff release' 'the download is announced'
[[ ! -f $HOME_DIR/.config/manicode/freebuff ]]
expect_status 0 $? '--download --dry-run writes nothing'

begin 'ripgrep from the Termux prefix'
new_fake_termux m
rm -f "$HOME_DIR/.config/manicode/rg"
printf '#!/bin/sh\n' >"$PREFIX_DIR/bin/rg"
chmod +x "$PREFIX_DIR/bin/rg"
out=$(run_installer 2>&1)
expect_status 0 $? 'install succeeds without $CFG/rg'
expect_contains "$out" "using ripgrep from $PREFIX_DIR/bin/rg" 'the prefix ripgrep is accepted'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" \
    "export CODEBUFF_RG_PATH=\"$PREFIX_DIR/bin/rg\"" \
    'the wrapper falls back to the prefix ripgrep'
run_installer --check >/dev/null 2>&1
expect_status 0 $? '--check accepts ripgrep in the prefix'

begin '--check with no ripgrep at all'
new_fake_termux n
run_installer >/dev/null 2>&1
rm -f "$HOME_DIR/.config/manicode/rg"
out=$(run_installer --check 2>&1)
expect_status 1 $? '--check fails without ripgrep'
expect_contains "$out" 'missing: ripgrep' '--check names the missing ripgrep'

# ------------------------------------------------------------------- result --

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
