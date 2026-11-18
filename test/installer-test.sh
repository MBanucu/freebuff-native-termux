#!/usr/bin/env bash
#
# Tests for freebuff-native-termux.sh and its lib/ modules, runnable on any
# Linux/macOS bash.
#
# Nothing here needs Termux.  The installer only requires $PREFIX, $HOME, a bash,
# a dpkg on PATH and a glibc loader tree, so every test builds a throwaway "fake
# Termux" prefix and points the installer at it.  Real device paths are never
# touched, and the ~400 MB glibc runtime is replaced by a stub loader that
# asserts the binary it was handed actually exists.  The prefix also gets a fake
# clang that just creates the -o file, and a fake curl that serves a local
# release, so the shim build and --download are exercised without a compiler or
# network.
#
# The cases live in test/installer/, one file per area:
#   cli.sh       command line, environment guard, CPU mapping, module loading
#   glibc.sh     the dependency resolver
#   install.sh   install, repair, --check, --dry-run, wrapper, shim, ripgrep
#   download.sh  --download against a fake metadata endpoint and archive
#
# Usage: bash test/installer-test.sh

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t freebuff-test)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# shellcheck source=/dev/null
source "$ROOT/test/assertions.sh"
# shellcheck source=/dev/null
source "$ROOT/test/fake-termux.sh"

for case_file in cli glibc install download; do
    # shellcheck source=/dev/null
    source "$ROOT/test/installer/$case_file.sh"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
