# shellcheck shell=bash

# Install, repair, --check, --dry-run, wrapper handling, shim, ripgrep.

begin 'install into a fake Termux'
new_fake_termux a
out=$(run_installer 2>&1)
expect_status 0 $? 'install exits 0'
expect_contains "$out" 'wrapper installed' 'wrapper written'
expect_contains "$out" 'spawn shim built' 'spawn shim built'

[[ -f $PREFIX_DIR/bin/freebuff ]]
expect_status 0 $? 'wrapper exists'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" "exec \"$PREFIX_DIR/glibc/bin/ld.so\"" \
    'wrapper execs the glibc loader'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" 'unset LD_PRELOAD' 'wrapper clears LD_PRELOAD'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" 'managed by freebuff-native-termux.sh' 'wrapper is marked'

[[ -s $HOME_DIR/.config/manicode/freebuff-spawn-shim.so ]]
expect_status 0 $? 'shim object exists'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" \
    'export LD_PRELOAD="$HOME/.config/manicode/freebuff-spawn-shim.so"' \
    'wrapper preloads the shim'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" \
    "export FREEBUFF_NATIVE_LOADER=\"$PREFIX_DIR/glibc/bin/ld.so\"" \
    'wrapper tells the shim which loader to use'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" \
    "export FREEBUFF_NATIVE_LIBDIR=\"$PREFIX_DIR/glibc/lib\"" \
    'wrapper tells the shim the library path'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" \
    'export FREEBUFF_NATIVE_BINARY="$HOME/.config/manicode/freebuff"' \
    'wrapper tells the shim which binary to re-exec'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" \
    'export CODEBUFF_RG_PATH="$HOME/.config/manicode/rg"' \
    'wrapper points code search at the local ripgrep'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" 'head -c 4' \
    'wrapper refuses to preload a non-ELF shim'

out=$(env HOME="$HOME_DIR" "$PREFIX_DIR/bin/freebuff" --version 2>&1)
expect_status 0 $? 'wrapper runs'
expect_contains "$out" '9.9.9-test' 'wrapper reaches the binary'

out=$(env HOME="$WORK/no-such-home" "$PREFIX_DIR/bin/freebuff" --version 2>&1)
expect_status 1 $? 'wrapper fails when HOME has no binary (the path is real, not faked)'

begin 'second run changes nothing'
out=$(run_installer 2>&1)
expect_status 0 $? 'second run exits 0'
expect_contains "$out" 'spawn shim present' 'shim recognised as current'
expect_contains "$out" 'wrapper up to date' 'wrapper recognised as current'
expect_contains "$out" '0 change(s) applied' 'no changes applied'

begin '--check'
run_installer --check >/dev/null 2>&1
expect_status 0 $? '--check passes on a complete install'

rm -f "$PREFIX_DIR/bin/freebuff"
out=$(run_installer --check 2>&1)
expect_status 1 $? '--check fails when the wrapper is missing'
expect_contains "$out" 'missing: wrapper' '--check names what is missing'
[[ ! -f $PREFIX_DIR/bin/freebuff ]]
expect_status 0 $? '--check does not repair'

begin '--dry-run'
out=$(run_installer --dry-run 2>&1)
expect_status 0 $? '--dry-run exits 0'
expect_contains "$out" 'would write' '--dry-run shows the wrapper'
[[ ! -f $PREFIX_DIR/bin/freebuff ]]
expect_status 0 $? '--dry-run writes nothing'

begin 'unmanaged wrapper is preserved'
printf '#!/bin/sh\necho old npm launcher\n' >"$PREFIX_DIR/bin/freebuff"
out=$(run_installer 2>&1)
expect_status 0 $? 'install over an unmanaged wrapper exits 0'
[[ -f $PREFIX_DIR/bin/freebuff.bak ]]
expect_status 0 $? 'old wrapper kept as .bak'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff.bak")" 'old npm launcher' '.bak holds the original'

begin '--check with an unmanaged wrapper'
new_fake_termux d
run_installer >/dev/null 2>&1
printf '#!/bin/sh\necho old npm launcher\n' >"$PREFIX_DIR/bin/freebuff"
out=$(run_installer --check 2>&1)
expect_status 0 $? '--check passes when an unmanaged wrapper is present'
expect_contains "$out" 'unmanaged wrapper' '--check says the wrapper is unmanaged'
[[ ! -f $PREFIX_DIR/bin/freebuff.bak ]]
expect_status 0 $? '--check does not touch the unmanaged wrapper'

begin '--check with a stale managed wrapper'
new_fake_termux e
run_installer >/dev/null 2>&1
printf '# stale edit\n' >>"$PREFIX_DIR/bin/freebuff"
out=$(run_installer --check 2>&1)
expect_status 1 $? '--check fails when the managed wrapper is stale'
expect_contains "$out" 'out of date' '--check reports the stale wrapper'

begin '--check and --dry-run without the shim'
new_fake_termux f
run_installer >/dev/null 2>&1
rm -f "$HOME_DIR/.config/manicode/freebuff-spawn-shim.so"
out=$(run_installer --check 2>&1)
expect_status 1 $? '--check fails when the shim is missing'
expect_contains "$out" 'missing: spawn shim' '--check names the missing shim'
[[ ! -f $HOME_DIR/.config/manicode/freebuff-spawn-shim.so ]]
expect_status 0 $? '--check does not build the shim'

out=$(run_installer --dry-run 2>&1)
expect_status 0 $? '--dry-run exits 0 without the shim'
expect_contains "$out" 'would build the spawn shim' '--dry-run announces the shim'
[[ ! -f $HOME_DIR/.config/manicode/freebuff-spawn-shim.so ]]
expect_status 0 $? '--dry-run does not build the shim'

begin 'a shim that cannot be built is not fatal'
new_fake_termux g
out=$(helper 'SHIM="$2/freebuff-spawn-shim.so"; SHIM_SRC="$3"; SHIM_TARGET=aarch64-linux-gnu; FREEBUFF_SHIM_CC=/nonexistent/cc ensure_shim' \
    "$HOME_DIR/.config/manicode" "$ROOT/shim/freebuff-spawn-shim.c" 2>&1)
expect_status 0 $? 'ensure_shim succeeds when the compiler is missing'
expect_contains "$out" 'could not build the spawn shim' 'the failed build is reported'
expect_contains "$out" 'will not work' 'it says what stops working'
[[ ! -e $HOME_DIR/.config/manicode/freebuff-spawn-shim.so ]]
expect_status 0 $? 'no half-built shim is left behind'

out=$(helper 'SHIM="$2/freebuff-spawn-shim.so"; SHIM_SRC="$2/no-such-shim.c" ensure_shim' \
    "$HOME_DIR/.config/manicode" 2>&1)
expect_status 0 $? 'ensure_shim succeeds without the source'
expect_contains "$out" 'no shim source' 'the missing source is reported'

begin 'prebuilt spawn shim'
new_fake_termux l
mkdir -p "$WORK/prebuilt"
printf '\177ELF\002\001\001fake prebuilt shim\n' >"$WORK/prebuilt/freebuff-spawn-shim.so"
out=$(helper 'SHIM="$2/freebuff-spawn-shim.so"; SHIM_PREBUILT="$3"; SHIM_SRC=/nonexistent; ensure_shim' \
    "$HOME_DIR/.config/manicode" "$WORK/prebuilt/freebuff-spawn-shim.so" 2>&1)
expect_status 0 $? 'ensure_shim succeeds with a prebuilt object'
expect_contains "$out" 'installing the prebuilt spawn shim' 'the prebuilt object is preferred'
expect_contains "$(cat "$HOME_DIR/.config/manicode/freebuff-spawn-shim.so")" 'fake prebuilt shim' \
    'the prebuilt object is copied into place'

printf 'not an elf\n' >"$WORK/prebuilt/bad.so"
out=$(helper 'SHIM="$2/out.so"; SHIM_PREBUILT="$3"; SHIM_SRC=/nonexistent; ensure_shim' \
    "$HOME_DIR/.config/manicode" "$WORK/prebuilt/bad.so" 2>&1)
expect_status 0 $? 'ensure_shim survives a non-ELF prebuilt object'
expect_contains "$out" 'not an ELF object' 'the bad prebuilt object is refused'
expect_contains "$out" 'no shim source' 'it falls back to the source path'
[[ ! -e $HOME_DIR/.config/manicode/out.so ]]
expect_status 0 $? 'nothing is installed from a bad prebuilt object'

begin 'repair'
new_fake_termux b
printf 'not an elf at all\n' >"$HOME_DIR/.config/manicode/freebuff"
mkdir -p "$WORK/src"
write_fake_binary "$WORK/src/freebuff"
out=$(run_installer --from "$WORK/src" 2>&1)
expect_status 0 $? 'installer repairs an unusable binary'
[[ -f $HOME_DIR/.config/manicode/freebuff.bak ]]
expect_status 0 $? 'unusable binary moved aside, not deleted'
expect_contains "$out" 'copying the freebuff binary' 'binary re-imported'

begin 'missing binary is a clear error'
new_fake_termux c
rm -f "$HOME_DIR/.config/manicode/freebuff"
out=$(run_installer 2>&1)
expect_status 1 $? 'dies when no binary can be found'
expect_contains "$out" '--from' 'error suggests --from'
expect_contains "$out" '--download' 'error also suggests --download'


begin 'ripgrep from the Termux prefix'
new_fake_termux m
rm -f "$HOME_DIR/.config/manicode/rg"
printf '#!/bin/sh\n' >"$PREFIX_DIR/bin/rg"
chmod +x "$PREFIX_DIR/bin/rg"
out=$(run_installer 2>&1)
expect_status 0 $? 'install succeeds without $CFG/rg'
expect_contains "$out" "using ripgrep from $PREFIX_DIR/bin/rg" 'the prefix ripgrep is accepted'
expect_contains "$(cat "$PREFIX_DIR/bin/freebuff")" \
    "export CODEBUFF_RG_PATH=\"$PREFIX_DIR/bin/rg\"" \
    'the wrapper falls back to the prefix ripgrep'
run_installer --check >/dev/null 2>&1
expect_status 0 $? '--check accepts ripgrep in the prefix'

begin '--check with no ripgrep at all'
new_fake_termux n
run_installer >/dev/null 2>&1
rm -f "$HOME_DIR/.config/manicode/rg"
out=$(run_installer --check 2>&1)
expect_status 1 $? '--check fails without ripgrep'
expect_contains "$out" 'missing: ripgrep' '--check names the missing ripgrep'

