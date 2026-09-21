#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

# shellcheck source=/dev/null
source "${HERE}/repo.env"
REPO_NAME="${REPO_NAME:-handheld-extra}"
ARCH_DIR="${ARCH_DIR:-extra/aarch64}"
RETAIN="${RETAIN:-3}"
DRY_RUN="${DRY_RUN:-}"

for v in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET; do
    [ -n "${!v:-}" ] || { echo "!! ${v} is not set" >&2; exit 1; }
done

command -v rclone >/dev/null || { echo "!! rclone not found" >&2; exit 1; }

IMAGE="${IMAGE:-linux-handheld-builder:latest}"
if command -v docker >/dev/null 2>&1 && docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    REPO_ADD_IN_CONTAINER=1
elif command -v repo-add >/dev/null; then
    REPO_ADD_IN_CONTAINER=
    if ! repo-add --help 2>&1 | grep -q -- '--include-sigs'; then
        echo "==> note: host $(repo-add --version 2>&1 | head -1) has no --include-sigs." >&2
        echo "    Signatures will not be embedded in the database, so clients fetch" >&2
        echo "    each .sig separately -- correct, just one extra request per install." >&2
    fi
else
    echo "!! neither the ${IMAGE} container nor a host repo-add is available" >&2
    exit 1
fi

CHECK_ONLY="${CHECK_ONLY:-}"
shopt -s nullglob
PKGS=(out/*.pkg.tar.zst)
shopt -u nullglob
if [ -z "${CHECK_ONLY}" ] && [ ${#PKGS[@]} -eq 0 ]; then
    echo "!! no packages in out/ -- run scripts/build.sh <package>..." >&2; exit 1
fi

export RCLONE_CONFIG=""
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2_ACL=private
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
export RCLONE_S3_NO_CHECK_BUCKET=true
export RCLONE_S3_UPLOAD_CUTOFF=5G
export RCLONE_RETRIES=2
export RCLONE_LOW_LEVEL_RETRIES=2
export RCLONE_CONTIMEOUT=15s
export RCLONE_TIMEOUT=120s

REMOTE="R2:${R2_BUCKET}/${ARCH_DIR}"
rclone_() { if [ -n "${DRY_RUN}" ]; then echo "   [dry-run] rclone $*"; else rclone "$@"; fi; }

if [ -n "${CHECK_ONLY}" ]; then
    echo "==> endpoint  https://${R2_ACCOUNT_ID:0:6}...${R2_ACCOUNT_ID: -4}.r2.cloudflarestorage.com"
    echo "==> bucket    ${R2_BUCKET}"
    T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
    echo "handheld repo access check" > "${T}/probe"
    P=".r2-access-check"
    rclone lsf "R2:${R2_BUCKET}" --max-depth 1 >/dev/null 2>"${T}/e" \
        || { sed 's/^/    /' "${T}/e" >&2; echo "!! cannot list ${R2_BUCKET} -- wrong bucket, wrong account id, or the token is not scoped to it" >&2; exit 1; }
    echo "  ok  list"
    rclone copyto "${T}/probe" "R2:${R2_BUCKET}/${P}" 2>"${T}/e" \
        || { sed 's/^/    /' "${T}/e" >&2; echo "!! cannot write -- the token is probably 'Object Read only'; it needs 'Object Read & Write'" >&2; exit 1; }
    echo "  ok  write"
    rclone cat "R2:${R2_BUCKET}/${P}" 2>/dev/null | diff -q - "${T}/probe" >/dev/null \
        || { echo "!! wrote the probe but could not read it back identically" >&2; exit 1; }
    echo "  ok  read back"
    rclone deletefile "R2:${R2_BUCKET}/${P}" 2>"${T}/e" \
        || { sed 's/^/    /' "${T}/e" >&2; echo "!! cannot delete -- publishing would work but retention pruning would not" >&2; exit 1; }
    echo "  ok  delete  (needed by retention pruning)"
    echo
    echo "credentials are good"
    exit 0
fi

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"; [ -n "${GNUPGHOME:-}" ] && rm -rf "${GNUPGHOME}"' EXIT

export GNUPGHOME="${WORK}/gnupg"; mkdir -p "${GNUPGHOME}"; chmod 700 "${GNUPGHOME}"
[ -n "${REPO_SIGNING_KEY:-}" ] || { echo "!! REPO_SIGNING_KEY is not set" >&2; exit 1; }
printf '%s' "${REPO_SIGNING_KEY}" | gpg --batch --quiet --import
GPGKEY="$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr:/{print $10; exit}')"
[ -n "${GPGKEY}" ] || { echo "!! no secret key after import" >&2; exit 1; }
echo "==> signing as ${GPGKEY}"

gpg_sign() {
    gpg --batch --yes --quiet --pinentry-mode loopback \
        --passphrase "${REPO_SIGNING_KEY_PASSPHRASE:-}" \
        --local-user "${GPGKEY}" --detach-sign --no-armor "$1"
}

for p in "${PKGS[@]}"; do
    [ -f "${p}.sig" ] || gpg_sign "${p}"
done

gpg --batch --yes --export --output "${WORK}/${REPO_NAME}.gpg" "${GPGKEY}"

if [ -z "${DRY_RUN}" ]; then
    echo "==> checking that no published filename is being overwritten"
    declare -A REMOTE_MD5=()
    while IFS='|' read -r rname rhash; do
        [ -n "${rname}" ] && REMOTE_MD5["${rname}"]="${rhash}"
    done < <(rclone lsf "${REMOTE}" --include '*.pkg.tar.zst' \
                 --hash MD5 --format ph --separator '|' 2>/dev/null || true)

    clash=()
    for p in "${PKGS[@]}"; do
        b="$(basename "${p}")"
        [ -n "${REMOTE_MD5[${b}]+x}" ] || continue
        local_md5="$(md5sum "${p}" | cut -d' ' -f1)"
        [ "${REMOTE_MD5[${b}]}" = "${local_md5}" ] || clash+=("${b}")
    done

    if [ ${#clash[@]} -gt 0 ]; then
        echo "!! these are already published with DIFFERENT content:" >&2
        printf '     %s\n' "${clash[@]}" >&2
        cat >&2 <<'EOM'
!!
!! Publishing them would overwrite an object served as immutable, so devices
!! would keep getting the old bytes with the new signature -- which reads as
!! "signature is invalid / package is corrupted" and cannot be fixed on the
!! device.
!!
!! Bump pkgrel in the PKGBUILD of each package above and rebuild. That gives the
!! new bytes a new filename, which is the only thing that invalidates the edge.
!! (If the rebuild is genuinely byte-identical this check passes on its own.)
EOM
        exit 1
    fi
    echo "    ok -- nothing published is being rewritten"
else
    echo "==> [dry-run] skipping the already-published check (needs the network)"
fi

DB="${WORK}/db"; mkdir -p "${DB}"
if [ -z "${DRY_RUN}" ]; then
    echo "==> fetching current ${REPO_NAME} database"
    rclone copy "${REMOTE}" "${DB}" \
        --include "${REPO_NAME}.db*" --include "${REPO_NAME}.files*" 2>/dev/null || true
    ls -1 "${DB}" 2>/dev/null | sed 's/^/    have /' || echo "    (empty -- first publish)"
else
    echo "==> [dry-run] not fetching the remote database"
fi

cp "${PKGS[@]}" "${DB}/"
for p in "${PKGS[@]}"; do cp "${p}.sig" "${DB}/"; done

( cd "${DB}"
  if [ -n "${REPO_ADD_IN_CONTAINER}" ]; then
      docker run --rm -v "${DB}:/db" -w /db \
          --user "$(id -u):$(id -g)" -e HOME=/tmp \
          "${IMAGE}" repo-add --quiet --include-sigs "${REPO_NAME}.db.tar.gz" ./*.pkg.tar.zst
  else
      inc=(); repo-add --help 2>&1 | grep -q -- '--include-sigs' && inc=(--include-sigs)
      repo-add --quiet "${inc[@]}" "${REPO_NAME}.db.tar.gz" ./*.pkg.tar.zst
  fi

  for n in db files; do
      if [ -L "${REPO_NAME}.${n}" ]; then
          rm -f "${REPO_NAME}.${n}"
          cp "${REPO_NAME}.${n}.tar.gz" "${REPO_NAME}.${n}"
      fi
  done
) < /dev/null

for n in db db.tar.gz files files.tar.gz; do
    [ -f "${DB}/${REPO_NAME}.${n}" ] || continue
    rm -f "${DB}/${REPO_NAME}.${n}.sig"
    gpg_sign "${DB}/${REPO_NAME}.${n}"
done
echo "==> database signed"

echo "==> uploading packages"
for p in "${PKGS[@]}"; do
    b="$(basename "${p}")"
    rclone_ copyto "${p}"      "${REMOTE}/${b}"     --header-upload "Cache-Control: public, max-age=31536000, immutable"
    rclone_ copyto "${p}.sig"  "${REMOTE}/${b}.sig" --header-upload "Cache-Control: public, max-age=31536000, immutable"
    echo "    ${b}"
done

echo "==> uploading database"
for f in "${DB}/${REPO_NAME}".{db,files}{,.tar.gz}{,.sig}; do
    [ -f "${f}" ] || continue
    rclone_ copyto "${f}" "${REMOTE}/$(basename "${f}")" \
        --header-upload "Cache-Control: public, max-age=60, must-revalidate"
    echo "    $(basename "${f}")"
done

rclone_ copyto "${WORK}/${REPO_NAME}.gpg" "R2:${R2_BUCKET}/${REPO_NAME}.gpg" \
    --header-upload "Cache-Control: public, max-age=300"

vercmp_sort() {
    local -a a=(); mapfile -t a
    [ ${#a[@]} -gt 0 ] || return 0

    if [ -n "${REPO_ADD_IN_CONTAINER}" ]; then
        printf '%s\n' "${a[@]}" | docker run --rm -i "${IMAGE}" bash -c "$(_vercmp_sort_body)"
    else
        printf '%s\n' "${a[@]}" | bash -c "$(_vercmp_sort_body)"
    fi
}

_vercmp_sort_body() {
cat <<'BODY'
set -euo pipefail
mapfile -t a
[ ${#a[@]} -gt 0 ] || exit 0
for ((i = 1; i < ${#a[@]}; i++)); do
    x="${a[i]}"
    for ((j = i - 1; j >= 0; j--)); do
        [ "$(vercmp "${a[j]}" "${x}")" -gt 0 ] || break
        a[j+1]="${a[j]}"
    done
    a[j+1]="${x}"
done
printf '%s\n' "${a[@]}"
BODY
}

echo "==> pruning to the newest ${RETAIN} version(s) per package"
if [ -n "${DRY_RUN}" ]; then
    mapfile -t REMOTE_PKGS < <(for p in "${PKGS[@]}"; do basename "${p}"; done | sort)
else
    mapfile -t REMOTE_PKGS < <(rclone lsf "${REMOTE}" --include '*.pkg.tar.zst' 2>/dev/null | sort)
fi
declare -A KEEP=()
for p in "${PKGS[@]}"; do KEEP["$(basename "${p}")"]=1; done

declare -A BYNAME=()
for f in "${REMOTE_PKGS[@]}"; do
    name="$(sed -E 's/-[^-]+-[^-]+-[^-]+\.pkg\.tar\.zst$//' <<< "${f}")"
    BYNAME["${name}"]+="${f}"$'\n'
done

for name in "${!BYNAME[@]}"; do
    mapfile -t versions < <(printf '%s' "${BYNAME[$name]}" | grep -v '^$' \
        | sed -E "s/^${name}-//; s/-aarch64\.pkg\.tar\.zst$//" | vercmp_sort)
    total=${#versions[@]}
    [ "${total}" -gt "${RETAIN}" ] || { echo "    ${name}: ${total} version(s), nothing to prune"; continue; }
    drop=$((total - RETAIN))
    for v in "${versions[@]:0:${drop}}"; do
        f="${name}-${v}-aarch64.pkg.tar.zst"
        [ -n "${KEEP[${f}]:-}" ] && { echo "    ${name}: refusing to prune the build we just published (${v})"; continue; }
        echo "    prune ${f}"
        rclone_ deletefile "${REMOTE}/${f}"      2>/dev/null || true
        rclone_ deletefile "${REMOTE}/${f}.sig"  2>/dev/null || true
    done
done

echo
echo "published ${#PKGS[@]} package(s) to ${REMOTE}"
