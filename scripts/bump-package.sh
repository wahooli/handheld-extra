#!/usr/bin/env bash
# shellcheck disable=SC2034  # GITHUB_REPO/GIT_URL/OCI_IMAGE/OCI_TAG_RE and friends are
# read by upstream_latest() in scripts/lib-upstream.sh; shellcheck cannot follow a
# source boundary, so every variable this file only hands to the lib looks unused.
#
# Bump one package to its latest upstream and leave the tree ready to build.
#
#   scripts/bump-package.sh wvkbd
#   DRY_RUN=1 scripts/bump-package.sh wvkbd     say what would change
#
# What it edits, per the package's upstream.env:
#
#   VERSION_FROM=upstream-tag   the release/tag, through VERSION_SED
#   VERSION_FROM=oci-tag        the published OCI tag, dashes to dots
#   VERSION_FROM=repo-file      VERSION and COMMIT from a file in PATCHES_REPO,
#                               read at the ref the artifact was built from
#
# Checksums are refreshed with updpkgsums when the PKGBUILD carries real ones.
# Most here are SKIP -- git sources, or tarballs taken on trust -- so the
# download only happens for the two that need it.
#
# It does NOT commit or build. The caller decides that, which keeps this usable
# by hand on a package the poller refuses to touch.
#
# Exit codes, because the caller has to tell these apart:
#
#   0   bumped -- something the build consumes changed; build and publish it
#   1   failed
#   2   AUTOBUMP=no; this package needs a human
#   3   tracking only -- CURRENT moved but the package did not. Commit it, do
#       NOT build it. See the pkgrel section at the bottom for why that matters.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"
# shellcheck source=/dev/null
source scripts/lib-upstream.sh

PKG="${1:?usage: bump-package.sh <package>}"
D="packages/${PKG}"
[ -f "${D}/upstream.env" ] || { echo "!! no ${D}/upstream.env" >&2; exit 1; }
DRY_RUN="${DRY_RUN:-}"
IMAGE="${IMAGE:-linux-handheld-builder:latest}"

# Defaults, then the package's own values. GITHUB_REPO/GIT_URL/INCLUDE_PRERELEASE
# look unused here because upstream_latest() in lib-upstream.sh reads them.
TRACK=; GITHUB_REPO=; GIT_URL=; OCI_IMAGE=; OCI_TAG_RE=; AUR_PKG=; CURRENT=; INCLUDE_PRERELEASE=
PATCHES_REPO=; PATCHES_PATH=; PATCHES_REF='s/^[0-9]+-//'; VERSION_FILE=
AUTOBUMP=yes; VERSION_VAR=pkgver; VERSION_FROM=upstream-tag; VERSION_SED='s/^v//'
# shellcheck source=/dev/null
source "${D}/upstream.env"

[ "${TRACK}" = none ] && { echo "==> ${PKG}: first-party, nothing upstream"; exit 0; }
[ "${AUTOBUMP}" = no ] && {
    echo "!! ${PKG}: AUTOBUMP=no -- this one needs a human. See its upstream.env." >&2
    exit 2
}

latest="$(upstream_latest)" || true
[ -n "${latest}" ] || { echo "!! ${PKG}: could not resolve the latest upstream version" >&2; exit 1; }

if [ "$(printf '%s' "${CURRENT}" | normalise)" = "$(printf '%s' "${latest}" | normalise)" ]; then
    echo "==> ${PKG}: already at ${CURRENT}"
    exit 0
fi
echo "==> ${PKG}: ${CURRENT} -> ${latest}"

# ── work out the new packaged version ────────────────────────────────────────
newver=; newcommit=
case "${VERSION_FROM}" in
    upstream-tag)
        newver="$(printf '%s' "${latest}" | sed -E "${VERSION_SED}")" ;;
    repo-file)
        # The file is read at the ref the artifact was built from, so pkgver and
        # _commit match the published build rather than whatever the publisher's
        # default branch happens to say today.
        _ref="$(printf '%s' "${latest}" | sed -E "${PATCHES_REF}")"
        newver="$(repo_file_value "${PATCHES_REPO}" "${_ref}" "${VERSION_FILE}" VERSION)"
        newcommit="$(repo_file_value "${PATCHES_REPO}" "${_ref}" "${VERSION_FILE}" COMMIT)"
        [ -n "${newver}" ] || { echo "!! no VERSION in ${PATCHES_REPO}:${VERSION_FILE} at ${_ref}" >&2; exit 1; } ;;
    oci-tag)
        # latest IS the published tag; dashes are not legal in pkgver.
        newver="${latest//-/.}" ;;
    *)  echo "!! ${PKG}: unknown VERSION_FROM=${VERSION_FROM}" >&2; exit 1 ;;
esac

# pkgver has rules, and a bump that breaks them fails at makepkg parse time with
# a message that says nothing about where the value came from.
case "${newver}" in
    ""|*-*|*:*|*/*|*" "*) echo "!! ${PKG}: '${newver}' is not a valid pkgver" >&2; exit 1 ;;
esac
# The tracked ref moving does not always mean the packaged version moves: an
# armada commit can touch only patches, and a retagged upstream can transform to
# the same pkgver. Updating CURRENT is still right, but rebuilding for an
# identical version is not -- pkgrel exists for that and the caller decides.
oldver="$(grep -oE "^${VERSION_VAR}=.*" "${D}/PKGBUILD" | head -1 | cut -d= -f2-)"
oldrel="$(grep -oE '^pkgrel=.*' "${D}/PKGBUILD" | head -1 | cut -d= -f2-)"
echo "    ${VERSION_VAR}: ${oldver} -> ${newver}"
[ "${oldver}" = "${newver}" ] && echo "    (version unchanged; only the tracked ref moved)"
[ -n "${newcommit}" ] && echo "    _commit: -> ${newcommit:0:12}"

if [ -n "${DRY_RUN}" ]; then echo "    [dry-run] nothing written"; exit 0; fi

# ── edit ─────────────────────────────────────────────────────────────────────
sed -i -E "s|^${VERSION_VAR}=.*|${VERSION_VAR}=${newver}|" "${D}/PKGBUILD"
[ -n "${newcommit}" ] && sed -i -E "s|^_commit=.*|_commit=${newcommit}|" "${D}/PKGBUILD"
sed -i -E "s|^CURRENT=.*|CURRENT=${latest}|" "${D}/upstream.env"
# pkgrel is decided at the END, once the patch set and the checksums have been
# refreshed and it is possible to see whether anything the BUILD consumes moved.

# A package with an external patch set gets it refetched: a new artifact means
# the patches that went into it may have moved too.
if [ -n "${PATCHES_REPO}" ]; then
    ./scripts/fetch-patch-set.sh "${PKG}" >/dev/null
    echo "    refetched $(ls "${D}/patch-set"/*.patch 2>/dev/null | wc -l) patches"
fi

# ── checksums ────────────────────────────────────────────────────────────────
# Only when the PKGBUILD carries real ones. updpkgsums downloads every source to
# hash it, so running it on a SKIP-only package would be pure cost.
if grep -qE "^(sha256sums|sha512sums|b2sums|md5sums)=\(" "${D}/PKGBUILD" \
   && grep -E "^(sha256sums|sha512sums|b2sums|md5sums)=\(" "${D}/PKGBUILD" | grep -qvE "SKIP"; then
    echo "    refreshing checksums with updpkgsums"
    docker run --rm -v "${HERE}:/work" -w "/work/${D}" --user root "${IMAGE}" bash -c '
        pacman -Sy --noconfirm --needed pacman-contrib >/dev/null 2>&1
        useradd -m u 2>/dev/null || true; chown -R u /work
        su u -c "cd /work/'"${D}"' && updpkgsums"' 2>&1 | tail -3
    docker run --rm -v "${HERE}:/w" --user root alpine:3 chown -R "$(id -u):$(id -g)" /w/packages >/dev/null 2>&1
else
    echo "    checksums are SKIP or absent -- nothing to refresh"
fi

# ── pkgrel, and whether this is a rebuild at all ─────────────────────────────
# The published filename is <pkgname>-<pkgver>-<pkgrel>-<arch>.pkg.tar.zst, and
# publish-r2.sh will not overwrite one that already exists with different bytes
# -- packages are served with `Cache-Control: immutable`, so reusing a name
# leaves the CDN handing devices the OLD bytes against the NEW signature. Every
# rebuild therefore needs a name of its own, and pkgrel is what supplies it.
#
# Three cases, and the middle one is the one this exists for:
#
#   version moved          pkgrel=1        new pkgver already gives a new name
#   version same, build    pkgrel+1        umtp-responder and inputplumber track
#     inputs moved                         armada's BASE.env, where a commit can
#                                          move COMMIT or the patch set without
#                                          moving VERSION; gamescope's oci-tag
#                                          can map two tags onto one pkgver
#   version same, only     unchanged       nothing to rebuild. Exit 3 so the
#     CURRENT moved                        caller commits it WITHOUT building.
#
# It used to be an unconditional `pkgrel=1` here, which got both of the last two
# wrong: it rebuilt and republished an identical version under its existing
# filename, and -- worse -- a pkgrel that had been raised BY HAND to escape a
# poisoned name was silently reset back onto it.
#
# --untracked-files=all because fetch-patch-set.sh writes new .patch files, and
# a plain `git diff` cannot see those. upstream.env is excluded on purpose: it is
# the tracking record, and nothing in the build path reads it (build.sh excludes
# it from change detection for the same reason).
if [ "${oldver}" != "${newver}" ]; then
    sed -i -E "s|^pkgrel=.*|pkgrel=1|" "${D}/PKGBUILD"
    echo "    pkgrel: ${oldrel} -> 1  (version moved)"
else
    mapfile -t dirty < <(git status --porcelain --untracked-files=all -- "${D}" \
        | awk '{print $NF}' | grep -v "^${D}/upstream.env$" || true)
    if [ ${#dirty[@]} -eq 0 ]; then
        echo "==> ${PKG}: only the tracked ref moved (CURRENT=${latest}); nothing to rebuild"
        exit 3
    fi
    case "${oldrel}" in
        ''|*[!0-9]*) echo "!! ${PKG}: pkgrel '${oldrel}' is not an integer; bump it by hand" >&2; exit 1 ;;
    esac
    sed -i -E "s|^pkgrel=.*|pkgrel=$((oldrel + 1))|" "${D}/PKGBUILD"
    echo "    pkgrel: ${oldrel} -> $((oldrel + 1))  (same ${VERSION_VAR}, but $(printf '%s ' "${dirty[@]}")changed)"
fi

bash -n "${D}/PKGBUILD" || { echo "!! ${PKG}: PKGBUILD no longer parses after the bump" >&2; exit 1; }
echo "==> ${PKG} bumped to ${newver}"
