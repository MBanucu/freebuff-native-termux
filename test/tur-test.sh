#!/usr/bin/env bash
#
# Tests for the TUR recipe draft in tur/freebuff-native/build.sh.
#
# Runs the recipe's install step against a fake Termux prefix, which is what
# `termux_step_make_install` does in the TUR build.  No network, no device.
#
# Usage: bash test/tur-test.sh

set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
RECIPE=$HERE/tur/freebuff-native/build.sh
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t freebuff-tur-test)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# shellcheck source=/dev/null
source "$HERE/test/assertions.sh"

if ! command -v clang >/dev/null 2>&1; then
    printf 'SKIP: clang is not installed\n'
    exit 0
fi

[[ -f $RECIPE ]]
expect_status 0 $? 'the recipe exists'
bash -n "$RECIPE"
expect_status 0 $? 'the recipe parses'

recipe=$(cat "$RECIPE")
for field in TERMUX_PKG_HOMEPAGE TERMUX_PKG_DESCRIPTION TERMUX_PKG_LICENSE \
    TERMUX_PKG_MAINTAINER TERMUX_PKG_VERSION TERMUX_PKG_SRCURL \
    TERMUX_PKG_SHA256 TERMUX_PKG_DEPENDS; do
    expect_contains "$recipe" "$field=" "the recipe sets $field"
done
expect_contains "$recipe" 'TERMUX_PKG_LICENSE="MIT"' 'the license is MIT'
expect_contains "$recipe" 'archive/refs/tags/v${TERMUX_PKG_VERSION}.tar.gz' \
    'the source is the tagged archive'
expect_contains "$recipe" 'TERMUX_PKG_EXCLUDED_ARCHES="arm, i686"' \
    'unsupported architectures are excluded'

PREFIX=$WORK/prefix
mkdir -p "$PREFIX"
export TERMUX_PREFIX=$PREFIX
export TERMUX_PKG_NAME=freebuff-native
export TERMUX_PKG_SRCDIR=$HERE
export TERMUX_ARCH=aarch64
export CC=clang
export CFLAGS='-O2'

# The recipe is a build-system fragment, not a program: source it and call the
# step the TUR build calls.  The debscripts step writes ./postinst into cwd.
# shellcheck source=/dev/null
source "$RECIPE"

cd "$WORK" || exit 1
termux_step_make_install >"$WORK/install.log" 2>&1
rc=$?
expect_status 0 "$rc" 'the install step succeeds'
if ((rc != 0)); then
    tail -5 "$WORK/install.log"
fi

LIB=$PREFIX/lib/freebuff-native
[[ -f $LIB/freebuff-native.sh ]]
expect_status 0 $? 'the installer entry point is installed'
[[ -x $PREFIX/bin/freebuff-native ]]
expect_status 0 $? 'the launcher is executable'
[[ -f $PREFIX/share/doc/freebuff-native/README.md ]]
expect_status 0 $? 'the README is installed'

head -1 "$PREFIX/bin/freebuff-native" >"$WORK/shebang"
expect_eq "#!$PREFIX/bin/bash" "$(cat "$WORK/shebang")" 'the launcher has an absolute shebang'
expect_contains "$(cat "$PREFIX/bin/freebuff-native")" "exec \"$LIB/freebuff-native.sh\"" \
    'the launcher runs the installed entry point'
expect_missing "$(cat "$PREFIX/bin/freebuff-native")" '@PREFIX@' \
    'no placeholder is left in the launcher'

expected=$(ls "$HERE"/lib/*.sh | wc -l | tr -d ' ')
got=$(ls "$LIB"/lib/*.sh 2>/dev/null | wc -l | tr -d ' ')
expect_eq "$expected" "$got" 'every installer module is installed'

SHIM=$LIB/shim/prebuilt/aarch64/freebuff-spawn-shim.so
[[ -s $SHIM ]]
expect_status 0 $? 'the shim is built for the package architecture'
expect_eq $'\x7fELF' "$(head -c 4 "$SHIM")" 'the shim is an ELF object'
[[ -f $LIB/shim/freebuff-spawn-shim.c ]]
expect_status 0 $? 'the shim source ships alongside it'

termux_step_create_debscripts
expect_status 0 $? 'the debscripts step succeeds'
[[ -f $WORK/postinst ]]
expect_status 0 $? 'a postinst is generated'
sh -n "$WORK/postinst"
expect_status 0 $? 'postinst parses'
expect_contains "$(cat "$WORK/postinst")" 'freebuff-native" --download' \
    'postinst finishes the install'
expect_contains "$(cat "$WORK/postinst")" '#!'"$PREFIX"'/bin/sh' \
    'postinst has an absolute shebang'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
