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
#   FREEBUFF_PKG_VERSION package version (default: 1.1.0)
#   FREEBUFF_PKG_PREFIX  install prefix (default: /data/data/com.termux/files/usr)
#   FREEBUFF_PKG_CC      compiler used for the shim (default: clang)
#
# The control file, maintainer scripts and launcher live in templates/ as
# *.in files with @NAME@ placeholders; this script renders them.
#
# A .deb only contains absolute paths under the build prefix, so a Termux build
# must run inside Termux (or with the same prefix).  The shim can be cross-built
# with clang --target because it is freestanding.

set -euo pipefail

HERE=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
TEMPLATES=$HERE/packaging/termux/templates
OUTDIR=${1:-$HERE/dist}
VERSION=${FREEBUFF_PKG_VERSION:-1.1.0}
PREFIX=${FREEBUFF_PKG_PREFIX:-/data/data/com.termux/files/usr}
CC=${FREEBUFF_PKG_CC:-clang}

die() { printf '[x] %s\n' "$*" >&2; exit 1; }
say() { printf '[+] %s\n' "$*"; }

# render <template> <destination> [NAME=VALUE ...]
# Pure-bash substitution: the placeholders carry absolute paths, which would
# need escaping in sed.
render() {
    local template=$1 dest=$2 content pair
    shift 2
    [[ -f $template ]] || die "missing template $template"
    content=$(<"$template")
    for pair in "$@"; do
        content=${content//@${pair%%=*}@/${pair#*=}}
    done
    if [[ $content =~ @[A-Za-z_]+@ ]]; then
        die "$template has an unrendered placeholder"
    fi
    printf '%s\n' "$content" >"$dest"
}

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

# The installer is a thin entry point that sources lib/ from its own directory,
# so the modules must sit next to it at the same relative path.
mkdir -p "$LIB/lib"
for module in "$HERE"/lib/*.sh; do
    install -m 644 "$module" "$LIB/lib/${module##*/}"
done

say "compiling the prebuilt spawn shim"
"$CC" --target="$TARGET" -fPIC -shared -nostdlib -nostdinc -O2 -Wall -Wextra \
    -o "$LIB/shim/prebuilt/$ARCH/freebuff-spawn-shim.so" \
    "$HERE/shim/freebuff-spawn-shim.c"
chmod 644 "$LIB/shim/prebuilt/$ARCH/freebuff-spawn-shim.so"

render "$TEMPLATES/launcher.in" "$BIN/freebuff-native" PREFIX="$PREFIX"
chmod 755 "$BIN/freebuff-native"

if [[ -f $HERE/README.md ]]; then
    install -m 644 "$HERE/README.md" "$DOC/README.md"
fi

# --- control -----------------------------------------------------------------

installed_size=$(du -sk "$ROOT$PREFIX" | cut -f1)

render "$TEMPLATES/control.in" "$ROOT/DEBIAN/control" \
    PACKAGE_VERSION="$VERSION" ARCH="$ARCH" INSTALLED_SIZE="$installed_size"

# The glibc runtime lives outside the package and may already be present.  Only
# then can the postinst finish the install: apt/dpkg cannot run under the dpkg
# lock that is held while maintainer scripts execute.
render "$TEMPLATES/postinst.in" "$ROOT/DEBIAN/postinst" PREFIX="$PREFIX"
render "$TEMPLATES/postrm.in" "$ROOT/DEBIAN/postrm" PREFIX="$PREFIX"

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
