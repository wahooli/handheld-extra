#!/usr/bin/env bash
set -euo pipefail
cd /work

failed=()
for p in ${TARGETS}; do
    echo "──────────────────────────────────────────────"
    echo ":: ${p}"
    echo "──────────────────────────────────────────────"
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
