#!/usr/bin/env bash
#
# Tests for packaging/termux/repo: the Packages/Release indexes, the signed
# Release, and the freebuff-repo setup package.  No network and no Termux device.
#
# Usage: bash test/repo-test.sh

set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
BUILD_REPO=$HERE/packaging/termux/repo/build-repo.sh
BUILD_PKG=$HERE/packaging/termux/repo/build-repo-package.sh
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t freebuff-repo-test)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# shellcheck source=/dev/null
source "$HERE/test/assertions.sh"

if ! command -v dpkg-deb >/dev/null 2>&1; then
    printf 'SKIP: dpkg-deb is not installed\n'
    exit 0
fi

PREFIX=/data/data/com.termux/files/usr

make_deb() { # name version arch outdir
    local name=$1 version=$2 arch=$3 outdir=$4
    local root=$WORK/build-$name-$arch
    mkdir -p "$root/DEBIAN" "$root/usr/bin"
    chmod 755 "$root/DEBIAN"
    cat >"$root/DEBIAN/control" <<EOF
Package: $name
Version: $version
Architecture: $arch
Maintainer: test <test@example.invalid>
Description: test package $name
EOF
    printf 'payload for %s\n' "$name" >"$root/usr/bin/$name"
    chmod 755 "$root/usr/bin/$name"

    local opts=()
    if dpkg-deb --help 2>&1 | grep -q -- '--root-owner-group'; then
        opts+=(--root-owner-group)
    fi
    dpkg-deb "${opts[@]}" --build "$root" "$outdir/${name}_${version}_${arch}.deb" >/dev/null
}

DEBS=$WORK/debs
mkdir -p "$DEBS"
make_deb demo-aarch64 1.0 aarch64 "$DEBS"
make_deb demo-x86 1.0 x86_64 "$DEBS"
make_deb demo-all 1.0 all "$DEBS"

PUBLIC=$WORK/public
out=$(bash "$BUILD_REPO" "$DEBS" "$PUBLIC" 2>&1)
expect_status 0 $? 'the repository builds'
expect_contains "$out" 'indexed binary-aarch64' 'aarch64 is indexed'
expect_contains "$out" 'indexed binary-x86_64' 'x86_64 is indexed'
[[ -f $PUBLIC/dists/stable/main/binary-aarch64/Packages ]]
expect_status 0 $? 'the aarch64 Packages index exists'
[[ -f $PUBLIC/dists/stable/main/binary-x86_64/Packages.gz ]]
expect_status 0 $? 'the x86_64 gzip index exists'

aarch64_packages=$(cat "$PUBLIC/dists/stable/main/binary-aarch64/Packages")
x86_packages=$(cat "$PUBLIC/dists/stable/main/binary-x86_64/Packages")
expect_contains "$aarch64_packages" 'Package: demo-aarch64' 'aarch64 package is in its index'
expect_contains "$aarch64_packages" 'Package: demo-all' 'arch:all package is in the aarch64 index'
expect_missing "$aarch64_packages" 'Package: demo-x86' 'the x86_64 package is not in the aarch64 index'
expect_contains "$x86_packages" 'Package: demo-x86' 'x86_64 package is in its index'
expect_contains "$x86_packages" 'Package: demo-all' 'arch:all package is in the x86_64 index'

# Every Filename/SHA256 pair in an index must describe the file it names.
check_index() { # Packages
    local index=$1 rel sum path
    [[ -f $index ]] || return 1
    while read -r rel; do
        path=$PUBLIC/$rel
        [[ -f $path ]] || { printf 'missing %s\n' "$path"; return 1; }
        sum=$(grep -A2 -F "Filename: $rel" "$index" | sed -n 's/^SHA256: //p')
        [[ -n $sum && $sum == "$(sha256sum "$path" | cut -d' ' -f1)" ]] || return 1
    done < <(sed -n 's/^Filename: //p' "$index")
}

check_index "$PUBLIC/dists/stable/main/binary-aarch64/Packages"
expect_status 0 $? 'aarch64 filenames and checksums agree'
check_index "$PUBLIC/dists/stable/main/binary-x86_64/Packages"
expect_status 0 $? 'x86_64 filenames and checksums agree'

gzip -dc "$PUBLIC/dists/stable/main/binary-aarch64/Packages.gz" >"$WORK/unpacked"
expect_eq "$(cat "$PUBLIC/dists/stable/main/binary-aarch64/Packages")" "$(cat "$WORK/unpacked")" \
    'Packages.gz matches Packages'

release=$(cat "$PUBLIC/dists/stable/Release")
expect_contains "$release" 'Architectures: aarch64 x86_64' 'Release lists both architectures'
expect_contains "$release" 'SHA256:' 'Release carries checksums'
sum=$(sha256sum "$PUBLIC/dists/stable/main/binary-aarch64/Packages.gz" | cut -d' ' -f1)
expect_contains "$release" "$sum" 'Release checksum matches the gzip index'

# Signing is optional tooling; verify it when gpg is available.
if command -v gpg >/dev/null 2>&1 && command -v gpgv >/dev/null 2>&1; then
    export GNUPGHOME=$WORK/gnupg
    mkdir -m 700 -p "$GNUPGHOME"
    gpg --batch --pinentry-mode loopback --passphrase '' \
        --quick-generate-key 'repo test <test@example.invalid>' ed25519 sign 1d >/dev/null 2>&1
    key=$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^sec:/ {print $5; exit}')
    signed=$WORK/signed
    out=$(bash "$BUILD_REPO" "$DEBS" "$signed" "$key" 2>&1)
    expect_status 0 $? 'the repository signs'
    expect_contains "$out" 'signed the Release file' 'signing is reported'
    gpg --export "$key" >"$WORK/keyring.gpg"
    gpgv --keyring "$WORK/keyring.gpg" "$signed/dists/stable/InRelease" >/dev/null 2>&1
    expect_status 0 $? 'InRelease verifies against the signing key'
    [[ -s $signed/dists/stable/Release.gpg ]]
    expect_status 0 $? 'a detached Release.gpg is written'
    unset GNUPGHOME
fi

DIST=$WORK/dist
mkdir -p "$DIST"
out=$(FREEBUFF_REPO_URL=https://example.test/freebuff/ \
    FREEBUFF_PKG_PREFIX="$PREFIX" bash "$BUILD_PKG" "$DIST" 2>&1)
expect_status 0 $? 'the freebuff-repo package builds'
DEB=$DIST/freebuff-repo_1.0.0_all.deb
[[ -f $DEB ]]
expect_status 0 $? 'the freebuff-repo .deb exists'

control=$(dpkg-deb -f "$DEB" 2>/dev/null)
expect_contains "$control" 'Package: freebuff-repo' 'package name'
expect_contains "$control" 'Architecture: all' 'architecture is all'
expect_contains "$control" 'Depends: bash' 'depends on bash'

listing=$(dpkg-deb -c "$DEB" 2>/dev/null)
expect_contains "$listing" "./${PREFIX#/}/etc/apt/sources.list.d/freebuff.list" 'the source list is packed'
expect_contains "$listing" "./${PREFIX#/}/etc/apt/trusted.gpg.d/freebuff.gpg" 'the key is packed'

extract=$WORK/extract
mkdir -p "$extract"
dpkg-deb -x "$DEB" "$extract"
sources=$(cat "$extract$PREFIX/etc/apt/sources.list.d/freebuff.list")
expect_contains "$sources" 'https://example.test/freebuff/' 'the source points at the repository'
expect_contains "$sources" "signed-by=$PREFIX/etc/apt/trusted.gpg.d/freebuff.gpg" 'the source is scoped to the key'
[[ -s $extract$PREFIX/etc/apt/trusted.gpg.d/freebuff.gpg ]]
expect_status 0 $? 'the packed key is not empty'

dpkg-deb -e "$DEB" "$WORK/control" >/dev/null 2>&1
sh -n "$WORK/control/postinst"
expect_status 0 $? 'postinst parses'
expect_contains "$(cat "$WORK/control/postinst")" 'pkg install freebuff-native' \
    'postinst prints the next step'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
