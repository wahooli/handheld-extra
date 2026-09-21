#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-}"
# shellcheck source=/dev/null
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../repo.env"
REPO_NAME="${REPO_NAME:-handheld-extra}"
ARCH_DIR="${ARCH_DIR:-extra/aarch64}"
[ -n "${REPO_URL}" ] || { echo "!! set REPO_URL, e.g. REPO_URL=https://repo.wahoo.li $0" >&2; exit 1; }
REPO_URL="${REPO_URL%/}"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; OFF=$'\033[0m'
[ -t 1 ] || { RED=; GRN=; YLW=; OFF=; }
fails=0
ok()   { echo "  ${GRN}ok${OFF}    $1"; }
bad()  { echo "  ${RED}FAIL${OFF}  $1"; fails=$((fails+1)); }
warn() { echo "  ${YLW}warn${OFF}  $1"; }

W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT

echo "==> ${REPO_URL}"

if curl -fsL --max-time 60 -o "${W}/db" "${REPO_URL}/${ARCH_DIR}/${REPO_NAME}.db"; then
    ok "${REPO_NAME}.db  ($(stat -c%s "${W}/db") bytes)"
else
    bad "${REPO_NAME}.db is not reachable -- bucket not public, or domain not bound to it?"
fi

if curl -fsL --max-time 60 -o "${W}/db.sig" "${REPO_URL}/${ARCH_DIR}/${REPO_NAME}.db.sig"; then
    ok "${REPO_NAME}.db.sig present"
else
    bad "${REPO_NAME}.db.sig missing -- the database is UNSIGNED as published"
fi

if curl -fsL --max-time 60 -o "${W}/key.gpg" "${REPO_URL}/${REPO_NAME}.gpg"; then
    export GNUPGHOME="${W}/gnupg"; mkdir -p "${GNUPGHOME}"; chmod 700 "${GNUPGHOME}"
    if gpg --batch --quiet --import "${W}/key.gpg" 2>/dev/null; then
        fpr="$(gpg --batch --with-colons --list-keys | awk -F: '/^fpr:/{print $10; exit}')"
        ok "${REPO_NAME}.gpg imports  (${fpr})"
        if [ -f "${W}/db.sig" ] && gpg --batch --verify "${W}/db.sig" "${W}/db" 2>/dev/null; then
            ok "database signature verifies against the published key"
        elif [ -f "${W}/db.sig" ]; then
            bad "database signature does NOT verify against the published key"
        fi
    else
        bad "${REPO_NAME}.gpg is not an importable key"
    fi
    unset GNUPGHOME
else
    bad "${REPO_NAME}.gpg missing at the bucket root -- devices cannot bootstrap trust"
fi

hdr="$(curl -fsI --max-time 60 "${REPO_URL}/${ARCH_DIR}/${REPO_NAME}.db" 2>/dev/null || true)"
cc="$(grep -i '^cache-control:' <<< "${hdr}" | tr -d '\r' | cut -d' ' -f2- || true)"
case "${cc}" in
    *max-age=31536000*|*immutable*) bad "database is served immutable (${cc}) -- devices will not see new builds" ;;
    "")                             warn "database has no Cache-Control; Cloudflare defaults apply" ;;
    *)                              ok  "database Cache-Control: ${cc}" ;;
esac

if [ -f "${W}/db" ] && command -v bsdtar >/dev/null; then
    mkdir -p "${W}/x"
    bsdtar -xf "${W}/db" -C "${W}/x" 2>/dev/null || true
    pkgfile="$(grep -rhA1 '^%FILENAME%$' "${W}/x" 2>/dev/null | grep -m1 '\.pkg\.tar\.zst$' || true)"
    if [ -n "${pkgfile}" ]; then
        ok "database indexes ${pkgfile}"
        if curl -fsI --max-time 60 -o /dev/null "${REPO_URL}/${ARCH_DIR}/${pkgfile}"; then
            ok "package object reachable"
        else
            bad "${pkgfile} is indexed but NOT reachable -- upload ordering or a bad prune"
        fi
        if curl -fsI --max-time 60 -o /dev/null "${REPO_URL}/${ARCH_DIR}/${pkgfile}.sig"; then
            ok "package .sig reachable"
        else
            bad "${pkgfile}.sig missing -- SigLevel=Required installs will fail"
        fi
    else
        warn "could not read a package name out of the database"
    fi
elif [ ! -f "${W}/db" ]; then
    warn "no database fetched, so the package-level checks were skipped"
else
    warn "bsdtar not available; skipping the package-level checks"
fi

echo
if [ "${fails}" -eq 0 ]; then
    echo "${GRN}repo looks good${OFF} -- see docs/REPO.md for the device-side setup"
else
    echo "${RED}${fails} problem(s)${OFF}"
    exit 1
fi
