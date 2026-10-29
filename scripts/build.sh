#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

IMAGE="${IMAGE:-linux-handheld-builder:latest}"
CCACHE_DIR="${CCACHE_DIR:-${HERE}/.ccache}"
DOCKER="${DOCKER:-docker}"

[ "$(uname -m)" = "aarch64" ] || {
    echo "!! host is $(uname -m), not aarch64. These build natively by design." >&2
    exit 1
}

all_packages() {
    local d
    for d in packages/*/; do
        [ -f "${d}PKGBUILD" ] || continue
        basename "${d}"
    done
}

case "${1:-}" in
    --all)     mapfile -t TARGETS < <(all_packages); shift ;;
    "")        echo "usage: $0 <package>... | --all" >&2; exit 1 ;;
    *)         TARGETS=("$@") ;;
esac

if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "==> nothing to build"
    exit 0
fi

for p in "${TARGETS[@]}"; do
    [ -f "packages/${p}/PKGBUILD" ] || { echo "!! no packages/${p}/PKGBUILD" >&2; exit 1; }
done
echo "==> building: ${TARGETS[*]}"

for p in "${TARGETS[@]}"; do
    grep -q '^PATCHES_REPO=' "packages/${p}/upstream.env" 2>/dev/null || continue
    ./scripts/fetch-patch-set.sh "${p}"
done

if ! "${DOCKER}" image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "==> building ${IMAGE}"
    "${DOCKER}" build -t "${IMAGE}" .
fi

mkdir -p out "${CCACHE_DIR}"

"${DOCKER}" run --rm \
    -v "${HERE}:/work" \
    -v "${CCACHE_DIR}:/ccache" \
    --user root \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -e CCACHE_DIR=/ccache -e CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}" \
    -e PACKAGER="${PACKAGER:-Waltteri Hooli <1420194+wahooli@users.noreply.github.com>}" \
    -e TARGETS="${TARGETS[*]}" \
    -w /work \
    "${IMAGE}" \
    /work/scripts/build-in-container.sh

echo
echo "──────────────────────────────────────────────"
shopt -s nullglob
for f in out/*.pkg.tar.zst; do
    printf ' %-56s %6s\n' "$(basename "${f}")" "$(du -h "${f}" | cut -f1)"
done
shopt -u nullglob
echo "──────────────────────────────────────────────"
