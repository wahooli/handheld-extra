#!/usr/bin/env bash
# shellcheck disable=SC2034
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

TRACK=; GITHUB_REPO=; GIT_URL=; OCI_IMAGE=; OCI_TAG_RE=; AUR_PKG=; CURRENT=; INCLUDE_PRERELEASE=
TRACK_PATHS=
PATCHES_REPO=; PATCHES_PATH=; PATCHES_REF='s/.*/&/'; VERSION_FILE=
SOURCE_REF_FROM=; SOURCE_REF_VAR=; SOURCE_COMMIT_VAR=; SOURCE_GIT=
TERRA_ENV_FILE=; TERRA_ENV_KEY=; TERRA_SPEC_REPO=; TERRA_SPEC_PATH=; TERRA_SPEC_KEYS=
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

newver=; newcommit=
case "${VERSION_FROM}" in
    upstream-tag)
        newver="$(printf '%s' "${latest}" | sed -E "${VERSION_SED}")" ;;
    commit-date)
        _cdate="$(github_commit_date "${GITHUB_REPO}" "${latest}")"
        [ -n "${_cdate}" ] || { echo "!! ${PKG}: could not read the commit date of ${latest}" >&2; exit 1; }
        newver="${_cdate}.${latest:0:8}" ;;
    repo-file)
        _ref="$(printf '%s' "${latest}" | sed -E "${PATCHES_REF}")"
        newver="$(repo_file_value "${PATCHES_REPO}" "${_ref}" "${VERSION_FILE}" VERSION)"
        newcommit="$(repo_file_value "${PATCHES_REPO}" "${_ref}" "${VERSION_FILE}" COMMIT)"
        [ -n "${newver}" ] || { echo "!! no VERSION in ${PATCHES_REPO}:${VERSION_FILE} at ${_ref}" >&2; exit 1; } ;;
    oci-tag)
        newver="${latest//-/.}" ;;
    *)  echo "!! ${PKG}: unknown VERSION_FROM=${VERSION_FROM}" >&2; exit 1 ;;
esac

case "${newver}" in
    ""|*-*|*:*|*/*|*" "*) echo "!! ${PKG}: '${newver}' is not a valid pkgver" >&2; exit 1 ;;
esac
oldver="$(grep -oE "^${VERSION_VAR}=.*" "${D}/PKGBUILD" | head -1 | cut -d= -f2-)"
oldrel="$(grep -oE '^pkgrel=.*' "${D}/PKGBUILD" | head -1 | cut -d= -f2-)"
echo "    ${VERSION_VAR}: ${oldver} -> ${newver}"
[ "${oldver}" = "${newver}" ] && echo "    (version unchanged; only the tracked ref moved)"
[ -n "${newcommit}" ] && echo "    _commit: -> ${newcommit:0:12}"

if [ -n "${DRY_RUN}" ]; then echo "    [dry-run] nothing written"; exit 0; fi

sed -i -E "s|^${VERSION_VAR}=.*|${VERSION_VAR}=${newver}|" "${D}/PKGBUILD"
[ -n "${newcommit}" ] && sed -i -E "s|^_commit=.*|_commit=${newcommit}|" "${D}/PKGBUILD"
sed -i -E "s|^CURRENT=.*|CURRENT=${latest}|" "${D}/upstream.env"

if [ -n "${PATCHES_REPO}" ]; then
    ./scripts/fetch-patch-set.sh "${PKG}" >/dev/null
    echo "    refetched $(ls "${D}/patch-set"/*.patch 2>/dev/null | wc -l) patches"
fi

if [ -n "${SOURCE_REF_FROM}" ]; then
    case "${SOURCE_REF_FROM}" in
        armada-terra-spec)
            _sref="$(armada_terra_source_ref "${PATCHES_REPO}" \
                "$(printf '%s' "${latest}" | sed -E "${PATCHES_REF}")" \
                "${TERRA_ENV_FILE}" "${TERRA_ENV_KEY}" \
                "${TERRA_SPEC_REPO}" "${TERRA_SPEC_PATH}" "${TERRA_SPEC_KEYS}")" || _sref=
            [ -n "${_sref}" ] || {
                echo "!! ${PKG}: could not resolve the source ref from ${PATCHES_REPO} at ${latest}" >&2
                echo "   refusing to continue -- an empty ref does not fail the build, it silently" >&2
                echo "   builds the default branch, which is the bug this resolution exists to fix." >&2
                exit 1; }
            _scommit="$(git_ref_commit "${SOURCE_GIT}" "${_sref}")" || _scommit=
            [ -n "${_scommit}" ] || { echo "!! ${PKG}: ${SOURCE_GIT} has no ref ${_sref}" >&2; exit 1; } ;;
        *) echo "!! ${PKG}: unknown SOURCE_REF_FROM=${SOURCE_REF_FROM}" >&2; exit 1 ;;
    esac
    _oldsref="$(pkgbuild_var "${D}/PKGBUILD" "${SOURCE_REF_VAR}")"
    sed -i -E "s|^${SOURCE_REF_VAR}=.*|${SOURCE_REF_VAR}=${_sref}|" "${D}/PKGBUILD"
    sed -i -E "s|^${SOURCE_COMMIT_VAR}=.*|${SOURCE_COMMIT_VAR}=${_scommit}|" "${D}/PKGBUILD"
    if [ "${_oldsref}" = "${_sref}" ]; then
        echo "    ${SOURCE_REF_VAR}: ${_sref} (unchanged)"
    else
        echo "    ${SOURCE_REF_VAR}: ${_oldsref} -> ${_sref}  (${_scommit:0:12})"
    fi
fi

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
