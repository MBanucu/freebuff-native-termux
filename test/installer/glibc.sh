# shellcheck shell=bash

# The glibc dependency resolver (pure functions over a Packages index).

begin 'dependency resolver'
# glibc's Pre-Depends has no version constraint before the "|", so taking the
# wrong branch (or not splitting alternatives) drops libz from the closure.
cat >"$WORK/Packages" <<'PKG'
Package: glibc-runner
Version: 2.0-3
Depends: glibc (>= 2.44), bash
Filename: pool/main/g/glibc-runner/glibc-runner_2.0-3_aarch64.deb

Package: glibc
Version: 2.44
Pre-Depends: libz | liby
Filename: pool/main/g/glibc/glibc_2.44_aarch64.deb

Package: bash
Version: 5.2.37-1
Depends: libcap-ng (>= 0.8)
Filename: pool/main/b/bash/bash_5.2.37-1_aarch64.deb

Package: libcap-ng
Version: 0.8.5
Filename: pool/main/l/libcap-ng/libcap-ng_0.8.5_aarch64.deb

Package: libz
Version: 1.3
Filename: pool/main/l/libz/libz_1.3_aarch64.deb
PKG
helper 'PKGARCH=aarch64; packages_to_tsv "$2" > "$3"; resolve_package_closure "$3" glibc-runner > "$4"' \
    "$WORK/Packages" "$WORK/tsv" "$WORK/closure"
expect_status 0 $? 'resolver runs'
expect_eq 5 "$(grep -c '' "$WORK/tsv")" 'parsed every stanza'
expect_eq 5 "$(grep -c '' "$WORK/closure")" 'closure has 5 packages'
expect_eq 0 "$(cut -f1 "$WORK/closure" | sort | uniq -d | grep -c '')" 'no duplicates in the closure'
cut -f1 "$WORK/closure" | grep -qx 'libz'
expect_status 0 $? 'takes the first alternative of "libz | liby"'
cut -f1 "$WORK/closure" | grep -qx 'glibc-runner'
expect_status 0 $? 'includes the requested root package'
cut -f1 "$WORK/closure" | grep -qx 'liby'
expect_status 1 $? 'does not resolve the unused alternative'

