#!/usr/bin/env bash
#
# Behavioural tests for shim/freebuff-spawn-shim.c, runnable on any Linux/macOS
# bash with a C compiler.
#
# The fixtures are two tiny programs: a launcher that starts a child the way
# freebuff starts its broker (execve, plus posix_spawn for the defensive hook),
# and a fake loader that prints the argv and LD_PRELOAD it was handed.  The shim
# is compiled for the host, preloaded into the launcher, and observed from
# outside, so nothing here needs Termux or the 136 MB binary.
#
# Usage: bash test/shim-test.sh        (CC=clang to pick the compiler)

set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t freebuff-shim-test)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

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

# ------------------------------------------------------------------ fixtures --

CC=${CC:-cc}
if ! command -v "$CC" >/dev/null 2>&1; then
    printf 'SKIP: no C compiler (%s) on PATH; set CC to one\n' "$CC"
    exit 0
fi

build() { # out source [flags...]
    local out=$1 src=$2
    shift 2
    "$CC" "$@" -o "$out" "$src" 2>"$WORK/build.log"
}

if ! build "$WORK/shim.so" "$HERE/shim/freebuff-spawn-shim.c" \
        -fPIC -shared -nostdlib -nostdinc -O2 -Wall -Wextra; then
    printf 'SKIP: the shim does not build with %s\n' "$CC"
    cat "$WORK/build.log"
    exit 0
fi
if ! build "$WORK/launcher" "$HERE/test/shim/launcher.c" -O2; then
    printf 'SKIP: the launcher fixture does not build with %s\n' "$CC"
    cat "$WORK/build.log"
    exit 0
fi
if ! build "$WORK/ld.so" "$HERE/test/shim/fake-loader.c" -O2; then
    printf 'SKIP: the loader fixture does not build with %s\n' "$CC"
    cat "$WORK/build.log"
    exit 0
fi

LIBDIR=$WORK/lib
mkdir -p "$LIBDIR"
: >"$WORK/freebuff"

SHIM=$WORK/shim.so
LOADER=$WORK/ld.so
LOG=$WORK/shim.log

# The variables below are read by the shim inside the child.  Set them in the
# environment of the launcher directly (not through env(1)): env is itself a
# process, and the shim strips LD_PRELOAD from every child, so the launcher
# would start without the shim and the run would silently test nothing.
run_launcher() { # args...
    LD_PRELOAD="$SHIM" \
    FREEBUFF_NATIVE_LOADER="$LOADER" \
    FREEBUFF_NATIVE_LIBDIR="$LIBDIR" \
    FREEBUFF_NATIVE_BINARY="$WORK/freebuff" \
    FREEBUFF_SHIM_LOG="$LOG" \
        "$WORK/launcher" "$@" 2>&1
}

# --------------------------------------------------------------------- tests --

begin 'the broker exec is rewritten through the loader'
out=$(run_launcher "$LOADER" --terminal-command-broker)
expect_status 0 $? 'launcher exits 0'
expect_contains "$out" "argv[0]=$LOADER" 'argv[0] stays the loader'
expect_contains "$out" 'argv[1]=--library-path' 'the library path is inserted'
expect_contains "$out" "argv[2]=$LIBDIR" 'the libdir is what the wrapper exported'
expect_contains "$out" "argv[3]=$WORK/freebuff" 'the pristine binary is re-executed'
expect_contains "$out" 'argv[4]=--terminal-command-broker' 'the broker flag is preserved'
count=$(printf '%s\n' "$out" | grep -c '^argv\[')
if [[ $count == 5 ]]; then
    ok 'no extra arguments were invented'
else
    notok 'no extra arguments were invented' "wanted 5 argv lines, got $count"
fi

begin 'LD_PRELOAD is stripped from children'
expect_contains "$out" 'LD_PRELOAD=<unset>' 'the broker does not inherit the glibc shim'
expect_missing "$out" "$SHIM" 'the shim path is gone from the child environment'

begin 'only the broker exec is rewritten'
out=$(run_launcher "$LOADER" --version)
expect_status 0 $? 'launcher exits 0'
expect_contains "$out" 'argv[1]=--version' 'the original argument survives'
expect_missing "$out" '--library-path' 'a normal exec is left alone'
expect_contains "$out" 'LD_PRELOAD=<unset>' 'LD_PRELOAD is stripped here too'

begin 'posix_spawn is handled the same way'
out=$(run_launcher --spawn "$LOADER" --terminal-command-broker)
expect_status 0 $? 'launcher exits 0'
expect_contains "$out" 'argv[1]=--library-path' 'the spawned broker gets the loader arguments'
expect_contains "$out" "argv[3]=$WORK/freebuff" 'the spawned broker gets the binary'
expect_contains "$out" 'LD_PRELOAD=<unset>' 'the spawned broker gets a clean environment'

begin 'a broker exec without configuration is left alone'
out=$(LD_PRELOAD="$SHIM" FREEBUFF_SHIM_LOG="$LOG" \
        "$WORK/launcher" "$LOADER" --terminal-command-broker 2>&1)
expect_status 0 $? 'launcher exits 0'
expect_contains "$out" 'argv[1]=--terminal-command-broker' 'the broken exec is not made worse'
expect_missing "$out" '--library-path' 'nothing is inserted without FREEBUFF_NATIVE_*'
expect_contains "$out" 'LD_PRELOAD=<unset>' 'LD_PRELOAD is still stripped'

begin 'the shim explains what it did'
log=$(cat "$LOG" 2>/dev/null || true)
expect_contains "$log" 'rewrote broker exec through the loader' 'the rewrite is logged'
expect_contains "$log" 'rewrote broker posix_spawn' 'the posix_spawn rewrite is logged'
expect_contains "$log" 'broker exec left broken: missing config' 'the unconfigured case is logged'

begin 'the exec trace confirms interposition'
tracelog=$WORK/trace.log
LD_PRELOAD="$SHIM" FREEBUFF_SHIM_LOG="$tracelog" FREEBUFF_SHIM_TRACE=1 \
    FREEBUFF_NATIVE_LOADER="$LOADER" FREEBUFF_NATIVE_LIBDIR="$LIBDIR" \
    FREEBUFF_NATIVE_BINARY="$WORK/freebuff" \
    "$WORK/launcher" "$LOADER" --terminal-command-broker >/dev/null 2>&1
expect_contains "$(cat "$tracelog" 2>/dev/null || true)" "[exec] $LOADER" \
    'the trace lists every exec path'
expect_contains "$(cat "$tracelog" 2>/dev/null || true)" 'rewrote broker' \
    'the trace run still logs the broker decision'

# ------------------------------------------------------------------- result --

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
