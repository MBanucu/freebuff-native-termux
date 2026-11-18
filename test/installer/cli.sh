# shellcheck shell=bash

# Command line, environment guard, CPU mapping, and module loading.

begin 'syntax and cli'
# Parse every shell file the repo ships, not just the entry point: a module that
# does not parse is only loaded on a device otherwise.
for sh in "$SCRIPT" "$ROOT"/lib/*.sh "$ROOT"/packaging/termux/*.sh "$ROOT"/packaging/termux/repo/*.sh \
          "$ROOT"/test/*.sh "$ROOT"/test/installer/*.sh; do
    bash -n "$sh"
    expect_status 0 $? "$(basename "$sh") parses"
done

out=$(bash "$SCRIPT" --help 2>&1)
expect_status 0 $? '--help exits 0'
expect_contains "$out" '--from' '--help documents --from'

out=$(bash "$SCRIPT" --bogus 2>&1)
expect_status 1 $? 'unknown option exits 1'
expect_contains "$out" 'unknown option' 'unknown option is reported'

out=$(bash "$SCRIPT" --download --from /tmp 2>&1)
expect_status 1 $? '--download with --from is rejected'
expect_contains "$out" 'cannot be combined' 'the conflict is explained'

begin 'refuses environments it must not touch'
out=$(env -u PREFIX bash "$SCRIPT" 2>&1)
expect_status 1 $? 'fails without PREFIX'
expect_contains "$out" 'Termux' 'explains that it needs Termux'

out=$(PREFIX=/opt/not-termux bash "$SCRIPT" 2>&1)
expect_status 1 $? 'fails on a non-Termux PREFIX'
expect_contains "$out" 'refusing' 'says it refuses that prefix'

begin 'arch detection'
expect_eq 'aarch64 ld-linux-aarch64.so.1' "$(helper 'arch_triplet aarch64')" 'aarch64 -> arm64 loader'
expect_eq 'x86_64 ld-linux-x86-64.so.2' "$(helper 'arch_triplet x86_64')" 'x86_64 -> x86-64 loader'
expect_eq 'aarch64 ld-linux-aarch64.so.1' "$(helper 'arch_triplet arm64')" 'arm64 alias works'
expect_eq '' "$(helper 'arch_triplet armv7l || true')" 'armv7l rejected (no 32-bit build)'
expect_eq '' "$(helper 'arch_triplet i686 || true')" 'i686 rejected (no 32-bit build)'

