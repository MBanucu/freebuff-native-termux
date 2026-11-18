#!/usr/bin/env bash
#
# Build the Termux .deb for freebuff-native.
#
#   packaging/termux/build-deb.sh [OUTDIR]
#
# The package is deliberately small: it carries the installer, the shim source,
# and a prebuilt shim object for one architecture.  The 136 MB freebuff binary
# is fetched by the postinst (or later by `freebuff-native`) with --download, so
# the same package works for every release and offline installs still have a
# local path through --from.
#
# Environment:
#   FREEBUFF_PKG_ARCH    aarch64 or x86_64 (default: dpkg --print-architecture)
#   FREEBUFF_PKG_VERSION package version (default: 1.0.0)
#   FREEBUFF_PKG_PREFIX  install prefix (default: /data/data/com.termux/files/usr)
#   FREEBUFF_PKG_CC      compiler used for the shim (default: clang)
#
# A .deb only contains absolute paths under the build prefix, so a Termux build
# must run inside Termux (or with the same prefix).  The shim can be cross-built
# with clang --target because it is freestanding.

set -euo pipefail

HERE=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
OUTDIR=${1:-$HERE/dist}
VERSION=${FREEBUFF_PKG_VERSION:-1.0.0}
PREFIX=${FREEBUFF_PKG_PREFIX:-/data/data/com.termux/files/usr}
CC=${FREEBUFF_PKG_CC:-clang}

die() { printf '[x] %s\n' "$*" >&2; exit 1; }
say() { printf '[+] %s\n' "$*"; }

ARCH=${FREEBUFF_PKG_ARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}
case $ARCH in
    aarch64|arm64) ARCH=aarch64; TARGET=aarch64-linux-gnu ;;
    x86_64|amd64)  ARCH=x86_64;  TARGET=x86_64-linux-gnu ;;
    *) die "unsupported architecture: $ARCH (Termux packages are aarch64 or x86_64)" ;;
esac

command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb is missing; run: pkg install dpkg"
command -v "$CC" >/dev/null 2>&1 || die "no C compiler '$CC'; run: pkg install clang"
[[ -f $HERE/freebuff-native-termux.sh ]] || die "missing $HERE/freebuff-native-termux.sh"
[[ -f $HERE/shim/freebuff-spawn-shim.c ]] || die "missing shim source"
[[ $VERSION =~ ^[0-9][A-Za-z0-9.+:~-]*$ ]] || die "invalid package version: $VERSION"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/freebuff-deb.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

ROOT=$WORK/root
LIB=$ROOT$PREFIX/lib/freebuff-native
BIN=$ROOT$PREFIX/bin
DOC=$ROOT$PREFIX/share/doc/freebuff-native

say "building freebuff-native $VERSION for $ARCH ($TARGET)"
mkdir -p "$LIB/shim/prebuilt/$ARCH" "$BIN" "$DOC" "$ROOT/DEBIAN"
# Umask 077 is common in Termux; dpkg-deb requires the control directory itself
# to be group/other readable.
chmod 755 "$ROOT/DEBIAN"

# --- payload -----------------------------------------------------------------

install -m 755 "$HERE/freebuff-native-termux.sh" "$LIB/freebuff-native.sh"
install -m 644 "$HERE/shim/freebuff-spawn-shim.c" "$LIB/shim/freebuff-spawn-shim.c"

say "compiling the prebuilt spawn shim"
"$CC" --target="$TARGET" -fPIC -shared -nostdlib -nostdinc -O2 -Wall -Wextra \
    -o "$LIB/shim/prebuilt/$ARCH/freebuff-spawn-shim.so" \
    "$HERE/shim/freebuff-spawn-shim.c"
chmod 644 "$LIB/shim/prebuilt/$ARCH/freebuff-spawn-shim.so"

# A launcher, not a symlink: the installer resolves its data directory from
# BASH_SOURCE, so it must be started under its real path.
cat >"$BIN/freebuff-native" <<EOF
#!$PREFIX/bin/bash
# managed by the freebuff-native package
exec "$PREFIX/lib/freebuff-native/freebuff-native.sh" "\$@"
EOF
chmod 755 "$BIN/freebuff-native"

if [[ -f $HERE/README.md ]]; then
    install -m 644 "$HERE/README.md" "$DOC/README.md"
fi

# --- control -----------------------------------------------------------------

# Installed-Size is in KiB and, by convention, counts the data tree only.
SIZE=$(du -sk "$ROOT$PREFIX" | cut -f1)

cat >"$ROOT/DEBIAN/control" <<EOF
Package: freebuff-native
Version: $VERSION
Architecture: $ARCH
Maintainer: Michael Banucu <23436598+MBanucu@users.noreply.github.com>
Installed-Size: $SIZE
Depends: bash, tar, curl | wget
Recommends: ripgrep
Section: utils
Priority: optional
Homepage: https://github.com/MBanucu/freebuff-native-termux
Description: Native Freebuff CLI for Termux without proot
 Runs the upstream Freebuff CLI on the Android kernel through Termux's
 glibc loader.  A small LD_PRELOAD shim repairs the terminal-command broker
 re-exec (CodebuffAI/freebuff#1688), so the agent's shell, git and code
 search work natively.
 .
 The package installs the wrapper, the prebuilt shim and the installer.
 The freebuff binary itself is downloaded on first use (freebuff-native
 --download) or imported from an existing copy (freebuff-native --from DIR).
EOF

# The glibc runtime lives outside the package and may already be present.  Only
# then can the postinst finish the install: apt/dpkg cannot run under the dpkg
# lock that is held while maintainer scripts execute.
cat >"$ROOT/DEBIAN/postinst" <<EOF
#!/bin/sh
set -u
PREFIX=$PREFIX
GLIBC=\$PREFIX/glibc

if [ -e "\$GLIBC/lib/libc.so.6" ] && [ -e "\$GLIBC/bin/ld.so" ]; then
    # Download the current release and install the wrapper/shim.  A network
    # failure must not fail the package installation.
    "\$PREFIX/bin/freebuff-native" --download ||
        echo "freebuff-native: setup did not finish; re-run 'freebuff-native --download' when online"
else
    echo "freebuff-native: the glibc runtime is not installed yet."
    echo "  Run 'freebuff-native --download' to install it, fetch freebuff, and finish setup."
fi
exit 0
EOF

cat >"$ROOT/DEBIAN/postrm" <<EOF
#!/bin/sh
set -u
PREFIX=$PREFIX
CFG=\${HOME:-}/.config/manicode

case "\${1:-}" in
    remove|purge|disappear)
        if [ -f "\$PREFIX/bin/freebuff" ] &&
           grep -q 'managed by freebuff-native-termux.sh' "\$PREFIX/bin/freebuff" 2>/dev/null; then
            rm -f "\$PREFIX/bin/freebuff"
        fi
        if [ -n "\${HOME:-}" ]; then
            rm -f "\$CFG/freebuff-spawn-shim.so"
        fi
        if [ "\${1:-}" = purge ] && [ -n "\${HOME:-}" ]; then
            # Keep credentials, settings and projects: they are the user's data.
            rm -f "\$CFG/freebuff" "\$CFG/tree-sitter.wasm"
        fi
        ;;
esac
if [ "\${1:-}" = purge ]; then
    echo "freebuff binary removed; credentials and projects kept in \$CFG"
else
    echo "freebuff data kept in \$CFG (credentials and settings); 'dpkg -P freebuff-native' also removes the binary"
fi
exit 0
EOF

chmod 755 "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/postrm"

# --- build -------------------------------------------------------------------

mkdir -p "$OUTDIR"
DEB=$OUTDIR/freebuff-native_${VERSION}_${ARCH}.deb
rm -f "$DEB"

opts=()
# Reproducible ownership; supported by the dpkg Termux ships and by CI.
if dpkg-deb --help 2>&1 | grep -q -- '--root-owner-group'; then
    opts+=(--root-owner-group)
fi
dpkg-deb "${opts[@]}" --build "$ROOT" "$DEB" >/dev/null

say "built $DEB"
if command -v sha256sum >/dev/null 2>&1; then
    printf '    sha256 %s\n' "$(sha256sum "$DEB" | cut -d' ' -f1)"
fi
printf '    size   %s\n' "$(du -h "$DEB" | cut -f1)"
