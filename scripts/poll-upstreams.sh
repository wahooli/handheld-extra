#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

# shellcheck source=/dev/null
source scripts/lib-upstream.sh

BUMP=
[ "${1:-}" = "--bump" ] && BUMP=1

require_rate_limit "$((
    $(ls -d packages/*/ | wc -l)
    + $(sed -n 's/^TRACK_PATHS=//p' packages/*/upstream.env 2>/dev/null | tr -d '"' | wc -w)
    + 4 ))" || exit 1

BEHIND=(); ERRORS=(); BUMPED=(); TRACKED=(); ABIDRIFT=(); CHECKED=0

for conf in packages/*/upstream.env; do
    pkg="$(basename "$(dirname "${conf}")")"
    TRACK=; GITHUB_REPO=; GIT_URL=; OCI_IMAGE=; OCI_TAG_RE=; AUR_PKG=; CURRENT=; INCLUDE_PRERELEASE=
    TRACK_PATHS=
    ABI_PIN_PKG=; ABI_PIN_REPO=; ABI_PIN_VAR=; ABI_PIN_AUTOBUMP=
    # shellcheck source=/dev/null
    source "${conf}"
    [ "${TRACK}" = none ] && continue
    CHECKED=$((CHECKED + 1))

    if [ -n "${ABI_PIN_PKG}" ]; then
        pinned="$(pkgbuild_var "packages/${pkg}/PKGBUILD" "${ABI_PIN_VAR}")"
        if avail="$(alarm_pkg_version "${ABI_PIN_REPO:-extra}" "${ABI_PIN_PKG}")"; then
            if [ -n "${pinned}" ] && [ "${pinned}" != "${avail}" ]; then
                printf '  %-32s %-14s ABI: %s %s -> %s\n' \
                    "${pkg}" "pin" "${ABI_PIN_PKG}" "${pinned}" "${avail}"
                abirc=0
                if [ -n "${BUMP}" ] && [ "${ABI_PIN_AUTOBUMP:-no}" = yes ]; then
                    ./scripts/bump-abi-pin.sh "${pkg}" >/tmp/abibump.$$ 2>&1 || abirc=$?
                    sed 's/^/      /' /tmp/abibump.$$; rm -f /tmp/abibump.$$
                fi
                case "${abirc}" in
                    0) if [ -n "${BUMP}" ] && [ "${ABI_PIN_AUTOBUMP:-no}" = yes ]; then
                           BUMPED+=("${pkg}")
                       elif [ -z "${BUMP}" ]; then
                           ABIDRIFT+=("${pkg}|${ABI_PIN_PKG}|${pinned}|${avail}|${ABI_PIN_VAR}|reporting only; run with \`--bump\`")
                       else
                           ABIDRIFT+=("${pkg}|${ABI_PIN_PKG}|${pinned}|${avail}|${ABI_PIN_VAR}|not opted in to \`ABI_PIN_AUTOBUMP\`")
                       fi ;;
                    4) ABIDRIFT+=("${pkg}|${ABI_PIN_PKG}|${pinned}|${avail}|${ABI_PIN_VAR}|no pairing published upstream yet") ;;
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

    show() { case "$1" in [0-9a-f]|[0-9a-f][0-9a-f]*) [ "${#1}" -eq 40 ] && printf '%s' "${1:0:12}" || printf '%s' "$1" ;; *) printf '%s' "$1" ;; esac; }

    if [ "${have}" = "${want}" ]; then
        printf '  %-32s %-14s up to date\n' "${pkg}" "$(show "${CURRENT}")"
    else
        printf '  %-32s %-14s -> %s\n' "${pkg}" "$(show "${CURRENT}")" "$(show "${latest}")"

        if [ -n "${BUMP}" ]; then
            rc=0
            ./scripts/bump-package.sh "${pkg}" >/tmp/bump.$$ 2>&1 || rc=$?
            if [ "${rc}" = 0 ]; then
                sed 's/^/      /' /tmp/bump.$$
                BUMPED+=("${pkg}")
                rm -f /tmp/bump.$$
                continue
            fi
            if [ "${rc}" = 3 ]; then
                sed 's/^/      /' /tmp/bump.$$
                TRACKED+=("${pkg}")
                rm -f /tmp/bump.$$
                continue
            fi
            sed 's/^/      /' /tmp/bump.$$; rm -f /tmp/bump.$$
            [ "${rc}" = 2 ] || ERRORS+=("${pkg}: bump failed")
        fi
        case "${TRACK}" in
            oci) BEHIND+=("${pkg}|${CURRENT:-none}|${latest}|https://${OCI_IMAGE%%/*}/${OCI_IMAGE#*/}") ;;
            github-paths) BEHIND+=("${pkg}|${CURRENT}|${latest}|https://github.com/${GITHUB_REPO}/commit/${latest}") ;;
            github-release) BEHIND+=("${pkg}|${CURRENT}|${latest}|https://github.com/${GITHUB_REPO}/releases/tag/${latest}") ;;
            aur) BEHIND+=("${pkg}|${CURRENT}|${latest}|https://aur.archlinux.org/packages/${AUR_PKG}") ;;
            *) BEHIND+=("${pkg}|${CURRENT}|${latest}|${src}") ;;
        esac
    fi
done

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
