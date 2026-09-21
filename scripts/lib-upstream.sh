#!/usr/bin/env bash
API="https://api.github.com"

require_rate_limit() {
    local need="${1:-10}" remaining reset
    local json
    json="$(gh_get "${API}/rate_limit" 2>/dev/null)" || return 0
    remaining="$(printf '%s' "${json}" | jq -r '.resources.core.remaining // empty' 2>/dev/null)"
    reset="$(printf '%s' "${json}" | jq -r '.resources.core.reset // empty' 2>/dev/null)"
    [ -n "${remaining}" ] || return 0
    if [ "${remaining}" -lt "${need}" ]; then
        local mins="?"
        [ -n "${reset}" ] && mins="$(( (reset - $(date +%s) + 59) / 60 ))"
        echo "!! GitHub API rate limit is ${remaining}, need ~${need}; resets in ${mins}m" >&2
        [ -n "${GH_TOKEN:-}" ] || echo "   (no GH_TOKEN set -- unauthenticated is only 60/hour)" >&2
        return 1
    fi
    return 0
}

gh_get() {
    if [ -n "${GH_TOKEN:-}" ]; then
        curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json" "$1"
    else
        curl -fsSL -H "Accept: application/vnd.github+json" "$1"
    fi
}

normalise() { sed -E 's|^refs/tags/||; s/^[vV]//; s/^release-//'; }

upstream_latest() {
    case "${TRACK}" in
        github-release)
            local filter='select(.draft == false)'
            [ -n "${INCLUDE_PRERELEASE:-}" ] || filter="${filter} | select(.prerelease == false)"
            gh_get "${API}/repos/${GITHUB_REPO}/releases?per_page=20" \
                | jq -r "[.[] | ${filter}] | .[0].tag_name // empty" 2>/dev/null
            ;;
        git-tag)
            git ls-remote --tags --refs "${GIT_URL}" 2>/dev/null \
                | awk '{print $2}' | normalise \
                | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | tail -1
            ;;
        oci)
            oci_latest_tag "${OCI_IMAGE}" "${OCI_TAG_RE:-.}"
            ;;
        github-paths)
            github_paths_commit "${GITHUB_REPO}" "${TRACK_PATHS}"
            ;;
        aur)
            aur_pkg_version "${AUR_PKG}"
            ;;
        *) return 1 ;;
    esac
}

github_paths_commit() {
    local repo="$1" paths="$2" path sha date best_sha='' best_date=''
    [ -n "${paths}" ] || return 1
    for path in ${paths}; do
        sha=; date=
        read -r sha date <<< "$(gh_get "${API}/repos/${repo}/commits?per_page=1&path=${path}" 2>/dev/null \
            | jq -r '.[0] | select(.sha != null) | "\(.sha) \(.commit.committer.date)"' 2>/dev/null)" || true
        [ -n "${sha}" ] || return 1
        if [ -z "${best_date}" ] || [[ "${date}" > "${best_date}" ]]; then
            best_sha="${sha}"; best_date="${date}"
        fi
    done
    [ -n "${best_sha}" ] || return 1
    printf '%s' "${best_sha}"
}

github_commit_date() {
    gh_get "${API}/repos/$1/commits/$2" 2>/dev/null \
        | jq -r '.commit.committer.date // empty' 2>/dev/null \
        | cut -c1-10 | tr -d -
}

oci_latest_tag() {
    local image="$1" tag_re="${2:-.}" host path tok digest tag
    host="${image%%/*}"
    path="${image#*/}"

    tok="$(curl -fsS "https://${host}/token?scope=repository:${path}:pull&service=${host}" 2>/dev/null | jq -r '.token // empty')"
    [ -n "${tok}" ] || return 1

    local accept='application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json'
    _digest_of() {
        curl -fsS -o /dev/null -D - -H "Authorization: Bearer ${tok}" -H "Accept: ${accept}" \
            "https://${host}/v2/${path}/manifests/$1" 2>/dev/null \
            | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}'
    }

    digest="$(_digest_of latest)"
    [ -n "${digest}" ] || return 1
    for tag in $(curl -fsS -H "Authorization: Bearer ${tok}" \
                   "https://${host}/v2/${path}/tags/list" 2>/dev/null \
                 | jq -r '.tags[]?' | grep -E "${tag_re}"); do
        if [ "$(_digest_of "${tag}")" = "${digest}" ]; then
            printf '%s' "${tag}"; return 0
        fi
    done
    return 1
}

repo_file_value() {
    local repo="$1" ref="$2" file="$3" key="$4"
    curl -fsSL "https://raw.githubusercontent.com/${repo}/${ref}/${file}" 2>/dev/null \
        | grep -oE "^${key}=.*" | cut -d= -f2-
}

_ALARM_DB_DIR=

alarm_pkg_version() {
    local repo="$1" name="$2" db entry ver
    [ -n "${_ALARM_DB_DIR}" ] || _ALARM_DB_DIR="$(mktemp -d)"
    db="${_ALARM_DB_DIR}/${repo}.db"
    if [ ! -s "${db}" ]; then
        curl -fsSL --retry 3 --max-time 180 \
            "http://mirror.archlinuxarm.org/aarch64/${repo}/${repo}.db" -o "${db}" || return 1
    fi
    entry="$(tar tzf "${db}" 2>/dev/null | grep -oE "^${name}-[0-9][^/]*" | sort -u | head -1)"
    [ -n "${entry}" ] || return 1
    ver="${entry#"${name}-"}"
    printf '%s' "${ver%-*}"
}

aur_pkg_version() {
    curl -fsSL --retry 2 --max-time 30 \
        "https://aur.archlinux.org/rpc/v5/info/$1" 2>/dev/null \
        | jq -r '.results[0].Version // empty' 2>/dev/null
}

pkgbuild_var() {
    grep -oE "^$2=.*" "$1" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'"
}

git_tag_commit() {
    local url="$1" tag="$2" out
    out="$(git ls-remote "${url}" "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>/dev/null)" || return 1
    [ -n "${out}" ] || return 1
    printf '%s\n' "${out}" \
        | awk '/\^\{\}$/ { print $1; found = 1; exit } { plain = $1 } END { if (!found && plain) print plain }'
}

hyprpm_paired_commit() {
    local repo="$1" hlcommit="$2"
    case "${hlcommit}" in
        [0-9a-f][0-9a-f]*) [ "${#hlcommit}" -eq 40 ] || return 1 ;;
        *) return 1 ;;
    esac
    curl -fsSL --retry 2 --max-time 30 \
        "https://raw.githubusercontent.com/${repo}/HEAD/hyprpm.toml" 2>/dev/null \
        | sed -n '/commit_pins/,/^]/p' \
        | grep -oE "\"${hlcommit}\"[[:space:]]*,[[:space:]]*\"[0-9a-f]{40}\"" \
        | tail -1 \
        | grep -oE '[0-9a-f]{40}' | tail -1
}

git_ref_commit() {
    local url="$1" ref="$2"
    case "${ref}" in
        [0-9a-f]*) [ "${#ref}" -eq 40 ] && { printf '%s' "${ref}"; return 0; } ;;
    esac
    git_tag_commit "${url}" "${ref}"
}

armada_terra_source_ref() {
    local repo="$1" ref="$2" envfile="$3" envkey="$4" specrepo="$5" specpath="$6" keys="$7"
    local terra spec key val
    terra="$(repo_file_value "${repo}" "${ref}" "${envfile}" "${envkey}")"
    [ -n "${terra}" ] || return 1
    spec="$(curl -fsSL --retry 2 --max-time 30 \
        "https://raw.githubusercontent.com/${specrepo}/${terra}/${specpath}" 2>/dev/null)" || return 1
    [ -n "${spec}" ] || return 1
    for key in ${keys}; do
        val="$(printf '%s\n' "${spec}" \
            | grep -oE "^%global[[:space:]]+${key}[[:space:]]+[^[:space:]]+" | head -1 | awk '{print $3}')"
        [ -n "${val}" ] && { printf '%s' "${val}"; return 0; }
    done
    return 1
}
