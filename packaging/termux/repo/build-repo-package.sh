#!/usr/bin/env bash
#
# Build the tiny freebuff-repo package: it adds the APT source and the signing
# key, so the next `pkg install freebuff-native` comes from this repository.
#
#   packaging/termux/repo/build-repo-package.sh [OUTDIR]
#
# Environment:
#   FREEBUFF_REPO_URL      repository root URL (default: GitHub Pages)
#   FREEBUFF_REPO_VERSION  package version (default: 1.0.0; the apt-repo
#                          workflow passes the released tag)
#   FREEBUFF_PKG_PREFIX    install prefix (default: Termux)
#
# The public key must already be at packaging/termux/repo/freebuff.gpg; CI
# exports it from the same key that signs dists/stable/InRelease.

set -euo pipefail

HERE=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OUT=${1:-$ROOT/dist}
PREFIX=${FREEBUFF_PKG_PREFIX:-/data/data/com.termux/files/usr}
VERSION=${FREEBUFF_REPO_VERSION:-1.0.0}
REPO_URL=${FREEBUFF_REPO_URL:-https://mbanucu.github.io/freebuff-native-termux/}
KEY=$HERE/freebuff.gpg

die() { printf '[x] %s\n' "$*" >&2; exit 1; }
say() { printf '[+] %s\n' "$*"; }

command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb is missing; run: pkg install dpkg"
[[ -s $KEY ]] || die "missing public key: $KEY"
[[ $VERSION =~ ^[0-9][A-Za-z0-9.+:~-]*$ ]] || die "invalid package version: $VERSION"
[[ $REPO_URL == */ ]] || REPO_URL=$REPO_URL/

WORK=$(mktemp -d "${TMPDIR:-/tmp}/freebuff-repo.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

ROOTDIR=$WORK/root
DOC=$ROOTDIR$PREFIX/share/doc/freebuff-repo
mkdir -p "$ROOTDIR$PREFIX/etc/apt/sources.list.d" \
         "$ROOTDIR$PREFIX/etc/apt/trusted.gpg.d" \
         "$DOC" "$ROOTDIR/DEBIAN"
chmod 755 "$ROOTDIR/DEBIAN"

install -m 644 "$KEY" "$ROOTDIR$PREFIX/etc/apt/trusted.gpg.d/freebuff.gpg"
cat >"$ROOTDIR$PREFIX/etc/apt/sources.list.d/freebuff.list" <<EOF
deb [signed-by=$PREFIX/etc/apt/trusted.gpg.d/freebuff.gpg] $REPO_URL stable main
EOF

cat >"$DOC/README.md" <<EOF
# freebuff-repo

This package added:

    $PREFIX/etc/apt/sources.list.d/freebuff.list
    $PREFIX/etc/apt/trusted.gpg.d/freebuff.gpg

Install the CLI with:

    pkg update
    pkg install freebuff-native

Repository: $REPO_URL
EOF

cat >"$ROOTDIR/DEBIAN/control" <<EOF
Package: freebuff-repo
Version: $VERSION
Architecture: all
Maintainer: Michael Banucu <23436598+MBanucu@users.noreply.github.com>
Installed-Size: @INSTALLED_SIZE@
Depends: bash
Section: utils
Priority: optional
Homepage: https://github.com/MBanucu/freebuff-native-termux
Description: APT repository for freebuff-native
 Adds the freebuff-native package source and its signing key to Termux.
 After installing this package, run:
 .
   pkg update
   pkg install freebuff-native
 .
 freebuff-native installs the glibc runtime, fetches the upstream Freebuff
 release, and writes the native launcher.
EOF

# Fill in the size after the payload exists, while keeping the control file
# readable in the source tree.
size=$(du -sk "$ROOTDIR$PREFIX" | cut -f1)
sed -i "s/@INSTALLED_SIZE@/$size/" "$ROOTDIR/DEBIAN/control"

cat >"$ROOTDIR/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -u
echo "freebuff-native APT repository added."
echo "  Run: pkg update && pkg install freebuff-native"
exit 0
EOF
chmod 755 "$ROOTDIR/DEBIAN/postinst"

mkdir -p "$OUT"
DEB=$OUT/freebuff-repo_${VERSION}_all.deb
rm -f "$DEB"

opts=()
if dpkg-deb --help 2>&1 | grep -q -- '--root-owner-group'; then
    opts+=(--root-owner-group)
fi
dpkg-deb "${opts[@]}" --build "$ROOTDIR" "$DEB" >/dev/null

say "built $DEB"
if command -v sha256sum >/dev/null 2>&1; then
    printf '    sha256 %s\n' "$(sha256sum "$DEB" | cut -d' ' -f1)"
fi
printf '    size   %s\n' "$(du -h "$DEB" | cut -f1)"
