# shellcheck shell=bash

# --download against a fake npm metadata endpoint and release archive.

begin '--download'
new_fake_termux h
target=$(download_target)
rm -f "$HOME_DIR/.config/manicode/freebuff" \
      "$HOME_DIR/.config/manicode/rg" \
      "$HOME_DIR/.config/manicode/tree-sitter.wasm"
new_fake_release
install_fake_curl
# --download must not silently harvest credentials from an old proot rootfs.
old=$PREFIX_DIR/var/lib/proot-distro/containers/debian/rootfs/root/.config/manicode
mkdir -p "$old"
printf 'old creds\n' >"$old/credentials.json"

out=$(run_installer --download 2>&1)
expect_status 0 $? '--download install exits 0'
expect_contains "$out" 'checksum verified' 'the archive checksum is verified'
expect_contains "$out" 'freebuff 9.9.9 installed' 'the installed version is reported'
[[ $(head -c 4 "$HOME_DIR/.config/manicode/freebuff") == $'\177ELF' ]]
expect_status 0 $? 'the downloaded binary is an ELF'
[[ -f $HOME_DIR/.config/manicode/tree-sitter.wasm ]]
expect_status 0 $? 'tree-sitter.wasm is installed'
expect_contains "$(cat "$HOME_DIR/.config/manicode/tree-sitter.wasm")" 'wasm payload' \
    'the wasm comes from the archive'
[[ ! -f $HOME_DIR/.config/manicode/credentials.json ]]
expect_status 0 $? '--download leaves proot credentials alone'
expect_contains "$out" 'pkg install ripgrep' 'missing ripgrep is a warning, not a failure'

rm -f "$HOME_DIR/.config/manicode/freebuff"
out=$(run_installer --download 2>&1)
expect_status 0 $? 'repairing with --download exits 0'
expect_contains "$out" 'archive already downloaded' 'the cached archive is reused'
expect_contains "$out" 'tree-sitter.wasm up to date' 'matching wasm is left untouched'

out=$(run_installer --download 2>&1)
expect_status 0 $? 'a complete --download install re-runs cleanly'
expect_contains "$out" '0 change(s) applied' 'second run applies no changes'

begin '--download rejects a bad archive'
cp "$FAKE_HTTP/freebuff-$target.tar.gz" "$WORK/good.tgz"
printf 'not a tarball\n' >"$FAKE_HTTP/freebuff-$target.tar.gz"
rm -f "$HOME_DIR/.config/manicode/freebuff" \
      "$FAKE/tmp/freebuff-native/freebuff-$target.tar.gz"
out=$(run_installer --download 2>&1)
expect_status 1 $? 'a checksum mismatch is fatal'
expect_contains "$out" 'checksum mismatch' 'the mismatch is named'
[[ ! -f $HOME_DIR/.config/manicode/freebuff ]]
expect_status 0 $? 'no binary is installed from a bad archive'
[[ ! -e $FAKE/tmp/freebuff-native/freebuff-$target.tar.gz ]]
expect_status 0 $? 'the corrupt cache entry is discarded'
cp "$WORK/good.tgz" "$FAKE_HTTP/freebuff-$target.tar.gz"

begin '--download without the release metadata'
mv "$FAKE_HTTP/latest" "$FAKE_HTTP/latest.off"
rm -f "$HOME_DIR/.config/manicode/freebuff"
out=$(run_installer --download 2>&1)
expect_status 1 $? 'an unreachable metadata file is fatal'
expect_contains "$out" '--from' 'the error points at the offline path'
mv "$FAKE_HTTP/latest.off" "$FAKE_HTTP/latest"

begin '--download --dry-run'
new_fake_termux i
rm -f "$HOME_DIR/.config/manicode/freebuff"
out=$(run_installer --download --dry-run 2>&1)
expect_status 0 $? '--download --dry-run exits 0'
expect_contains "$out" 'would download the latest freebuff release' 'the download is announced'
[[ ! -f $HOME_DIR/.config/manicode/freebuff ]]
expect_status 0 $? '--download --dry-run writes nothing'

