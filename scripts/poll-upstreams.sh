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
# gtk2 sets it for a different reason: what it tracks is Arch's PACKAGING, so a
# move means "somebody added a patch", and the bump is copying that patch in --
# not rewriting a version.
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

BEHIND=(); ERRORS=(); BUMPED=(); TRACKED=(); ABIDRIFT=(); CHECKED=0

for conf in packages/*/upstream.env; do
    pkg="$(basename "$(dirname "${conf}")")"
    # Reset before sourcing so one package's values cannot leak into the next.
    # They look unused because upstream_latest() consumes them from the sourced
    # lib, which shellcheck cannot follow across the source boundary.
    TRACK=; GITHUB_REPO=; GIT_URL=; OCI_IMAGE=; OCI_TAG_RE=; AUR_PKG=; CURRENT=; INCLUDE_PRERELEASE=
    ABI_PIN_PKG=; ABI_PIN_REPO=; ABI_PIN_VAR=
    # shellcheck source=/dev/null
    source "${conf}"
    [ "${TRACK}" = none ] && continue
    CHECKED=$((CHECKED + 1))

    # A second, independent axis: some packages are pinned to ANOTHER package's
    # version rather than only their own upstream. hyprgrass is the case --
    # depends=('hyprland=<ver>') is an exact match, so ALARM moving hyprland
    # makes the published package uninstallable even though hyprgrass itself has
    # released nothing.
    #
    # Checked FIRST, and outside everything below, because every other path in
    # this loop can `continue` past it -- and a package being up to date on its
    # own axis is exactly when this is the only thing left to catch.
    #
    # It is reported, never auto-bumped: moving _hyprver means also finding the
    # hyprgrass commit that targets the new Hyprland, from upstream's hyprpm.toml
    # compatibility table. That is a lookup, not an increment.
    if [ -n "${ABI_PIN_PKG}" ]; then
        pinned="$(pkgbuild_var "packages/${pkg}/PKGBUILD" "${ABI_PIN_VAR}")"
        if avail="$(alarm_pkg_version "${ABI_PIN_REPO:-extra}" "${ABI_PIN_PKG}")"; then
            if [ -n "${pinned}" ] && [ "${pinned}" != "${avail}" ]; then
                printf '  %-32s %-14s ABI: %s %s -> %s\n' \
                    "${pkg}" "pin" "${ABI_PIN_PKG}" "${pinned}" "${avail}"
                ABIDRIFT+=("${pkg}|${ABI_PIN_PKG}|${pinned}|${avail}|${ABI_PIN_VAR}")
            fi
        else
            ERRORS+=("${pkg}: could not read ${ABI_PIN_REPO:-extra}/${ABI_PIN_PKG} from the ALARM sync db")
        fi
    fi

    latest="$(upstream_latest 2>/dev/null || true)"
    case "${TRACK}" in
        github-release) src="${GITHUB_REPO}" ;;
        git-tag)        src="${GIT_URL}" ;;
        oci)            src="${OCI_IMAGE}" ;;
        aur)            src="aur/${AUR_PKG}" ;;
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
            # Captured on the command itself, NOT with `rc=$?` after an `if`: a
            # false `if` condition with no else branch leaves $? at ZERO, so the
            # exit-2 test below could never fire and every AUTOBUMP=no package
            # was reported as a failure. Latent until now -- hyprgrass has not
            # moved since it was written -- and gtk2 would have hit it on the
            # first Arch pkgrel bump, which is exactly the case it exists for.
            rc=0
            ./scripts/bump-package.sh "${pkg}" >/tmp/bump.$$ 2>&1 || rc=$?
            if [ "${rc}" = 0 ]; then
                sed 's/^/      /' /tmp/bump.$$
                BUMPED+=("${pkg}")
                rm -f /tmp/bump.$$
                continue                      # bumped: not "behind" any more
            fi
            # Exit 3: the tracked ref moved but the package did not -- an armada
            # commit that touched neither VERSION, COMMIT nor the patch set. The
            # CURRENT edit is worth committing so tomorrow's poll does not report
            # it again, but building it is not: it would rebuild the same
            # pkgver-pkgrel into non-identical bytes and publish-r2.sh would
            # refuse to overwrite the name that is already live. Kept out of
            # bumped_list, which is what poll.yml dispatches a build for.
            if [ "${rc}" = 3 ]; then
                sed 's/^/      /' /tmp/bump.$$
                TRACKED+=("${pkg}")
                rm -f /tmp/bump.$$
                continue
            fi
            sed 's/^/      /' /tmp/bump.$$; rm -f /tmp/bump.$$
            # Exit 2 means the package declares AUTOBUMP=no. That is a decision,
            # not a fault, so it is reported rather than raised as an error.
            [ "${rc}" = 2 ] || ERRORS+=("${pkg}: bump failed")
        fi
        case "${TRACK}" in
            oci) BEHIND+=("${pkg}|${CURRENT:-none}|${latest}|https://${OCI_IMAGE%%/*}/${OCI_IMAGE#*/}") ;;
            github-release) BEHIND+=("${pkg}|${CURRENT}|${latest}|https://github.com/${GITHUB_REPO}/releases/tag/${latest}") ;;
            aur) BEHIND+=("${pkg}|${CURRENT}|${latest}|https://aur.archlinux.org/packages/${AUR_PKG}") ;;
            *) BEHIND+=("${pkg}|${CURRENT}|${latest}|${src}") ;;
        esac
    fi
done

echo
echo "checked ${CHECKED} package(s); ${#BUMPED[@]} bumped, ${#TRACKED[@]} tracking-only, ${#BEHIND[@]} behind, ${#ABIDRIFT[@]} ABI-pin drift, ${#ERRORS[@]} error(s)"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "behind=${#BEHIND[@]}"
        echo "errors=${#ERRORS[@]}"
        echo "bumped=${#BUMPED[@]}"
        echo "bumped_list=${BUMPED[*]-}"
        echo "tracked=${#TRACKED[@]}"
        echo "tracked_list=${TRACKED[*]-}"
        echo "abidrift=${#ABIDRIFT[@]}"
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
    if [ -n "${BUMP}" ] && [ ${#TRACKED[@]} -gt 0 ]; then
        echo "#### Tracking updated, not rebuilt"
        echo
        printf -- '- `%s`\n' "${TRACKED[@]}"
        echo
        echo "The tracked ref moved without moving anything the package builds from,"
        echo "so only \`CURRENT\` changed. Rebuilding would republish the same"
        echo "\`pkgver-pkgrel\` under a filename that is already live and served"
        echo "immutable, which is how a device ends up with the old bytes and the new"
        echo "signature."
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
    if [ ${#ABIDRIFT[@]} -gt 0 ]; then
        echo
        echo "#### ABI pin drift"
        echo
        echo "| package | pin variable | pinned to | built against | now in ALARM |"
        echo "|---|---|---|---|---|"
        for d in "${ABIDRIFT[@]}"; do
            IFS='|' read -r p dep was now var <<< "${d}"
            echo "| \`${p}\` | \`${var}\` | \`${dep}\` | ${was} | **${now}** |"
        done
        echo
        echo "These still build. The problem is on the device: each pins an exact"
        echo "version its dependency has moved past, so \`pacman -Syu\` refuses the"
        echo "WHOLE transaction -- nothing upgrades at all until the package is"
        echo "rebuilt and republished."
        echo
        for d in "${ABIDRIFT[@]}"; do
            IFS='|' read -r p dep was now var <<< "${d}"
            echo '```'
            echo "error: failed to prepare transaction (could not satisfy dependencies)"
            echo ":: installing ${dep} (${now}) breaks dependency '${dep}=${was}' required by ${p}"
            echo '```'
            echo
        done
        echo "Fixing one is a lookup, not an increment: bump the pin variable AND the"
        echo "matching \`_commit\`, which upstream pairs in its compatibility table"
        echo "(\`hyprpm.toml\` for hyprgrass). Then build and publish."
    fi
    if [ ${#ERRORS[@]} -gt 0 ]; then
        echo
        echo "#### Could not be checked"
        echo
        printf -- '- %s\n' "${ERRORS[@]}"
    fi
} > .upstream-report.md

[ ${#ERRORS[@]} -eq 0 ]
