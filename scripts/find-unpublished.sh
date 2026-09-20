#!/usr/bin/env bash
# Packages whose packaged version is NOT what the live repo serves.
#
#   scripts/find-unpublished.sh            names, one per line
#   scripts/find-unpublished.sh --table    a markdown table for an issue body
#
# Why this exists
# ---------------
# Everything else here reasons about what SHOULD happen: the poller compares
# upstreams, the bumper edits versions, the build workflow builds what changed.
# Nothing compared that against what devices actually receive, and the gap is not
# theoretical -- both of these were true at once, silently, for days:
#
#   gamescope   git said 20260913.24d88394, R2 served 20260906.53607bc5
#   hyprgrass   git said 0.8.2+hypr0.56.2,  R2 served 0.8.2+hypr0.56.1
#
# Each had a different cause -- one build raced onto the wrong commit, the other
# was never dispatched -- and neither would ever have been retried, because the
# poller's question is "is CURRENT behind upstream", and by then it was not. The
# bump had landed. Only the BUILD was missing, and nothing was asking about
# builds.
#
# So this asks the one question that does not care why: does the repo serve what
# this tree says it should? Anything that answers no gets rebuilt, whatever went
# wrong. A failure mode nobody has thought of yet still heals.
#
# It is deliberately not clever. It does not know about races, retries or
# failures; it compares two strings per package.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"
# shellcheck source=/dev/null
source ./repo.env

TABLE=
[ "${1:-}" = "--table" ] && TABLE=1

[ -n "${REPO_URL:-}" ] || { echo "!! repo.env has no REPO_URL" >&2; exit 1; }

DB="$(mktemp)"; trap 'rm -f "${DB}"' EXIT
# Fails CLOSED. An unreachable repo must not read as "everything is unpublished"
# and dispatch a rebuild of every package.
curl -fsSL --retry 3 --max-time 120 \
    "${REPO_URL}/${ARCH_DIR}/${REPO_NAME}.db" -o "${DB}" \
    || { echo "!! could not fetch ${REPO_URL}/${ARCH_DIR}/${REPO_NAME}.db" >&2; exit 1; }

# Sourced rather than grepped, because a pkgver can be composed from other
# variables -- hyprgrass builds its from _srcver and _hyprver, so the literal
# line says nothing useful. These are our own PKGBUILDs; they assign variables
# and define functions at the top level, and sourcing does not run the functions.
# Same approach as the rename check in check.yml.
pkg_fields() {
    ( set +eu
      pkgname=; pkgver=; pkgrel=
      . "$1" >/dev/null 2>&1 || true
      # pkgname may be an array; the first entry is the one that carries the
      # package's own name.
      set -- ${pkgname[0]:-}
      printf '%s %s-%s' "${1:-}" "${pkgver}" "${pkgrel}" )
}

# Entries in the db are <name>-<pkgver>-<pkgrel>/. Requiring a DIGIT after the
# name is what stops `networkmanager` also matching `networkmanager-docs`.
published_version() {
    local name="$1" entry
    entry="$(tar tzf "${DB}" 2>/dev/null | grep -oE "^${name}-[0-9][^/]*" | sort -u | head -1)" || true
    [ -n "${entry}" ] || return 1
    printf '%s' "${entry#"${name}-"}"
}

# Asked of git, not of the filesystem. A glob over packages/*/ also picks up
# directories that are gitignored -- packages/gtk2/ is, deliberately -- and those
# are not part of this repo: they exist in one working tree, never in a CI
# checkout, and nothing publishes them. Globbing reported gtk2 as "not
# published", which is true and meaningless, and would have queued a build for a
# package the build never sees.
mapfile -t PKGBUILDS < <(git ls-files 'packages/*/PKGBUILD')
[ ${#PKGBUILDS[@]} -gt 0 ] || { echo "!! no tracked packages/*/PKGBUILD found" >&2; exit 1; }

STALE=()
for f in "${PKGBUILDS[@]}"; do
    d="$(dirname "${f}")/"
    read -r name want <<< "$(pkg_fields "${f}")"
    [ -n "${name}" ] && [ "${want}" != "-" ] || {
        echo "!! $(basename "${d}"): could not read pkgname/pkgver from its PKGBUILD" >&2
        continue; }
    if have="$(published_version "${name}")"; then
        [ "${have}" = "${want}" ] && continue
    else
        have="(not published)"
    fi
    STALE+=("$(basename "${d}")|${name}|${have}|${want}")
done

if [ -n "${TABLE}" ]; then
    [ ${#STALE[@]} -gt 0 ] || exit 0
    echo "| package | serving now | should be |"
    echo "|---|---|---|"
    for s in "${STALE[@]}"; do
        IFS='|' read -r _dir name have want <<< "${s}"
        echo "| \`${name}\` | ${have} | **${want}** |"
    done
else
    for s in "${STALE[@]}"; do printf '%s\n' "${s%%|*}"; done
fi
