#!/data/data/com.termux/files/usr/bin/bash
#
# Add the freebuff-native APT repository to this Termux install.
#
#   curl -fsSL https://mbanucu.github.io/freebuff-native-termux/install.sh | bash
#
# Prefer to read what runs first? Download freebuff-repo_all.deb and install it
# with pkg; this script only does those two steps.

set -euo pipefail

REPO_URL=${FREEBUFF_REPO_URL:-https://mbanucu.github.io/freebuff-native-termux/}
[[ $REPO_URL == */ ]] || REPO_URL=$REPO_URL/

die() { printf '[x] %s\n' "$*" >&2; exit 1; }
say() { printf '[+] %s\n' "$*"; }

[[ -n ${PREFIX:-} && ${PREFIX} == *com.termux* ]] ||
    die "run this inside Termux: PREFIX is not a Termux prefix"
command -v pkg >/dev/null 2>&1 || die "pkg is missing; this is not Termux"

tmp=${TMPDIR:-$PREFIX/tmp}/freebuff-repo.deb
say "downloading freebuff-repo"
if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 20 -o "$tmp" "$REPO_URL/freebuff-repo_all.deb"
elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$tmp" "$REPO_URL/freebuff-repo_all.deb"
else
    die "neither curl nor wget is installed; run: pkg install curl"
fi

say "installing freebuff-repo"
pkg install -y "$tmp"

say "updating the package index"
pkg update

say "done; now run: pkg install freebuff-native"
