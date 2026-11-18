# shellcheck shell=bash

# The glibc runtime: package index, dependency closure, and installation.
#
# The closure is ~41 packages.  apt would order them, but apt cannot run when
# euid is 0, so the fallback resolves Depends by hand from the Packages index:
# one tab-separated line per stanza, then a breadth-first walk.

# Where the glibc packages come from.  Overridable for mirrors.
GLIBC_REPO=${FREEBUFF_GLIBC_REPO:-https://packages-cf.termux.dev/apt/termux-glibc}

glibc_is_installed() {
    [[ -e $GLIBC_DIR/lib/libc.so.6 ]] || return 1
    [[ -e $GLIBC_DIR/bin/ld.so || -e $GLIBC_DIR/lib/$LOADER ]] || return 1
}

# Sets IDX_PATH rather than printing it: callers run under $(...) and any
# progress line on stdout would end up inside the path.
fetch_glibc_index() {
    local xz=$CACHE/Packages.xz txt=$CACHE/Packages."$PKGARCH"
    mkdir -p "$CACHE"
    if ((FORCE)) || [[ ! -s $txt ]]; then
        install_tool_if_missing xz
        act "downloading the glibc package index ($PKGARCH)"
        download_file "$GLIBC_REPO/dists/glibc/stable/binary-$PKGARCH/Packages.xz" "$xz" || return 1
        xz -dc "$xz" >"$txt" || return 1
        CHANGED=$((CHANGED + 1))
    fi
    IDX_PATH=$txt
}

packages_to_tsv() { # Packages -> pkg \t version \t filename \t deps
    local line pkg='' ver='' fn='' deps=''
    emit() {
        if [[ -n $pkg ]]; then
            printf '%s\t%s\t%s\t%s\n' "$pkg" "$ver" "$fn" "$deps"
        fi
    }
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ -z $line ]]; then
            emit
            pkg='' ver='' fn='' deps=''
            continue
        fi
        case $line in
            'Package: '*)  pkg=${line#Package: } ;;
            'Version: '*)  ver=${line#Version: } ;;
            'Filename: '*) fn=${line#Filename: } ;;
            'Depends: '*|'Pre-Depends: '*)
                local more=${line#*: }
                deps=${deps:+$deps,}$more
                ;;
        esac
    done <"$1"
    emit
}

# resolve_package_closure <tsv> <package...> -> pkg \t version \t filename
resolve_package_closure() {
    local tsv=$1
    shift
    local -A ver_of=()
    local -A fn_of=()
    local -A deps_of=()
    local -A seen=()
    local pkg ver fn deps
    while IFS=$'\t' read -r pkg ver fn deps; do
        ver_of[$pkg]=$ver
        fn_of[$pkg]=$fn
        deps_of[$pkg]=$deps
    done <"$tsv"

    local -a queue=("$@")
    local -a alts=()
    while ((${#queue[@]})); do
        pkg=${queue[0]}
        queue=("${queue[@]:1}")
        if [[ -n ${seen[$pkg]:-} ]]; then continue; fi
        seen[$pkg]=1
        if [[ -z ${fn_of[$pkg]:-} ]]; then
            warn "package $pkg is not in the $PKGARCH index; skipping"
            continue
        fi
        printf '%s\t%s\t%s\n' "$pkg" "${ver_of[$pkg]}" "${fn_of[$pkg]}"
        IFS=',' read -r -a alts <<<"${deps_of[$pkg]:-}"
        local alt first
        for alt in "${alts[@]}"; do
            alt=${alt//[[:space:]]/}
            alt=${alt%%\(*}   # drop "(>= 1.0)" version constraints
            alt=${alt%%:*}    # drop ":any" multi-arch suffixes
            first=${alt%%|*}  # first alternative of "a | b"
            if [[ -n $first ]]; then queue+=("$first"); fi
        done
    done
}

enable_glibc_repository() {
    local src=$PREFIX/etc/apt/sources.list.d/glibc.list
    if grep -qs 'termux-glibc' "$src"; then
        ok "glibc apt source already present"
        return 0
    fi
    act "adding the glibc apt source"
    if pkg install -y glibc-repo >/dev/null 2>&1 && grep -qs 'termux-glibc' "$src"; then
        CHANGED=$((CHANGED + 1))
        return 0
    fi
    # glibc-repo ships exactly one file, so writing it is equivalent when the
    # package cannot be installed (uid 0, stale index, offline mirror).
    warn "glibc-repo package unavailable; writing the source line directly"
    mkdir -p "${src%/*}"
    printf 'deb %s/ glibc stable\n' "$GLIBC_REPO" >"$src"
    CHANGED=$((CHANGED + 1))
}

install_glibc_with_apt() {
    enable_glibc_repository
    # The new source has no index yet; without this pkg cannot find glibc-runner.
    pkg update -y >"$CACHE/apt-update.log" 2>&1 || warn "pkg update failed (see $CACHE/apt-update.log)"
    pkg install -y glibc-runner
}

# Write the closure's not-yet-installed packages to a list, one per line:
# pkg \t version \t filename.  A package already at the index version is
# skipped, so re-running does not re-download 72 MB of packages.
select_missing_glibc_packages() { # tsv list
    local tsv=$1 list=$2 pkg ver fn have total=0 count=0
    : >"$list"
    while IFS=$'\t' read -r pkg ver fn; do
        total=$((total + 1))
        have=$(dpkg-query -W -f '${Version}' "$pkg" 2>/dev/null || true)
        if [[ $have == "$ver" ]]; then
            ok "$pkg $ver already installed"
        else
            printf '%s\t%s\t%s\n' "$pkg" "$ver" "$fn" >>"$list"
            count=$((count + 1))
        fi
    done < <(resolve_package_closure "$tsv" glibc-runner)
    ((total)) || die "glibc-runner is not in the $PKGARCH index"
    ((count)) || ok "every glibc package is already installed"
}

download_glibc_packages() { # list debdir
    local list=$1 debdir=$2 pkg ver fn deb
    mkdir -p "$debdir"
    while IFS=$'\t' read -r pkg ver fn; do
        deb=$debdir/${fn##*/}
        if [[ ! -s $deb ]]; then
            act "downloading $pkg $ver"
            download_file "$GLIBC_REPO/$fn" "$deb" || die "download failed: $GLIBC_REPO/$fn"
            CHANGED=$((CHANGED + 1))
        fi
    done <"$list"
}

install_glibc_packages() { # list debdir
    local list=$1 debdir=$2 pkg ver fn
    local -a debs=()
    while IFS=$'\t' read -r pkg ver fn; do
        debs+=("$debdir/${fn##*/}")
    done <"$list"
    ((${#debs[@]})) || return 0

    act "installing ${#debs[@]} package(s) with dpkg"
    if ! dpkg -i "${debs[@]}" >"$CACHE/dpkg.log" 2>&1; then
        warn "dpkg reported problems; finishing configuration (see $CACHE/dpkg.log)"
        dpkg --configure -a >>"$CACHE/dpkg.log" 2>&1 || true
    fi
    CHANGED=$((CHANGED + 1))
}

install_glibc_with_dpkg() {
    fetch_glibc_index || die "cannot download the glibc index for $PKGARCH; is $GLIBC_REPO reachable?"
    local tsv=$CACHE/Packages."$PKGARCH".tsv
    local list=$CACHE/glibc-packages.list
    packages_to_tsv "$IDX_PATH" >"$tsv"
    select_missing_glibc_packages "$tsv" "$list"
    download_glibc_packages "$list" "$CACHE/debs"
    install_glibc_packages "$list" "$CACHE/debs"
}

install_glibc() {
    act "installing the glibc runtime into $GLIBC_DIR"
    mkdir -p "$CACHE"
    if ! install_glibc_with_apt; then
        warn "apt could not install glibc-runner; resolving the closure with dpkg instead"
    fi
    # apt failing silently (uid 0, wrong arch) is exactly the case docs/investigation.md hit.
    if ! glibc_is_installed; then
        install_glibc_with_dpkg
    fi
    glibc_is_installed || die "glibc runtime is still incomplete: $GLIBC_DIR/lib/$LOADER is missing.
    See $CACHE/dpkg.log.  Do not 'fix' this by patching the freebuff binary."
    ok "glibc runtime ready ($GLIBC_DIR)"
}

ensure_glibc() {
    if glibc_is_installed && ((!FORCE)); then
        ok "glibc runtime present ($GLIBC_DIR, loader $LOADER)"
        return 0
    fi
    if ((CHECK)); then
        warn "missing: glibc runtime in $GLIBC_DIR"
        MISSING=$((MISSING + 1))
        return 0
    fi
    if ((DRY_RUN)); then
        act "would install glibc-runner + glibc into $GLIBC_DIR ($PKGARCH)"
        return 0
    fi
    install_glibc
}
