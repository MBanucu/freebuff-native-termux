#!/usr/bin/env bash
#
# Static checks for the Android scaffold in android/.  The checks themselves
# live in test/android-check.py; this runner reports them in the same format as
# the other suites.
#
# Usage: bash test/android-test.sh

set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)

# shellcheck source=/dev/null
source "$HERE/test/assertions.sh"

if ! command -v python3 >/dev/null 2>&1; then
    printf 'SKIP: python3 is not installed\n'
    exit 0
fi

out=$(python3 "$HERE/test/android-check.py" 2>&1)
expect_status 0 $? 'the static checks pass'

while IFS=$'\t' read -r status message detail; do
    case $status in
        ok)   ok "$message" ;;
        fail) notok "$message" "${detail:-}" ;;
        '')   ;;
        *)    printf '%s\n' "$status" ;;
    esac
done <<<"$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
