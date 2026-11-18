# shellcheck shell=bash

# Shared plumbing for the installer: messages, downloads, package installs and
# hashing.  Sourced by freebuff-native-termux.sh; not executable on its own.

log()  { printf '%s\n' "$*"; }
ok()   { printf '[ok] %s\n' "$*"; }
act()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

# Download a URL to a file with whichever of curl/wget exists.  The caller names
# the source in its error message; this only reports a missing client.
download_file() { # url destination
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 20 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        die "neither curl nor wget is installed; run: pkg install curl"
    fi
}

install_tool_if_missing() { # package name
    if command -v "$1" >/dev/null 2>&1; then return 0; fi
    act "installing $1"
    if ((DRY_RUN)); then return 0; fi
    pkg install -y "$1" >/dev/null 2>&1 || die "could not install $1"
    CHANGED=$((CHANGED + 1))
}

sha256_of_file() { # file
    local out
    if command -v sha256sum >/dev/null 2>&1; then
        out=$(sha256sum "$1") || return 1
        out=${out%% *}
    elif command -v shasum >/dev/null 2>&1; then
        out=$(shasum -a 256 "$1") || return 1
        out=${out%% *}
    elif command -v openssl >/dev/null 2>&1; then
        out=$(openssl dgst -sha256 "$1") || return 1
        out=${out##* }
    else
        return 1
    fi
    printf '%s\n' "$out"
}
