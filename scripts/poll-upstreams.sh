#!/usr/bin/env bash
# shellcheck disable=SC2034  # GITHUB_REPO/GIT_URL/OCI_IMAGE/OCI_TAG_RE and friends are
# read by upstream_latest() in scripts/lib-upstream.sh; shellcheck cannot follow a
# source boundary, so every variable this file only hands to the lib looks unused.
#
# Check every package against its upstream and report what is behind.
#
# Two modes:
#
#   (default)  report what is behind
#   --bump     bump each one via scripts/bump-package.sh, leaving the tree ready
#              to commit and build
#
# --bump is what CI runs. A package that cannot be bumped safely says so and is
# reported instead: hyprgrass sets AUTOBUMP=no because its pkgver is composed
# with a pinned Hyprland version, and taking a new release without checking
# which Hyprland the image ships builds a plugin for the wrong ABI.
#
# Nothing here validates that the bumped package still BUILDS -- that is the
# build workflow's job, and it already opens an issue when it fails.
#
# Each package declares how it is tracked in packages/<name>/upstream.env.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

# shellcheck source=/dev/null
source scripts/lib-upstream.sh

# --bump edits the tree; without it this only reports.
BUMP=
[ "${1:-}" = "--bump" ] && BUMP=1

# One request per GitHub-tracked package, plus a few for armada lookups.
require_rate_limit "$(( $(ls -d packages/*/ | wc -l) * 2 ))" || exit 1

BEHIND=(); ERRORS=(); BUMPED=(); CHECKED=0

for conf in packages/*/upstream.env; do
    pkg="$(basename "$(dirname "${conf}")")"
    # Reset before sourcing so one package's values cannot leak into the next.
    # They look unused because upstream_latest() consumes them from the sourced
    # lib, which shellcheck cannot follow across the source boundary.
    TRACK=; GITHUB_REPO=; GIT_URL=; OCI_IMAGE=; OCI_TAG_RE=; CURRENT=; INCLUDE_PRERELEASE=
    # shellcheck source=/dev/null
    source "${conf}"
    [ "${TRACK}" = none ] && continue
    CHECKED=$((CHECKED + 1))

    latest="$(upstream_latest 2>/dev/null || true)"
    case "${TRACK}" in
        github-release) src="${GITHUB_REPO}" ;;
        git-tag)        src="${GIT_URL}" ;;
        oci)            src="${OCI_IMAGE}" ;;
        *) ERRORS+=("${pkg}: unknown TRACK=${TRACK}"); continue ;;
    esac

    if [ -z "${latest}" ]; then
        ERRORS+=("${pkg}: could not read a version from ${src}")
        printf '  %-32s %-14s ERROR\n' "${pkg}" "${CURRENT:-?}"
        continue
    fi

    have="$(printf '%s' "${CURRENT}" | normalise)"
    want="$(printf '%s' "${latest}"  | normalise)"

    # Commit SHAs are compared in full and displayed short. A 40-character
    # column makes the table unreadable, and truncating before the comparison
    # would be a way to miss a real change.
    show() { case "$1" in [0-9a-f]|[0-9a-f][0-9a-f]*) [ "${#1}" -eq 40 ] && printf '%s' "${1:0:12}" || printf '%s' "$1" ;; *) printf '%s' "$1" ;; esac; }

    if [ "${have}" = "${want}" ]; then
        printf '  %-32s %-14s up to date\n' "${pkg}" "$(show "${CURRENT}")"
    else
        printf '  %-32s %-14s -> %s\n' "${pkg}" "$(show "${CURRENT}")" "$(show "${latest}")"

        if [ -n "${BUMP}" ]; then
            if ./scripts/bump-package.sh "${pkg}" >/tmp/bump.$$ 2>&1; then
                sed 's/^/      /' /tmp/bump.$$
                BUMPED+=("${pkg}")
                rm -f /tmp/bump.$$
                continue                      # bumped: not "behind" any more
            fi
            rc=$?
            sed 's/^/      /' /tmp/bump.$$; rm -f /tmp/bump.$$
            # Exit 2 means the package declares AUTOBUMP=no. That is a decision,
            # not a fault, so it is reported rather than raised as an error.
            [ "${rc}" = 2 ] || ERRORS+=("${pkg}: bump failed")
        fi
        case "${TRACK}" in
            oci) BEHIND+=("${pkg}|${CURRENT:-none}|${latest}|https://${OCI_IMAGE%%/*}/${OCI_IMAGE#*/}") ;;
            github-release) BEHIND+=("${pkg}|${CURRENT}|${latest}|https://github.com/${GITHUB_REPO}/releases/tag/${latest}") ;;
            *) BEHIND+=("${pkg}|${CURRENT}|${latest}|${src}") ;;
        esac
    fi
done

echo
echo "checked ${CHECKED} package(s); ${#BUMPED[@]} bumped, ${#BEHIND[@]} behind, ${#ERRORS[@]} error(s)"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "behind=${#BEHIND[@]}"
        echo "errors=${#ERRORS[@]}"
        echo "bumped=${#BUMPED[@]}"
        echo "bumped_list=${BUMPED[*]-}"
    } >> "${GITHUB_OUTPUT}"
fi

# A report file rather than stdout parsing, so the workflow can drop it straight
# into an issue body and a job summary without reformatting.
{
    if [ -n "${BUMP}" ] && [ ${#BUMPED[@]} -gt 0 ]; then
        echo "#### Bumped and building"
        echo
        printf -- '- `%s`\n' "${BUMPED[@]}"
        echo
    fi
    if [ ${#BEHIND[@]} -gt 0 ]; then
        echo "| package | packaged | upstream | |"
        echo "|---|---|---|---|"
        for b in "${BEHIND[@]}"; do
            IFS='|' read -r p c l u <<< "${b}"
            echo "| \`${p}\` | $(show "${c}") | **$(show "${l}")** | [changes](${u}) |"
        done
        echo
        echo "These were NOT bumped automatically. Either the package sets"
        echo "\`AUTOBUMP=no\` because its version needs judgement, or the bump failed."
        echo "Bumping by hand means editing its version variable, refreshing checksums"
        echo "if it has real ones, and updating \`CURRENT\` in its \`upstream.env\` --"
        echo "\`scripts/bump-package.sh <pkg>\` does all three where it can."
    fi
    if [ ${#ERRORS[@]} -gt 0 ]; then
        echo
        echo "#### Could not be checked"
        echo
        printf -- '- %s\n' "${ERRORS[@]}"
    fi
} > .upstream-report.md

[ ${#ERRORS[@]} -eq 0 ]
