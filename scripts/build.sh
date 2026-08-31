#!/usr/bin/env bash
#
# Build one or more packages into out/.
#
#   scripts/build.sh wvkbd mangohud     build those
#   scripts/build.sh --all              build every package
#   scripts/build.sh --changed <ref>    build only what changed since <ref>
#
# Unlike the kernel repo, which has exactly one thing to build, this one is a
# set. --changed is what CI uses: rebuilding seven packages because one of them
# moved is the waste this whole split exists to avoid.
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

# Packages whose directory changed since a git ref. A change to anything outside
# packages/ -- a script, the Dockerfile, the workflow -- deliberately does NOT
# trigger a rebuild of everything: those change how packages are built, not what
# they contain, and the published package would be identical.
changed_packages() {
    local ref="$1" p
    # An initial push has no parent: GitHub passes the all-zero SHA as
    # github.event.before. Diffing against it cannot work, and returning nothing
    # would be wrong -- on a first push nothing has been published yet, so
    # everything is genuinely new.
    if [ -z "${ref}" ] || [ "${ref}" = "0000000000000000000000000000000000000000" ]; then
        echo "no previous commit to diff against; treating every package as changed" >&2
        all_packages
        return 0
    fi
    git rev-parse --verify "${ref}" >/dev/null 2>&1 || {
        echo "!! not a valid git ref: ${ref}" >&2; return 1; }
    for p in $(all_packages); do
        git diff --quiet "${ref}" HEAD -- "packages/${p}" || echo "${p}"
    done
}

case "${1:-}" in
    --all)     mapfile -t TARGETS < <(all_packages); shift ;;
    --changed) mapfile -t TARGETS < <(changed_packages "${2:?--changed needs a git ref}"); shift 2 ;;
    "")        echo "usage: $0 <package>... | --all | --changed <ref>" >&2; exit 1 ;;
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
