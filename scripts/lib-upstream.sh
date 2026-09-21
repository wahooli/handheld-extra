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
# Echoes the raw upstream identifier -- a tag, a commit sha, or for TRACK=aur a
# packaged pkgver-pkgrel; empty on failure.
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
        github-paths)
            github_paths_commit "${GITHUB_REPO}" "${TRACK_PATHS}"
            ;;
        aur)
            aur_pkg_version "${AUR_PKG}"
            ;;
        *) return 1 ;;
    esac
}

# The newest commit touching any of a set of paths in a GitHub repo.
#
#   github_paths_commit armada-os/armada 'packages/gamescope/patches packages/TERRA.env'
#     ->  a0bd432ffc5768d2fbaa752892c66f7e7bab9d8a
#
# This is how a publisher who ships no artifact is tracked: the commit IS the
# release. Everything the package needs then resolves from that one sha -- the
# patch set, the base version, the source ref -- so the inputs can never be read
# from two different moments, which is the failure the OCI-tag tracking it
# replaced existed to prevent and which a "latest commit on the default branch"
# watch would reintroduce the moment the publisher touched an unrelated package.
#
# PATHS, plural, and narrow on purpose. It lists what THIS repo actually
# consumes, not what upstream considers a rebuild: gamescope reads their patches
# and their TERRA.env and nothing else, so an edit to their build.sh is correctly
# invisible here. Listing a path we do not consume buys pointless rebuilds;
# omitting one we do buys a silent stale pin -- which is exactly what watching
# only `packages/gamescope/` would have done when TERRA_COMMIT moved.
#
# One request per path, so the caller's rate-limit budget has to account for
# paths rather than packages. Newest committer date wins; a single commit
# touching several of the paths simply answers first.
#
# Fails closed: a path nobody has ever committed to returns nothing rather than
# silently narrowing the watch to the paths that do exist.
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

# The committer date of one commit, as YYYYMMDD.
#
#   github_commit_date armada-os/armada a0bd432ffc57...  ->  20260920
#
# Only VERSION_FROM=commit-date needs this, and only at bump time, so it is a
# second request rather than something threaded through every lookup.
github_commit_date() {
    gh_get "${API}/repos/$1/commits/$2" 2>/dev/null \
        | jq -r '.commit.committer.date // empty' 2>/dev/null \
        | cut -c1-10 | tr -d -
}

# The tag an OCI image's `latest` currently points at.
#
#   oci_latest_tag ghcr.io/some-publisher/packages/gamescope '^[0-9]{8}-[0-9a-f]{8}$'
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
#             from 2021, and nothing matched. A publisher with many tags would
#             need this to follow the Link header.
#
# No package tracks this today -- the one publisher that did stopped shipping
# artifacts and is now followed with TRACK=github-paths. It is kept because it is
# the only tracking mode here that needs no GitHub API and so no rate limit,
# which is the right answer for any publisher that does tag its releases.
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
#   repo_file_value armada-os/armada 956bd2c7 packages/inputplumber/BASE.env VERSION
#
# raw.githubusercontent.com rather than the contents API: no rate limit, no token.
repo_file_value() {
    local repo="$1" ref="$2" file="$3" key="$4"
    curl -fsSL "https://raw.githubusercontent.com/${repo}/${ref}/${file}" 2>/dev/null \
        | grep -oE "^${key}=.*" | cut -d= -f2-
}

# Read a package's version from an Arch Linux ARM sync database.
#
#   alarm_pkg_version extra hyprland   ->  0.56.1
#
# This exists for packages pinned to ANOTHER package's ABI. hyprgrass carries
# depends=('hyprland=<ver>'), an exact match, so it goes stale when ALARM moves
# hyprland -- an axis its own GitHub releases say nothing about. Without this the
# first sign of drift is a device whose `pacman -Syu` refuses to run.
#
# The sync db is what pacman itself reads, so there is no HTML to scrape and no
# API to be rate-limited by. It is ~11 MB and cached for the life of the run.
#
# The pkgrel is stripped deliberately: a `pkg=<ver>` dependency with no pkgrel
# ignores pkgrel, so hyprland 0.56.1-3 satisfies hyprland=0.56.1 and a -3 is not
# drift.
_ALARM_DB_DIR=

alarm_pkg_version() {
    local repo="$1" name="$2" db entry ver
    [ -n "${_ALARM_DB_DIR}" ] || _ALARM_DB_DIR="$(mktemp -d)"
    db="${_ALARM_DB_DIR}/${repo}.db"
    if [ ! -s "${db}" ]; then
        curl -fsSL --retry 3 --max-time 180 \
            "http://mirror.archlinuxarm.org/aarch64/${repo}/${repo}.db" -o "${db}" || return 1
    fi
    # Entries are <name>-<pkgver>-<pkgrel>/. Requiring a DIGIT after the name is
    # what keeps `hyprland` from also matching `hyprland-qtutils-0.1.5-1`.
    entry="$(tar tzf "${db}" 2>/dev/null | grep -oE "^${name}-[0-9][^/]*" | sort -u | head -1)"
    [ -n "${entry}" ] || return 1
    ver="${entry#"${name}-"}"
    printf '%s' "${ver%-*}"
}

# The packaged version -- pkgver-pkgrel -- of a package in the AUR.
#
#   aur_pkg_version gtk2   ->  2.24.33-5
#
# This tracks a PACKAGING axis rather than a source one, which is the right and
# only signal for something whose upstream is finished. gtk2 is the case: GTK 2
# ended at 2.24.33 in 2021, but CVE-2024-6655 reached users as an Arch pkgrel
# bump carrying a new patch. Nothing in a tag list or a release feed says that
# happened.
#
# The v5 RPC, addressed by PATH rather than by the ?arg[]= query form: curl
# treats [] in a URL as a glob range unless -g is passed, and this needs no
# extra flag to be safe.
#
# Fails closed. An unknown package name returns resultcount 0, `// empty` turns
# that into no output, and the caller reports "could not read a version" rather
# than silently treating a typo as up to date.
aur_pkg_version() {
    curl -fsSL --retry 2 --max-time 30 \
        "https://aur.archlinux.org/rpc/v5/info/$1" 2>/dev/null \
        | jq -r '.results[0].Version // empty' 2>/dev/null
}

# Read a plain `name=value` assignment out of a PKGBUILD, without sourcing it.
pkgbuild_var() {
    grep -oE "^$2=.*" "$1" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'"
}

# The commit a tag points at in a remote git repo, without cloning it.
#
#   git_tag_commit https://github.com/hyprwm/Hyprland.git v0.56.2
#     ->  efb50993780079460b0cbed1363e2166a2de1d9f
#
# Both ref forms are asked for and the dereferenced one wins. An ANNOTATED tag
# lists two lines -- `refs/tags/v1` is the sha of the tag OBJECT and only
# `refs/tags/v1^{}` is the commit -- while a LIGHTWEIGHT tag has no ^{} line at
# all. Hyprland's release tags are lightweight today, so reading either form
# alone works right now and resolves to a non-commit the first time upstream
# tags with -a. That failure would not look like a failure: the sha is
# well-formed, it simply matches nothing in the pin table below.
git_tag_commit() {
    local url="$1" tag="$2" out
    out="$(git ls-remote "${url}" "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>/dev/null)" || return 1
    [ -n "${out}" ] || return 1
    printf '%s\n' "${out}" \
        | awk '/\^\{\}$/ { print $1; found = 1; exit } { plain = $1 } END { if (!found && plain) print plain }'
}

# The plugin commit upstream pairs with a given Hyprland commit.
#
#   hyprpm_paired_commit horriblename/hyprgrass efb5099378...  ->  8e605468cb...
#
# Hyprland plugins keep a compatibility table at their repo root: hyprpm.toml
# carries `commit_pins`, a list of [Hyprland commit, plugin commit] pairs. It is
# what hyprpm reads to rebuild a plugin after a compositor bump, and what the AUR
# package parses at build time -- so it is the authoritative answer to "which
# plugin commit targets this compositor", not a heuristic.
#
# Matched on the FULL Hyprland commit and nothing else. There is deliberately no
# nearest-entry fallback: consecutive rows exist precisely BECAUSE an ABI changed
# between them, so the neighbouring row is the one guaranteed not to work. No
# match means upstream has not pinned this compositor yet, and the caller must
# report that rather than pick something close.
#
# The table is read from the default branch, which is also where the packaged
# _commit lives -- a pin for a Hyprland release cannot exist on a branch older
# than that release.
#
# Fails closed: unreadable table, malformed argument, or no pairing all return
# empty, and every caller treats empty as "do not bump".
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

# Resolve a git ref -- a tag or an already-resolved commit -- to a commit sha.
#
# Anything 40 hex characters long is taken as a commit and returned as-is; every
# other form goes to the remote as a tag. That split exists because the upstream
# this serves has used BOTH spellings over time.
git_ref_commit() {
    local url="$1" ref="$2"
    case "${ref}" in
        [0-9a-f]*) [ "${#ref}" -eq 40 ] && { printf '%s' "${ref}"; return 0; } ;;
    esac
    git_tag_commit "${url}" "${ref}"
}

# The SOURCE ref armada's patches are written against.
#
#   armada_terra_source_ref armada-os/armada a0bd432f packages/TERRA.env \
#       TERRA_COMMIT terrapkg/packages \
#       anda/games/terra-gamescope/terra-gamescope.spec 'ver gamescope_commit'
#     ->  3.16.28-ogc1
#
# armada does not package from a source tree of their own: they clone terrapkg
# at a pinned TERRA_COMMIT and inject their patches into Terra's spec, and it is
# THAT spec which names the upstream ref. So the ref armada's patches are written
# against is two hops from the commit we track, and this walks them:
#
#   tracked commit -> packages/TERRA.env TERRA_COMMIT -> terra spec -> ref
#
# Everything comes off the one tracked commit, so the source and the patch set
# can never be resolved from different moments -- which is the entire failure
# this exists to prevent. That used to be the one published artifact tag; since
# armada stopped publishing artifacts it is the one commit sha, and the guarantee
# is the same because both halves are still read at a single ref.
#
# gamescope built `#branch=ogc` for a while, a MOVING branch,
# while the patches were pinned to an artifact; when the fork got far enough
# ahead, 9 of 17 patches stopped applying and every build failed. The patch set
# was never stale -- against the ref Terra pinned, that same set applies with
# zero fuzz.
#
# Two spellings, because Terra has used both: `%global ver <tag>` today and
# `%global gamescope_commit <sha>` before it. They are tried in the order the
# caller lists them.
#
# Fails closed, and that matters more here than usual: an empty ref written into
# a PKGBUILD does not fail the build, it silently clones the default branch --
# reintroducing exactly the bug this removes.
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
