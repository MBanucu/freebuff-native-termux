#!/usr/bin/env bash
#
# Build an APT repository tree from the .deb files in a directory.
#
#   packaging/termux/repo/build-repo.sh [DEBDIR] [OUTDIR] [GPG_KEY]
#
# The result is what GitHub Pages serves:
#
#   dists/stable/InRelease, Release, Release.gpg
#   dists/stable/main/binary-<arch>/Packages{,.gz}
#   pool/main/<letter>/<package>/<file>.deb
#
# GPG_KEY is a key id or fingerprint.  Without one the tree is still built but
# unsigned, and apt will refuse it unless the source line says trusted=yes.
# CI passes the key from the APT_GPG_PRIVATE_KEY secret.

set -euo pipefail

HERE=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
DEBDIR=${1:-dist}
OUT=${2:-public}
KEY=${3:-${FREEBUFF_REPO_KEY:-}}
SUITE=stable
COMPONENT=main

die() { printf '[x] %s\n' "$*" >&2; exit 1; }
say() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }

for tool in dpkg-deb gzip md5sum sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is missing"
done

[[ -d $DEBDIR ]] || die "no such directory: $DEBDIR"
shopt -s nullglob
debs=("$DEBDIR"/*.deb)
((${#debs[@]})) || die "no .deb files in $DEBDIR"

say "building an APT repository from ${#debs[@]} package(s)"
rm -rf "$OUT"
mkdir -p "$OUT/dists/$SUITE/$COMPONENT" "$OUT/pool/$COMPONENT"

declare -a rels=()
declare -A have_arch=()
for deb in "${debs[@]}"; do
    pkg=$(dpkg-deb -f "$deb" Package)
    arch=$(dpkg-deb -f "$deb" Architecture)
    [[ -n $pkg && -n $arch ]] || die "cannot read Package/Architecture from $deb"

    rel=pool/$COMPONENT/${pkg:0:1}/$pkg/${deb##*/}
    mkdir -p "$OUT/${rel%/*}"
    cp "$deb" "$OUT/$rel"
    rels+=("$rel")
    [[ $arch == all ]] || have_arch[$arch]=1
done

((${#have_arch[@]})) || die "only Architecture: all packages; nothing arch-specific to index"

# Stable order, so a rebuild does not produce a spurious diff.
mapfile -t arches < <(printf '%s\n' "${!have_arch[@]}" | sort)
say "architectures: ${arches[*]}"

# Write one Packages index.  Architecture: all packages are repeated in every
# architecture, which is how Debian repositories do it.
write_index() { # arch output
    local arch=$1 out=$2 i deb rel a control desc size sum
    : >"$out"
    for i in "${!debs[@]}"; do
        deb=${debs[$i]}
        rel=${rels[$i]}
        a=$(dpkg-deb -f "$deb" Architecture)
        [[ $a == "$arch" || $a == all ]] || continue

        control=$(dpkg-deb -f "$deb")
        desc=$(printf '%s\n' "$control" | sed -n '/^Description:/,$p')
        size=$(wc -c <"$OUT/$rel" | tr -d ' ')
        sum=$(sha256sum "$OUT/$rel")
        sum=${sum%% *}

        # Filename/Size/SHA256 before Description, whose continuation lines must
        # stay at the end of the stanza.
        printf '%s\n' "$control" | sed '/^Description:/,$d' >>"$out"
        printf 'Filename: %s\nSize: %s\nSHA256: %s\n' "$rel" "$size" "$sum" >>"$out"
        if [[ -n $desc ]]; then
            printf '%s\n' "$desc" >>"$out"
        fi
        printf '\n' >>"$out"
    done
}

for arch in "${arches[@]}"; do
    dir=$OUT/dists/$SUITE/$COMPONENT/binary-$arch
    mkdir -p "$dir"
    write_index "$arch" "$dir/Packages"
    gzip -9 -n -c "$dir/Packages" >"$dir/Packages.gz"
    say "indexed binary-$arch"
done

release=$OUT/dists/$SUITE/Release
{
    printf 'Origin: freebuff-native\n'
    printf 'Label: freebuff-native\n'
    printf 'Suite: %s\n' "$SUITE"
    printf 'Codename: %s\n' "$SUITE"
    printf 'Version: 1.0\n'
    printf 'Architectures: %s\n' "${arches[*]}"
    printf 'Components: %s\n' "$COMPONENT"
    printf 'Description: Native Freebuff CLI for Termux without proot\n'
    printf 'Date: %s\n' "$(date -u '+%a, %d %b %Y %H:%M:%S UTC')"
    printf 'MD5Sum:\n'
    for arch in "${arches[@]}"; do
        for f in "main/binary-$arch/Packages" "main/binary-$arch/Packages.gz"; do
            path=$OUT/dists/$SUITE/$f
            printf ' %s %s %s\n' \
                "$(md5sum "$path" | cut -d' ' -f1)" \
                "$(wc -c <"$path" | tr -d ' ')" "$f"
        done
    done
    printf 'SHA256:\n'
    for arch in "${arches[@]}"; do
        for f in "main/binary-$arch/Packages" "main/binary-$arch/Packages.gz"; do
            path=$OUT/dists/$SUITE/$f
            sum=$(sha256sum "$path")
            printf ' %s %s %s\n' "${sum%% *}" \
                "$(wc -c <"$path" | tr -d ' ')" "$f"
        done
    done
} >"$release"

if [[ -n $KEY ]]; then
    command -v gpg >/dev/null 2>&1 || die "gpg is missing; cannot sign with $KEY"
    gpg --batch --yes --local-user "$KEY" --armor --detach-sign \
        -o "$OUT/dists/$SUITE/Release.gpg" "$release"
    gpg --batch --yes --local-user "$KEY" --clearsign \
        -o "$OUT/dists/$SUITE/InRelease" "$release"
    say "signed the Release file"
else
    warn "no signing key: the repository is unsigned and needs trusted=yes"
fi

# Serve the public key next to the repository, for people who verify by hand.
if [[ -s $HERE/freebuff.gpg ]]; then
    install -m 644 "$HERE/freebuff.gpg" "$OUT/freebuff.gpg"
fi

say "repository tree ready in $OUT"
