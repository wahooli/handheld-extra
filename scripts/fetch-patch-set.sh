#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

PKG="${1:?usage: fetch-patch-set.sh <package>}"
CONF="packages/${PKG}/upstream.env"
[ -f "${CONF}" ] || { echo "!! no ${CONF}" >&2; exit 1; }

PATCHES_REPO=; PATCHES_PATH=; PATCHES_REF='s/.*/&/'; CURRENT=
# shellcheck source=/dev/null
source "${CONF}"
[ -n "${PATCHES_REPO}" ] && [ -n "${PATCHES_PATH}" ] \
    || { echo "!! ${PKG} declares no PATCHES_REPO/PATCHES_PATH -- it carries no external patch set" >&2; exit 1; }
[ -n "${CURRENT}" ] || { echo "!! ${CONF} has no CURRENT" >&2; exit 1; }

REF="$(printf '%s' "${CURRENT}" | sed -E "${PATCHES_REF}")"
[ -n "${REF}" ] || { echo "!! PATCHES_REF produced an empty ref from CURRENT=${CURRENT}" >&2; exit 1; }

DEST="packages/${PKG}/patch-set"

rm -rf "${DEST}"; mkdir -p "${DEST}"
echo "==> ${PATCHES_REPO} ${PATCHES_PATH}/patches @ ${CURRENT} (ref ${REF})"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
curl -fsSL --retry 3 -o "${TMP}/a.tar.gz" \
    "https://codeload.github.com/${PATCHES_REPO}/tar.gz/${REF}" \
    || { echo "!! could not fetch ${PATCHES_REPO} at ${REF}" >&2; exit 1; }

tar -xzf "${TMP}/a.tar.gz" -C "${TMP}" --strip-components=1 \
    --wildcards "*/${PATCHES_PATH}/patches/*.patch" 2>/dev/null \
    || { echo "!! no ${PATCHES_PATH}/patches in ${PATCHES_REPO} at ${REF}" >&2; exit 1; }

shopt -s nullglob
FILES=("${TMP}/${PATCHES_PATH}/patches"/*.patch)
shopt -u nullglob
[ ${#FILES[@]} -gt 0 ] || { echo "!! no patches found at ${REF}" >&2; exit 1; }

for f in "${FILES[@]}"; do
    cp "${f}" "${DEST}/"
    echo "    $(basename "${f}")"
done
echo "==> ${#FILES[@]} patch(es) in ${DEST}"
