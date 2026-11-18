#!/usr/bin/env bash
#
# Tests for packaging/termux/build-deb.sh.  Needs dpkg-deb and clang, but not a
# Termux device and not root: the package is built with a throwaway prefix under
# mktemp, then inspected with dpkg-deb itself.
#
# Usage: bash test/package-test.sh

set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
BUILD=$HERE/packaging/termux/build-deb.sh
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t freebuff-pkg-test)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# shellcheck source=/dev/null
source "$HERE/test/assertions.sh"

arch_name() {
    case $(uname -m) in
        aarch64|arm64) printf 'aarch64\n' ;;
        x86_64|amd64)  printf 'x86_64\n' ;;
    esac
}

ARCH=$(arch_name)
if [[ -z $ARCH ]]; then
    printf 'SKIP: host arch %s has no Termux package target\n' "$(uname -m)"
    exit 0
fi

if ! command -v dpkg-deb >/dev/null 2>&1; then
    printf 'SKIP: dpkg-deb is not installed\n'
    exit 0
fi
if ! command -v clang >/dev/null 2>&1; then
    printf 'SKIP: clang is not installed\n'
    exit 0
fi

PREFIX=$WORK/prefix
DIST=$WORK/dist
export FREEBUFF_PKG_ARCH=$ARCH
export FREEBUFF_PKG_PREFIX=$PREFIX
export FREEBUFF_PKG_VERSION=9.8.7

begin 'build'
out=$(bash "$BUILD" "$DIST" 2>&1)
expect_status 0 $? 'the package builds'
expect_contains "$out" 'compiling the prebuilt spawn shim' 'the shim is cross-compiled'
expect_contains "$out" 'built ' 'the output path is reported'

DEB=$DIST/freebuff-native_9.8.7_${ARCH}.deb
[[ -f $DEB ]]
expect_status 0 $? 'the .deb exists'

begin 'control metadata'
control=$(dpkg-deb -f "$DEB" 2>/dev/null)
expect_contains "$control" 'Package: freebuff-native' 'package name'
expect_contains "$control" "Architecture: $ARCH" 'architecture matches'
expect_contains "$control" 'Version: 9.8.7' 'version'
expect_contains "$control" 'Depends: bash, tar, curl | wget' 'runtime dependencies'
expect_contains "$control" 'Recommends: ripgrep' 'ripgrep is recommended'
depends=$(dpkg-deb -f "$DEB" Depends)
expect_contains "$depends" 'bash' 'depends on bash'

begin 'payload layout'
listing=$(dpkg-deb -c "$DEB" 2>/dev/null)
expect_contains "$listing" "./${PREFIX#/}/bin/freebuff-native" 'launcher is packed'
expect_contains "$listing" "./${PREFIX#/}/lib/freebuff-native/freebuff-native.sh" 'installer is packed'
expect_contains "$listing" "./${PREFIX#/}/lib/freebuff-native/shim/freebuff-spawn-shim.c" 'shim source is packed'
expect_contains "$listing" "./${PREFIX#/}/lib/freebuff-native/shim/prebuilt/$ARCH/freebuff-spawn-shim.so" \
    'the prebuilt shim is packed for the target architecture'
expect_contains "$listing" "./${PREFIX#/}/share/doc/freebuff-native/README.md" 'README is packed'

# The installer is a thin entry point that sources lib/ next to itself, so the
# modules have to travel with it.  A package without them installs nothing.
for module in "$HERE"/lib/*.sh; do
    name=${module##*/}
    expect_contains "$listing" "./${PREFIX#/}/lib/freebuff-native/lib/$name" "$name is packed"
done

extract=$WORK/extract
mkdir -p "$extract"
dpkg-deb -x "$DEB" "$extract"
expect_status 0 $? 'the package extracts'

LIB=$extract$PREFIX/lib/freebuff-native
SHIM=$LIB/shim/prebuilt/$ARCH/freebuff-spawn-shim.so
[[ $(head -c 4 "$SHIM") == $'\177ELF' ]]
expect_status 0 $? 'the prebuilt shim is an ELF object'
[[ -s $LIB/freebuff-native.sh ]]
expect_status 0 $? 'the installer copy is not empty'

# The installer resolves the prebuilt object with exactly this expression; a
# mismatch here would make a .deb install fall back to compiling (or to no shim).
bash -n "$LIB/freebuff-native.sh"
expect_status 0 $? 'the packed installer parses'
grep -qF 'SHIM_PREBUILT=$SCRIPT_DIR/shim/prebuilt/$PKGARCH/freebuff-spawn-shim.so' \
    "$LIB/freebuff-native.sh"
expect_status 0 $? 'the installer looks for the prebuilt shim at the packed path'
[[ -f "$LIB/shim/prebuilt/$ARCH/freebuff-spawn-shim.so" ]]
expect_status 0 $? 'the packed path actually contains the shim'

# Every module the entry point sources must exist under the packed lib/.
for name in $(sed -n 's/^for module in \(.*\); do$/\1/p' "$LIB/freebuff-native.sh"); do
    [[ -f "$LIB/lib/$name.sh" ]]
    expect_status 0 $? "the packed lib/ holds $name.sh"
done

# --help stops before any device check, so this only proves that the packed
# entry point finds and sources its modules from the relative path.
out=$(bash "$LIB/freebuff-native.sh" --help 2>&1)
expect_status 0 $? 'the packed installer loads its modules'
expect_contains "$out" '--from' 'the packed installer prints usage'

begin 'maintainer scripts'
for script in postinst postrm; do
    dpkg-deb -e "$DEB" "$WORK/control-$script" >/dev/null 2>&1
    sh -n "$WORK/control-$script/$script"
    expect_status 0 $? "$script parses"
done

expect_contains "$(cat "$WORK/control-postinst/postinst")" "PREFIX=$PREFIX" \
    'postinst knows the build prefix'
expect_contains "$(cat "$WORK/control-postinst/postinst")" '$PREFIX/bin/freebuff-native' \
    'postinst calls the installed launcher'
expect_contains "$(cat "$WORK/control-postinst/postinst")" '--download' \
    'postinst fetches the release when glibc is present'
expect_contains "$(cat "$WORK/control-postinst/postinst")" 'glibc runtime is not installed yet' \
    'postinst explains the first-run step'
expect_contains "$(cat "$WORK/control-postrm/postrm")" 'freebuff-spawn-shim.so' \
    'postrm removes the generated shim'
expect_contains "$(cat "$WORK/control-postrm/postrm")" 'dpkg -P' \
    'postrm documents how to purge the binary'

begin 'bad input'
out=$(FREEBUFF_PKG_ARCH=armv7l bash "$BUILD" "$DIST" 2>&1)
expect_status 1 $? 'an unsupported architecture is rejected'
expect_contains "$out" 'unsupported architecture' 'the rejection is explained'

out=$(FREEBUFF_PKG_VERSION=nope bash "$BUILD" "$DIST" 2>&1)
expect_status 1 $? 'an invalid version is rejected'
expect_contains "$out" 'invalid package version' 'the rejection is explained'

# ------------------------------------------------------------------- result --

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
