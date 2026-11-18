# shellcheck shell=bash

# Shared assertion helpers for the test suites.

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

expect_missing() { # haystack needle description
    case $1 in
        *"$2"*) notok "$3" "output unexpectedly contains '$2'" ;;
        *) ok "$3" ;;
    esac
}
