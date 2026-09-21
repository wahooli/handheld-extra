#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"
# shellcheck source=/dev/null
source scripts/lib-upstream.sh

PKG="${1:?usage: bump-abi-pin.sh <package>}"
D="packages/${PKG}"
[ -f "${D}/upstream.env" ] || { echo "!! no ${D}/upstream.env" >&2; exit 1; }
DRY_RUN="${DRY_RUN:-}"

ABI_PIN_PKG=; ABI_PIN_REPO=; ABI_PIN_VAR=; ABI_PIN_AUTOBUMP=no
ABI_PIN_COMMIT_VAR=_commit; ABI_PIN_COMMIT_FROM=; ABI_PIN_COMMIT_REPO=
ABI_PIN_SRC_GIT=; ABI_PIN_SRC_TAG_FMT='v%s'
# shellcheck source=/dev/null
source "${D}/upstream.env"

[ -n "${ABI_PIN_PKG}" ] || { echo "==> ${PKG}: no ABI pin declared"; exit 2; }
[ "${ABI_PIN_AUTOBUMP}" = yes ] || {
    echo "!! ${PKG}: ABI_PIN_AUTOBUMP is not yes -- this one needs a human. See its upstream.env." >&2
    exit 2
}

pinned="$(pkgbuild_var "${D}/PKGBUILD" "${ABI_PIN_VAR}")"
[ -n "${pinned}" ] || { echo "!! ${PKG}: no ${ABI_PIN_VAR}= in its PKGBUILD" >&2; exit 1; }

avail="$(alarm_pkg_version "${ABI_PIN_REPO:-extra}" "${ABI_PIN_PKG}")" || {
    echo "!! ${PKG}: could not read ${ABI_PIN_REPO:-extra}/${ABI_PIN_PKG} from the ALARM sync db" >&2
    exit 1
}

if [ "${pinned}" = "${avail}" ]; then
    echo "==> ${PKG}: ${ABI_PIN_VAR} already at ${avail}"
    exit 3
fi
echo "==> ${PKG}: ${ABI_PIN_PKG} ${pinned} -> ${avail} in ${ABI_PIN_REPO:-extra}"

newcommit=
case "${ABI_PIN_COMMIT_FROM}" in
    hyprpm-toml)
        [ -n "${ABI_PIN_SRC_GIT}" ] && [ -n "${ABI_PIN_COMMIT_REPO}" ] || {
            echo "!! ${PKG}: hyprpm-toml needs ABI_PIN_SRC_GIT and ABI_PIN_COMMIT_REPO" >&2; exit 1; }
        case "${ABI_PIN_SRC_TAG_FMT}" in
            *%s*) ;;
            *) echo "!! ${PKG}: ABI_PIN_SRC_TAG_FMT='${ABI_PIN_SRC_TAG_FMT}' has no %s, so every version maps to one tag" >&2; exit 1 ;;
        esac
        _tag="${ABI_PIN_SRC_TAG_FMT/'%s'/${avail}}"
        depcommit="$(git_tag_commit "${ABI_PIN_SRC_GIT}" "${_tag}")" || true
        [ -n "${depcommit}" ] || {
            echo "!! ${PKG}: ${ABI_PIN_SRC_GIT} has no tag ${_tag} for ${ABI_PIN_PKG} ${avail}" >&2; exit 1; }
        echo "    ${ABI_PIN_PKG} ${_tag} is ${depcommit:0:12}"
        newcommit="$(hyprpm_paired_commit "${ABI_PIN_COMMIT_REPO}" "${depcommit}")" || true
        if [ -z "${newcommit}" ]; then
            echo "==> ${PKG}: ${ABI_PIN_COMMIT_REPO} has not pinned ${ABI_PIN_PKG} ${avail} (${depcommit:0:12}) yet"
            echo "    refusing to guess a commit -- the neighbouring pin is the one that will not load"
            exit 4
        fi
        ;;
    '') ;;
    *)  echo "!! ${PKG}: unknown ABI_PIN_COMMIT_FROM=${ABI_PIN_COMMIT_FROM}" >&2; exit 1 ;;
esac

oldcommit="$(pkgbuild_var "${D}/PKGBUILD" "${ABI_PIN_COMMIT_VAR}")"
oldrel="$(pkgbuild_var "${D}/PKGBUILD" pkgrel)"
echo "    ${ABI_PIN_VAR}: ${pinned} -> ${avail}"
[ -n "${newcommit}" ] && echo "    ${ABI_PIN_COMMIT_VAR}: ${oldcommit:0:12} -> ${newcommit:0:12}"

if [ -n "${newcommit}" ] && [ "${newcommit}" = "${oldcommit}" ]; then
    echo "    (same source commit; upstream pins both ${ABI_PIN_PKG} versions to it)"
fi

if [ -n "${DRY_RUN}" ]; then echo "    [dry-run] nothing written"; exit 0; fi

sed -i -E "s|^${ABI_PIN_VAR}=.*|${ABI_PIN_VAR}=${avail}|" "${D}/PKGBUILD"
[ -n "${newcommit}" ] && sed -i -E "s|^${ABI_PIN_COMMIT_VAR}=.*|${ABI_PIN_COMMIT_VAR}=${newcommit}|" "${D}/PKGBUILD"

if grep -qE "^pkgver=.*\\\$\{?${ABI_PIN_VAR}\}?" "${D}/PKGBUILD"; then
    sed -i -E "s|^pkgrel=.*|pkgrel=1|" "${D}/PKGBUILD"
    echo "    pkgrel: ${oldrel} -> 1  (pkgver carries ${ABI_PIN_VAR}, so it moved too)"
else
    case "${oldrel}" in
        ''|*[!0-9]*) echo "!! ${PKG}: pkgrel '${oldrel}' is not an integer; bump it by hand" >&2; exit 1 ;;
    esac
    sed -i -E "s|^pkgrel=.*|pkgrel=$((oldrel + 1))|" "${D}/PKGBUILD"
    echo "    pkgrel: ${oldrel} -> $((oldrel + 1))  (pkgver does not carry ${ABI_PIN_VAR})"
fi

bash -n "${D}/PKGBUILD" || { echo "!! ${PKG}: PKGBUILD no longer parses after the bump" >&2; exit 1; }
echo "==> ${PKG} pinned to ${ABI_PIN_PKG} ${avail}"
