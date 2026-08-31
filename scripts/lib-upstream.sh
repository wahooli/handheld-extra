#!/usr/bin/env bash
# Shared upstream resolution. Sourced by poll-upstreams.sh and bump-package.sh
# so "what is the latest version" is answered by one implementation -- if they
# ever disagreed, the poller would report a bump the bumper could not perform.

API="https://api.github.com"

# Refuse to run on an exhausted rate limit.
#
# Without this, every GitHub-tracked package fails its lookup and the poller
# reports them all as errors -- which in CI means an issue claiming eight
# packages are broken when the truth is one HTTP 403. Unauthenticated is 60/hour
# and easy to exhaust by hand; CI passes GH_TOKEN and gets far more.
require_rate_limit() {
    local need="${1:-10}" remaining reset
    local json
    json="$(gh_get "${API}/rate_limit" 2>/dev/null)" || return 0   # cannot tell; proceed
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

# Strip the decorations upstreams put on tags, so a comparison is about the
# version and nothing else: v0.20 and 0.20 are the same release.
normalise() { sed -E 's|^refs/tags/||; s/^[vV]//; s/^release-//'; }

# Latest upstream version for a package whose upstream.env is already sourced.
# Echoes the raw upstream identifier (tag or commit sha); empty on failure.
upstream_latest() {
    case "${TRACK}" in
        github-release)
            local filter='select(.draft == false)'
            [ -n "${INCLUDE_PRERELEASE:-}" ] || filter="${filter} | select(.prerelease == false)"
            gh_get "${API}/repos/${GITHUB_REPO}/releases?per_page=20" \
                | jq -r "[.[] | ${filter}] | .[0].tag_name // empty" 2>/dev/null
            ;;
        git-tag)
            # Version-SHAPED tags only. ValveSoftware/gamescope carries a
            # `dmemcg-experimental` tag and `sort -V` puts any leading letter
            # after every digit, so without this the newest release would
            # forever appear to be an experimental branch.
            git ls-remote --tags --refs "${GIT_URL}" 2>/dev/null \
                | awk '{print $2}' | normalise \
                | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | tail -1
            ;;
        oci)
            oci_latest_tag "${OCI_IMAGE}" "${OCI_TAG_RE:-.}"
            ;;
        *) return 1 ;;
    esac
}

# The tag an OCI image's `latest` currently points at.
#
#   oci_latest_tag ghcr.io/armada-os/armada-packages/gamescope '^[0-9]{8}-[0-9a-f]{8}$'
#
# Resolved by digest rather than by parsing tag names: `latest` always points at
# the current build, and the release tag sharing its digest is the name for it.
# That makes no assumption about how the publisher formats tags beyond the
# caller's pattern, and needs no GitHub API -- so it is unaffected by the
# 60/hour rate limit.
#
# Two limits, both of which fail CLOSED -- returning nothing, so the caller
# reports "could not resolve" rather than bumping to a wrong version:
#
#   Auth      uses the standard OCI token endpoint, which ghcr.io implements. A
#             registry with a different flow (Docker Hub's rate-limited anonymous
#             tokens, anything needing credentials) needs its own branch here.
#
#   Paging    /tags/list returns one page, 100 tags on ghcr. For a publisher with
#             more than that the current release may not be on it: tested against
#             ghcr.io/home-assistant/home-assistant, whose first page is tags
#             from 2021, and nothing matched. armada publishes a handful per
#             package so this never bites; a publisher with many tags would need
#             this to follow the Link header.
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

# A KEY=value from a shell-style file in a GitHub repo at a given ref.
#
#   repo_file_value armada-os/armada-packages 78f00c74 inputplumber/BASE.env VERSION
#
# raw.githubusercontent.com rather than the contents API: no rate limit, no token.
repo_file_value() {
    local repo="$1" ref="$2" file="$3" key="$4"
    curl -fsSL "https://raw.githubusercontent.com/${repo}/${ref}/${file}" 2>/dev/null \
        | grep -oE "^${key}=.*" | cut -d= -f2-
}
