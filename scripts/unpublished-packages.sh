#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

# shellcheck source=/dev/null
source ./repo.env

T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
curl -fsSL --retry 3 --max-time 60 -o "${T}/db" "${REPO_URL}/${ARCH_DIR}/${REPO_NAME}.db" \
    || { echo "!! cannot fetch ${REPO_URL}/${ARCH_DIR}/${REPO_NAME}.db" >&2; exit 1; }

declare -A PUBLISHED=()
while read -r name ver; do
    PUBLISHED["${name}"]="${ver}"
done < <(tar -xzOf "${T}/db" --wildcards '*/desc' \
             | awk '/^%NAME%$/ { getline n } /^%VERSION%$/ { getline v; print n, v }')
[ ${#PUBLISHED[@]} -gt 0 ] || { echo "!! ${REPO_NAME}.db lists no packages" >&2; exit 1; }

for f in $(git ls-files 'packages/*/PKGBUILD'); do
    d="$(dirname "${f}")"
    while read -r name ver; do
        [ "${PUBLISHED[${name}]:-}" = "${ver}" ] && continue
        echo "${name}: published ${PUBLISHED[${name}]:-nothing}, PKGBUILD says ${ver}" >&2
        basename "${d}"
        break
    done < <( set +eu; pkgname=; epoch=; pkgver=; pkgrel=
              . "${f}" >/dev/null 2>&1 || true
              for n in "${pkgname[@]}"; do printf '%s %s\n' "${n}" "${epoch:+${epoch}:}${pkgver}-${pkgrel}"; done )
done
