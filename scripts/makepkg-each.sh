#!/usr/bin/env bash
#
# The unprivileged half of the container build: makepkg, once per package.
# See scripts/build-in-container.sh.
set -euo pipefail
cd /work

failed=()
for p in ${TARGETS}; do
    echo "──────────────────────────────────────────────"
    echo ":: ${p}"
    echo "──────────────────────────────────────────────"
    # A subshell per package so a `cd` or an exported var from one PKGBUILD
    # cannot leak into the next.
    #
    # --syncdeps installs makedepends via the build user's NOPASSWD sudo.
    # --cleanbuild so a stale src/ from a previous version cannot be reused --
    # these packages track moving upstreams, which is exactly where that bites.
    if ! ( cd "packages/${p}" && makepkg --noconfirm --syncdeps --cleanbuild --force ); then
        echo ":: FAILED: ${p}"
        failed+=("${p}")
    fi
done

if [ ${#failed[@]} -gt 0 ]; then
    echo
    echo ":: ${#failed[@]} package(s) failed: ${failed[*]}"
    exit 1
fi
