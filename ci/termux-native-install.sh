#!/data/data/com.termux/files/usr/bin/bash
# Install freebuff-native inside Termux on the emulator.
#
# ci/emulator-e2e.sh copies this file into Termux's home and runs it through
# `run-as com.termux` with PREFIX/HOME/PATH/LD_LIBRARY_PATH set.  It is not
# executed on the host.
#
#   ci-termux-native-install.sh [freebuff-native.deb]
#
# With a .deb it installs the release package (the preferred path).  Without
# one it falls back to the documented APT repository installer.  Either way it
# then runs `freebuff-native --download`, which installs the glibc runtime, the
# freebuff release and ripgrep, and finishes with the installer's own
# `--check`.  The final line is the marker the wrapper requires.

set -euo pipefail

PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
HOME=${HOME:-/data/data/com.termux/files/home}
export PREFIX HOME
export TMPDIR=${TMPDIR:-$PREFIX/tmp}
export PATH="$PREFIX/bin:/system/bin:/system/xbin"
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-$PREFIX/lib}
export DEBIAN_FRONTEND=noninteractive

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "== installing curl"
    pkg install -y curl
fi

if [ -n "${1:-}" ]; then
    echo "== dpkg -i $1"
    if ! dpkg -i "$1"; then
        dpkg --configure -a
    fi
else
    echo "== APT installer fallback"
    curl -fsSL https://mbanucu.github.io/freebuff-native-termux/install.sh | bash
    pkg install -y freebuff-native
fi

echo "== freebuff-native --download"
freebuff-native --download

echo "== freebuff-native --check"
freebuff-native --check

echo "NATIVE INSTALL COMPLETE"
