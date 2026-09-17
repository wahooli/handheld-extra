#!/usr/bin/env bash
# Bump one package's ABI pin to the version its dependency is now at in ALARM.
#
#   scripts/bump-abi-pin.sh hyprgrass
#   DRY_RUN=1 scripts/bump-abi-pin.sh hyprgrass     say what would change
#
# This is a SECOND axis, independent of bump-package.sh. That one asks "has this
# package released something new"; this one asks "has the package it is pinned to
# moved underneath it". hyprgrass is the case and the reason this exists:
#
#   depends=("hyprland=${_hyprver}")
#
# is an exact match, so ALARM publishing hyprland 0.56.2 makes the published
# hyprgrass uninstallable even though hyprgrass itself released nothing. On a
# device that is not a stale plugin, it is `pacman -Syu` refusing the WHOLE
# transaction -- nothing on the system upgrades at all:
#
#   error: failed to prepare transaction (could not satisfy dependencies)
#   :: installing hyprland (0.56.2-3) breaks dependency 'hyprland=0.56.1'
#      required by hyprgrass
#
# so this axis is the one that strands users, and it moves on ALARM's schedule
# rather than upstream's.
#
# ── why this is mechanical and the release axis is not ───────────────────────
# It was reported-only at first, on the grounds that moving _hyprver also means
# finding the hyprgrass commit built against the new Hyprland -- "a lookup, not
# an increment". The lookup is real, but it is not a judgement call: upstream
# publishes the answer as a table (hyprpm.toml commit_pins, Hyprland commit ->
# plugin commit) and hyprpm and the AUR package both just read it. Anything a
# human does here is reading the same row.
#
# What stays a judgement call is the OTHER axis -- taking a new hyprgrass release
# -- which is why that one keeps AUTOBUMP=no in the same upstream.env.
#
# ── what it refuses to do ────────────────────────────────────────────────────
# Exact row or nothing. Consecutive pins exist because an ABI changed between
# them, so the nearest row is the one guaranteed not to load. When ALARM is ahead
# of upstream's table -- the normal case for the first days after a Hyprland
# release -- this exits 4 and the poller reports it for a human. Building a
# plugin against an unpinned compositor would produce a package that installs
# cleanly, unblocks pacman, and silently fails to load: worse than the error it
# replaces, because nothing reports it.
#
# It does NOT commit or build; the caller decides that.
#
# Exit codes, because the caller has to tell these apart:
#
#   0   bumped -- build and publish it
#   1   failed
#   2   no ABI pin declared, or ABI_PIN_AUTOBUMP is not yes -- not for this script
#   3   already in sync; nothing to do
#   4   upstream has published no pairing for this version yet -- report, do not
#       guess. Not a fault, so the caller reports it rather than failing the run.
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

# ── find the source commit that targets the new dependency version ───────────
newcommit=
case "${ABI_PIN_COMMIT_FROM}" in
    hyprpm-toml)
        [ -n "${ABI_PIN_SRC_GIT}" ] && [ -n "${ABI_PIN_COMMIT_REPO}" ] || {
            echo "!! ${PKG}: hyprpm-toml needs ABI_PIN_SRC_GIT and ABI_PIN_COMMIT_REPO" >&2; exit 1; }
        # ALARM carries a pkgver; the pin table is keyed by the upstream COMMIT,
        # so the release tag is the bridge between them.
        #
        # Literal substitution rather than printf: the format comes from a config
        # file, and printf would read every OTHER % in it as a directive too. A
        # stray one is not a crash, it is a wrong tag that resolves to a real
        # commit somewhere else in history.
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
    # No resolver declared: the pin variable is the only thing that moves. Right
    # for a package whose source does not track its dependency commit-by-commit.
    '') ;;
    *)  echo "!! ${PKG}: unknown ABI_PIN_COMMIT_FROM=${ABI_PIN_COMMIT_FROM}" >&2; exit 1 ;;
esac

oldcommit="$(pkgbuild_var "${D}/PKGBUILD" "${ABI_PIN_COMMIT_VAR}")"
oldrel="$(pkgbuild_var "${D}/PKGBUILD" pkgrel)"
echo "    ${ABI_PIN_VAR}: ${pinned} -> ${avail}"
[ -n "${newcommit}" ] && echo "    ${ABI_PIN_COMMIT_VAR}: ${oldcommit:0:12} -> ${newcommit:0:12}"

if [ -n "${newcommit}" ] && [ "${newcommit}" = "${oldcommit}" ]; then
    # Upstream pins several Hyprland commits to one plugin commit, so a
    # compositor bump that changed no plugin-visible ABI lands here. The source
    # is identical; only the depends= string and the pkgver move. Still a real
    # rebuild -- the whole point is republishing a package pacman will accept.
    echo "    (same source commit; upstream pins both ${ABI_PIN_PKG} versions to it)"
fi

if [ -n "${DRY_RUN}" ]; then echo "    [dry-run] nothing written"; exit 0; fi

# ── edit ─────────────────────────────────────────────────────────────────────
sed -i -E "s|^${ABI_PIN_VAR}=.*|${ABI_PIN_VAR}=${avail}|" "${D}/PKGBUILD"
[ -n "${newcommit}" ] && sed -i -E "s|^${ABI_PIN_COMMIT_VAR}=.*|${ABI_PIN_COMMIT_VAR}=${newcommit}|" "${D}/PKGBUILD"

# ── pkgrel ───────────────────────────────────────────────────────────────────
# The published filename is <pkgname>-<pkgver>-<pkgrel>-<arch>.pkg.tar.zst and
# publish-r2.sh refuses to overwrite one that already exists with different bytes
# -- packages are served immutable, so reusing a name leaves the CDN handing
# devices the OLD bytes against the NEW signature. Every rebuild needs a name of
# its own; the question is only which field supplies it.
#
# A package can put the pin IN its version, as hyprgrass does:
#
#   pkgver="${_srcver}+hypr${_hyprver}"
#
# and then the pin bump has already produced a new filename, so pkgrel goes back
# to 1 -- the Arch convention, and it also drops any hand-raised pkgrel that only
# existed to escape a poisoned name under the OLD pkgver.
#
# Where pkgver does not reference the pin, the rebuild is invisible in the
# version and pkgrel is the only thing that can distinguish it. Asking the
# PKGBUILD which case it is beats assuming, because getting it wrong is silent:
# the build succeeds and publish just declines to ship it.
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
