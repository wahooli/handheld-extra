#!/usr/bin/env bash
#
# Fetch a package's external patch set, at the ref its upstream.env pins.
#
#   scripts/fetch-patch-set.sh gamescope
#
# The patches are NOT committed here, for the same reason the kernel repo does
# not commit its patch stack: they belong to whoever maintains them, and a copy
# in this tree is a fork nobody notices they are keeping. What is committed is
# the pinned ref in upstream.env, which is the reviewable part.
#
# Driven entirely by upstream.env, so nothing here knows about any particular
# vendor:
#   PATCHES_REPO   owner/repo to take patches from
#   PATCHES_PATH   directory within it holding patches/
#   PATCHES_REF    how to turn CURRENT into a git ref (a sed expression)
#
# They land in packages/<pkg>/patch-set/, which is gitignored -- so they
# cannot be committed by accident and cannot make `build.sh --changed` think the
# package is permanently dirty.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

PKG="${1:?usage: fetch-patch-set.sh <package>}"
CONF="packages/${PKG}/upstream.env"
[ -f "${CONF}" ] || { echo "!! no ${CONF}" >&2; exit 1; }

PATCHES_REPO=; PATCHES_PATH=; PATCHES_REF='s/.*//'; CURRENT=
# shellcheck source=/dev/null
source "${CONF}"
[ -n "${PATCHES_REPO}" ] && [ -n "${PATCHES_PATH}" ] \
    || { echo "!! ${PKG} declares no PATCHES_REPO/PATCHES_PATH -- it carries no external patch set" >&2; exit 1; }
[ -n "${CURRENT}" ] || { echo "!! ${CONF} has no CURRENT" >&2; exit 1; }

# CURRENT identifies the published artifact; PATCHES_REF says how to get a git
# ref out of it. For armada that tag is <date>-<short-sha> and the sha half is
# the commit the artifact was built from, so the patch set matches the build.
REF="$(printf '%s' "${CURRENT}" | sed -E "${PATCHES_REF}")"
[ -n "${REF}" ] || { echo "!! PATCHES_REF produced an empty ref from CURRENT=${CURRENT}" >&2; exit 1; }

DEST="packages/${PKG}/patch-set"

rm -rf "${DEST}"; mkdir -p "${DEST}"
echo "==> ${PATCHES_REPO} ${PATCHES_PATH}/patches @ ${CURRENT} (ref ${REF})"

# The repository archive, not the contents API.
#
# Listing a directory through api.github.com costs a request against a 60/hour
# unauthenticated budget, and when that runs out this fails with a bare 403 that
# reads exactly like "the patches are gone". codeload has no such limit, needs no
# token, and one request replaces one-plus-N.
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
curl -fsSL --retry 3 -o "${TMP}/a.tar.gz" \
    "https://codeload.github.com/${PATCHES_REPO}/tar.gz/${REF}" \
    || { echo "!! could not fetch ${PATCHES_REPO} at ${REF}" >&2; exit 1; }

# One leading component, whose name embeds the resolved sha, so it is stripped
# rather than guessed at.
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
