# TUR recipe for freebuff-native.
#
# Draft for a pull request to termux-user-repository/tur: copy this directory
# to tur/freebuff-native/ there.  Nothing else is needed; the package builds
# from the tagged source archive.
#
# What the package is: an installer with a small C shim.  The upstream Freebuff
# binary (136 MB) is not redistributed; the launcher fetches the official
# release, verifies its published sha256, and installs the glibc runtime that
# the binary needs.  The payload itself is ~1.3k lines of bash plus the shim.
#
# The shim is compiled here, for the target architecture, so installing needs
# no compiler on the device.

TERMUX_PKG_HOMEPAGE=https://github.com/MBanucu/freebuff-native-termux
TERMUX_PKG_DESCRIPTION="Run the upstream Freebuff CLI on Termux through glibc, without proot"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="@MBanucu"
TERMUX_PKG_VERSION="1.1.0"
TERMUX_PKG_SRCURL="https://github.com/MBanucu/freebuff-native-termux/archive/refs/tags/v${TERMUX_PKG_VERSION}.tar.gz"
TERMUX_PKG_SHA256=7ef356292ca095f5c288b39119b3e2b526a392fc806ec0407423ec57a4d50c7c
# aarch64 and x86_64 only: the installer resolves the glibc loader by name and
# has no arm/i686 path.
TERMUX_PKG_EXCLUDED_ARCHES="arm, i686"
# The installer drives pkg/dpkg for the glibc runtime and the release archive.
TERMUX_PKG_DEPENDS="bash, curl, dpkg, tar"
TERMUX_PKG_RECOMMENDS="ripgrep"
TERMUX_PKG_BUILD_IN_SRC=true

termux_step_make_install() {
	local lib="$TERMUX_PREFIX/lib/freebuff-native"

	# The entry point sources lib/ from its own directory, so keep that layout.
	install -Dm755 "$TERMUX_PKG_SRCDIR/freebuff-native-termux.sh" \
		"$lib/freebuff-native.sh"
	install -Dm644 -t "$lib/lib" "$TERMUX_PKG_SRCDIR"/lib/*.sh
	install -Dm644 -t "$lib/shim" "$TERMUX_PKG_SRCDIR/shim/freebuff-spawn-shim.c"

	# Freestanding: no sysroot needed, and the installer looks for the object
	# under shim/prebuilt/<arch>/ first.
	mkdir -p "$lib/shim/prebuilt/$TERMUX_ARCH"
	$CC $CFLAGS -fPIC -shared -nostdlib -nostdinc -O2 -Wall -Wextra \
		-o "$lib/shim/prebuilt/$TERMUX_ARCH/freebuff-spawn-shim.so" \
		"$TERMUX_PKG_SRCDIR/shim/freebuff-spawn-shim.c"

	# A launcher, not a symlink: the installer resolves its data directory from
	# BASH_SOURCE, so it has to run under its real path.
	mkdir -p "$TERMUX_PREFIX/bin"
	sed -e "s|@PREFIX@|$TERMUX_PREFIX|g" \
		"$TERMUX_PKG_SRCDIR/packaging/termux/templates/launcher.in" \
		>"$TERMUX_PREFIX/bin/freebuff-native"
	chmod 755 "$TERMUX_PREFIX/bin/freebuff-native"

	install -Dm644 "$TERMUX_PKG_SRCDIR/README.md" \
		"$TERMUX_PREFIX/share/doc/$TERMUX_PKG_NAME/README.md"
}

termux_step_create_debscripts() {
	# Only finish the install when the glibc runtime is already there: apt and
	# dpkg hold a lock while maintainer scripts run, so the installer cannot use
	# them.  A network failure must not fail the package installation.
	cat <<-EOF > ./postinst
	#!$TERMUX_PREFIX/bin/sh
	if [ -e "$TERMUX_PREFIX/glibc/lib/libc.so.6" ]; then
	    "$TERMUX_PREFIX/bin/freebuff-native" --download ||
	        echo "freebuff-native: re-run 'freebuff-native --download' when online"
	else
	    echo "freebuff-native: run 'freebuff-native --download' to finish setup"
	fi
	exit 0
	EOF
}
