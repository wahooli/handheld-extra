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
# Two axes, and a package can be reported on one while bumped on the other.
# Besides "has upstream released something", each package can declare an ABI PIN
# -- a dependency whose exact version it is compiled against. hyprgrass pins
# hyprland, and that axis IS auto-bumped (scripts/bump-abi-pin.sh), because
# upstream publishes the compatibility table the bump needs. The two get opposite
# answers on purpose: a stale release ships an old package, while a stale ABI pin
# means every device's `pacman -Syu` refuses its WHOLE transaction until someone
# reads an issue.
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

# One request per GitHub-tracked package -- but a TRACK=github-paths package
# costs one per WATCHED PATH, not one per package, plus one more to read a commit
# date when it versions from one.
#
# Counted rather than multiplied. A multiplier has to be wrong in one direction:
# too low and this misses the exhaustion it exists to catch, too high and it
# refuses runs that would have succeeded -- which an unauthenticated local run
# hits immediately, since 60/hour is the whole budget there. Adding the paths up
# costs one glob and is simply correct. The +4 is slack for the bump-time
# lookups, which only happen for packages that actually moved.
require_rate_limit "$((
    $(ls -d packages/*/ | wc -l)
    + $(sed -n 's/^TRACK_PATHS=//p' packages/*/upstream.env 2>/dev/null | tr -d '"' | wc -w)
    + 4 ))" || exit 1

BEHIND=(); ERRORS=(); BUMPED=(); TRACKED=(); ABIDRIFT=(); CHECKED=0

for conf in packages/*/upstream.env; do
    pkg="$(basename "$(dirname "${conf}")")"
    # Reset before sourcing so one package's values cannot leak into the next.
    # They look unused because upstream_latest() consumes them from the sourced
    # lib, which shellcheck cannot follow across the source boundary.
    TRACK=; GITHUB_REPO=; GIT_URL=; OCI_IMAGE=; OCI_TAG_RE=; AUR_PKG=; CURRENT=; INCLUDE_PRERELEASE=
    TRACK_PATHS=
    ABI_PIN_PKG=; ABI_PIN_REPO=; ABI_PIN_VAR=; ABI_PIN_AUTOBUMP=
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
    # Bumped with --bump, not merely reported. It was reported-only at first,
    # on the grounds that moving _hyprver means also finding the hyprgrass commit
    # that targets the new Hyprland -- "a lookup, not an increment". The lookup is
    # real; it is not judgement. Upstream publishes the pairing as a table
    # (hyprpm.toml commit_pins) that hyprpm and the AUR package both just read,
    # and bump-abi-pin.sh reads the same row. What it will NOT do is take a
    # neighbouring row when the exact one is missing -- that exits 4 and lands in
    # ABIDRIFT below, for a human.
    #
    # Reporting it was the wrong shape for this axis anyway: the release axis
    # going stale ships an old package, while this one going stale means every
    # device's `pacman -Syu` refuses its WHOLE transaction until someone reads
    # the issue. Nothing on the system upgrades in the meantime.
    if [ -n "${ABI_PIN_PKG}" ]; then
        pinned="$(pkgbuild_var "packages/${pkg}/PKGBUILD" "${ABI_PIN_VAR}")"
        if avail="$(alarm_pkg_version "${ABI_PIN_REPO:-extra}" "${ABI_PIN_PKG}")"; then
            if [ -n "${pinned}" ] && [ "${pinned}" != "${avail}" ]; then
                printf '  %-32s %-14s ABI: %s %s -> %s\n' \
                    "${pkg}" "pin" "${ABI_PIN_PKG}" "${pinned}" "${avail}"
                abirc=0
                if [ -n "${BUMP}" ] && [ "${ABI_PIN_AUTOBUMP:-no}" = yes ]; then
                    # rc captured on the command itself, not via `rc=$?` after an
                    # `if` -- a false condition with no else branch leaves $? at
                    # zero, which is how the exit-2 test in the release path below
                    # stayed dead until it was found.
                    ./scripts/bump-abi-pin.sh "${pkg}" >/tmp/abibump.$$ 2>&1 || abirc=$?
                    sed 's/^/      /' /tmp/abibump.$$; rm -f /tmp/abibump.$$
                fi
                case "${abirc}" in
                    # 0 with no bump attempted means report-only mode, or a package
                    # that has not opted in -- abirc is still at its initial 0
                    # because nothing ran. Only a bump that actually happened goes
                    # into BUMPED, which is what poll.yml commits and dispatches a
                    # build for; the package is then republished under the filename
                    # its new pkgver supplies and the device's upgrade unblocks.
                    0) if [ -n "${BUMP}" ] && [ "${ABI_PIN_AUTOBUMP:-no}" = yes ]; then
                           BUMPED+=("${pkg}")
                       elif [ -z "${BUMP}" ]; then
                           # Report-only run. The package may well be opted in --
                           # saying otherwise here would send someone to fix a
                           # declaration that is already correct.
                           ABIDRIFT+=("${pkg}|${ABI_PIN_PKG}|${pinned}|${avail}|${ABI_PIN_VAR}|reporting only; run with \`--bump\`")
                       else
                           ABIDRIFT+=("${pkg}|${ABI_PIN_PKG}|${pinned}|${avail}|${ABI_PIN_VAR}|not opted in to \`ABI_PIN_AUTOBUMP\`")
                       fi ;;
                    # 4: upstream has published no pairing for this version yet.
                    # A wait, not a fault -- reported with that reason attached so
                    # the issue does not read as a broken script.
                    4) ABIDRIFT+=("${pkg}|${ABI_PIN_PKG}|${pinned}|${avail}|${ABI_PIN_VAR}|no pairing published upstream yet") ;;
                    # 2: the package does not opt in. Also a decision, not a fault.
                    2) ABIDRIFT+=("${pkg}|${ABI_PIN_PKG}|${pinned}|${avail}|${ABI_PIN_VAR}|") ;;
                    *) ABIDRIFT+=("${pkg}|${ABI_PIN_PKG}|${pinned}|${avail}|${ABI_PIN_VAR}|the bump failed")
                       ERRORS+=("${pkg}: ABI pin bump failed") ;;
                esac
            fi
        else
            ERRORS+=("${pkg}: could not read ${ABI_PIN_REPO:-extra}/${ABI_PIN_PKG} from the ALARM sync db")
        fi
    fi

    latest="$(upstream_latest 2>/dev/null || true)"
    case "${TRACK}" in
        github-release) src="${GITHUB_REPO}" ;;
        github-paths)   src="${GITHUB_REPO} (${TRACK_PATHS})" ;;
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
            # commit that touched a watched path without moving VERSION, COMMIT
            # or the patch set the build consumes. The CURRENT edit is worth
            # committing so tomorrow's poll does not report it again, but
            # building it is not: it would rebuild the same
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
            # The commit itself, not a compare against CURRENT: a compare link is
            # more useful but 404s whenever CURRENT is not a sha in that repo,
            # which is every package that has not been through one bump since it
            # started being tracked this way.
            github-paths) BEHIND+=("${pkg}|${CURRENT}|${latest}|https://github.com/${GITHUB_REPO}/commit/${latest}") ;;
            github-release) BEHIND+=("${pkg}|${CURRENT}|${latest}|https://github.com/${GITHUB_REPO}/releases/tag/${latest}") ;;
            aur) BEHIND+=("${pkg}|${CURRENT}|${latest}|https://aur.archlinux.org/packages/${AUR_PKG}") ;;
            *) BEHIND+=("${pkg}|${CURRENT}|${latest}|${src}") ;;
        esac
    fi
done

# A package can move on BOTH axes in one run -- an ABI pin bump and a release
# bump -- and would then be named twice in the commit subject and dispatched to
# build.yml twice. The tree is already correct either way; this is about what the
# list says.
if [ ${#BUMPED[@]} -gt 0 ]; then
    mapfile -t BUMPED < <(printf '%s\n' "${BUMPED[@]}" | awk '!seen[$0]++')
fi

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
        echo "| package | pin variable | pinned to | built against | now in ALARM | why not bumped |"
        echo "|---|---|---|---|---|---|"
        for d in "${ABIDRIFT[@]}"; do
            IFS='|' read -r p dep was now var why <<< "${d}"
            echo "| \`${p}\` | \`${var}\` | \`${dep}\` | ${was} | **${now}** | ${why:-unknown} |"
        done
        echo
        echo "An ABI pin that drifts is the one failure here that stops a device"
        echo "upgrading AT ALL: the package still builds, but it pins an exact version"
        echo "its dependency has moved past, so \`pacman -Syu\` refuses the WHOLE"
        echo "transaction until it is rebuilt and republished."
        echo
        for d in "${ABIDRIFT[@]}"; do
            IFS='|' read -r p dep was now var why <<< "${d}"
            echo '```'
            echo "error: failed to prepare transaction (could not satisfy dependencies)"
            echo ":: installing ${dep} (${now}) breaks dependency '${dep}=${was}' required by ${p}"
            echo '```'
            echo
        done
        echo "These are the ones that could NOT be bumped automatically -- a drifted"
        echo "pin that CAN be is bumped and built without appearing here."
        echo
        echo "\"No pairing published upstream yet\" is a wait, not a break: the fix is"
        echo "upstream adding the row, and the next poll takes it. Everything else"
        echo "means editing the pin variable AND the matching \`_commit\` by hand, from"
        echo "upstream's compatibility table (\`hyprpm.toml\` for hyprgrass), then"
        echo "building and publishing. \`scripts/bump-abi-pin.sh <pkg>\` does exactly"
        echo "that where the table has the row."
    fi
    if [ ${#ERRORS[@]} -gt 0 ]; then
        echo
        echo "#### Could not be checked"
        echo
        printf -- '- %s\n' "${ERRORS[@]}"
    fi
} > .upstream-report.md

[ ${#ERRORS[@]} -eq 0 ]
