#!/usr/bin/env bash
#
# Sign the built packages, fold them into the [handheld-extra] database, and push
# the result to Cloudflare R2.
#
# This is the kernel repo's publisher with the identity read from repo.env and a
# smaller retention default. Deliberately a copy, not a shared library: the two
# repositories publish independently, and neither ever needs to change for the
# other's sake -- sharing would be coupling with no upside.
#
# Keep it in step by re-deriving from the kernel repo rather than hand-patching;
# the CreateBucket 501 fix reached this copy late precisely because it was not.
#
# Required environment:
#   R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET
#   REPO_SIGNING_KEY            armored private key
#   REPO_SIGNING_KEY_PASSPHRASE
# Optional:
#   REPO_NAME (default: handheld)   pacman repo / database name
#   RETAIN    (default: 3)          versions kept per package name
#   DRY_RUN=1                       do everything except write to R2
#   CHECK_ONLY=1                    only prove the credentials work, then exit
#
# CHECK_ONLY exists because DRY_RUN deliberately touches no network, so without
# it the first thing that ever exercises the R2 token is a real publish -- at the
# end of a 40-minute kernel build. It does a write/read/delete round trip, which
# is the only way to tell a working token from one created with the wrong
# permission level or scoped to a different bucket.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

# Identity comes from repo.env so scripts and workflows cannot disagree about
# which database they are writing.
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

# ── which repo-add ──────────────────────────────────────────────────────────
# Prefer the builder image's, because its pacman is the one that built these
# packages. The host's is whatever the platform ships, and on GitHub's Ubuntu
# runners `pacman-package-manager` is 6.0.2 while Arch is on 7.1.0 -- old enough
# not to know --include-sigs, and old repo-add does not reject unknown options,
# it treats them as the database filename:
#     ERROR: '--include-sigs' does not have a valid database archive extension.
# Pinning to the container removes the whole class of version-skew bugs here,
# not just that flag.
#
# No signing happens in the container: repo-add is called without --sign and the
# key is never mounted. The database is signed afterwards, on the host.
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
# The kernel repo always builds exactly two packages; here the set varies per
# run, and an empty out/ is a real possibility rather than an impossibility.
shopt -s nullglob
PKGS=(out/*.pkg.tar.zst)
shopt -u nullglob
if [ -z "${CHECK_ONLY}" ] && [ ${#PKGS[@]} -eq 0 ]; then
    echo "!! no packages in out/ -- run scripts/build.sh <package>..." >&2; exit 1
fi

# --------------------------------------------------------------------------
# rclone remote, configured entirely from env so nothing lands on disk
# --------------------------------------------------------------------------
export RCLONE_CONFIG=""                      # no config file at all
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2_ACL=private
# R2 does not implement multipart ETags the way rclone's default checksum
# handling expects; without this, every upload is followed by a failed verify.
# no-check-bucket, set BOTH ways on purpose.
#
# Without it rclone issues `PUT /<bucket>` -- a CreateBucket call -- before every
# upload, and R2 does not implement CreateBucket:
#     ERROR : <file>: Failed to copy: NotImplemented: Not Implemented
#     status code: 501
# Each file is a separate rclone process, so the bucket check is not cached
# between them: every object failed once and succeeded on the retry. Verified
# against a fake S3 that logs requests -- unset, rclone sends the bucket-level
# PUT; set, it goes straight to PUT /<bucket>/<key>?x-id=PutObject.
#
# The backend-wide RCLONE_S3_* form alone did not take on the rclone 1.60.1 that
# Ubuntu 24.04 ships, when the remote is defined entirely by RCLONE_CONFIG_R2_*
# env vars rather than a config file. The remote-scoped form binds to this
# specific remote and is the one that matters; the other is kept because it costs
# nothing and covers any rclone that prefers it.
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
export RCLONE_S3_NO_CHECK_BUCKET=true
export RCLONE_S3_UPLOAD_CUTOFF=5G
# Fail fast on an unreachable or misconfigured endpoint. rclone's defaults retry
# for minutes, which in CI reads as a hung publish rather than as a bad secret --
# and the point of this job is that failures are loud and quick.
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

# --------------------------------------------------------------------------
# 1. Signing key, in a throwaway keyring
# --------------------------------------------------------------------------
export GNUPGHOME="${WORK}/gnupg"; mkdir -p "${GNUPGHOME}"; chmod 700 "${GNUPGHOME}"
[ -n "${REPO_SIGNING_KEY:-}" ] || { echo "!! REPO_SIGNING_KEY is not set" >&2; exit 1; }
printf '%s' "${REPO_SIGNING_KEY}" | gpg --batch --quiet --import
GPGKEY="$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr:/{print $10; exit}')"
[ -n "${GPGKEY}" ] || { echo "!! no secret key after import" >&2; exit 1; }
echo "==> signing as ${GPGKEY}"

gpg_sign() {   # $1 = file to detach-sign
    gpg --batch --yes --quiet --pinentry-mode loopback \
        --passphrase "${REPO_SIGNING_KEY_PASSPHRASE:-}" \
        --local-user "${GPGKEY}" --detach-sign --no-armor "$1"
}

for p in "${PKGS[@]}"; do
    [ -f "${p}.sig" ] || gpg_sign "${p}"
done

# The bootstrap key, published at the bucket root so a device with no keyring
# yet can `pacman-key --add` it over https before trusting anything.
gpg --batch --yes --export --output "${WORK}/${REPO_NAME}.gpg" "${GPGKEY}"

# --------------------------------------------------------------------------
# 2. Refuse to overwrite a filename that is already published
# --------------------------------------------------------------------------
# Packages go up with `Cache-Control: immutable`, which is a PROMISE that the
# bytes behind a given filename never change. Overwriting one breaks it in the
# nastiest way available: Cloudflare's edge keeps handing out the PREVIOUS build
# for up to a year, while the database -- max-age=60 -- already carries the new
# sha256 and the new signature. The device downloads a package that does not
# match the index entry it just fetched:
#     error: hyprgrass: signature from "handheld repo <repo@wahoo.li>" is invalid
#     :: File /var/cache/pacman/pkg/hyprgrass-...pkg.tar.zst is corrupted
#        (invalid or corrupted package (PGP signature)).
# Nothing on the device fixes that -- the staleness is at the edge, and clearing
# the pacman cache only re-downloads the same stale object. It is also invisible
# from here: origin, database and signature are all perfectly consistent.
#
# It has happened once, to hyprgrass 0.8.2+hypr0.56.1-1: a comment-only edit to
# its upstream.env re-triggered the build, the same commit rebuilt into
# non-identical bytes, and those went to the same object name. build.sh no longer
# rebuilds for upstream.env alone, but that only removes one way in -- a
# Dockerfile change, a makedepend moving underneath, a manual `--all` run can all
# rebuild an unbumped version. pkgrel is what gives new bytes a new name, so the
# only safe answer is to stop here and say so.
#
# Identical bytes are fine and pass: re-running a publish that half-failed must
# stay idempotent. Hashes come from rclone in ONE listing rather than a HEAD per
# package; R2 returns the md5 as the etag for the single-part uploads this script
# makes (UPLOAD_CUTOFF=5G), so it is directly comparable to md5sum here.
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
        [ -n "${REMOTE_MD5[${b}]+x}" ] || continue          # not published yet
        local_md5="$(md5sum "${p}" | cut -d' ' -f1)"
        # An empty remote hash means the object exists but R2 gave no md5 for it
        # (a multipart upload from some other tool). Unverifiable is treated as a
        # clash on purpose: the whole point here is to never guess about bytes a
        # device will check a signature against.
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

# --------------------------------------------------------------------------
# 3. Pull the current database, fold the new packages in
# --------------------------------------------------------------------------
DB="${WORK}/db"; mkdir -p "${DB}"
# A dry run must not need the network: it exists to check the signing and
# database logic, and reaching for a bucket it will not write to only turns a
# bad credential into a slow, confusing failure.
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
  # --include-sigs embeds each package's PGP signature in the database. Without
  # it a client on SigLevel=Required has to fetch a separate .sig next to every
  # package -- an extra request per install, and a hard failure if that object
  # is missing for any reason. Arch's own repos include them.
  #
  # No --remove: that deletes the superseded package FILE from disk, which here
  # is a temp directory holding only the new packages, so it would do nothing --
  # and retention is handled deliberately further down, against R2 rather than
  # as a side effect. repo-add already replaces the database ENTRY for a package
  # name regardless.
  #
  # No --sign either, and that one is not cosmetic. repo-add shells out to gpg
  # without loopback pinentry, so with a passphrase-protected key it prints
  #     ==> WARNING: Failed to sign package database file
  # and carries on to exit 0. The database then ships UNSIGNED, and a client on
  # SigLevel=...DatabaseOptional accepts it without complaint -- a silent
  # downgrade of exactly the thing signing was meant to guarantee. We sign it
  # below with the same loopback path that already works for the packages.
  if [ -n "${REPO_ADD_IN_CONTAINER}" ]; then
      docker run --rm -v "${DB}:/db" -w /db \
          --user "$(id -u):$(id -g)" -e HOME=/tmp \
          "${IMAGE}" repo-add --quiet --include-sigs "${REPO_NAME}.db.tar.gz" ./*.pkg.tar.zst
  else
      inc=(); repo-add --help 2>&1 | grep -q -- '--include-sigs' && inc=(--include-sigs)
      repo-add --quiet "${inc[@]}" "${REPO_NAME}.db.tar.gz" ./*.pkg.tar.zst
  fi

  # repo-add leaves handheld.db and handheld.files as SYMLINKS to the .tar.gz
  # files, and those are the names pacman actually fetches. rclone skips symlinks
  # unless told otherwise, so materialise them as real files -- otherwise the
  # upload silently omits the database a device asks for by name.
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

# --------------------------------------------------------------------------
# 4. Upload -- ORDER MATTERS
# --------------------------------------------------------------------------
# Packages first, database last. A client that runs `pacman -Sy` in the middle
# of a publish must never receive a database that references a package which is
# not there yet; the reverse (a package nothing points at) is harmless.
#
# Cache headers matter too, because a custom domain puts Cloudflare's edge in
# front of this. Packages are content-addressed by filename and never change,
# so they can be cached forever. The database changes on every publish and must
# not be, or devices get a stale index pointing at packages we have pruned.
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

# --------------------------------------------------------------------------
# 5. Prune -- last, and never below what the database references
# --------------------------------------------------------------------------
# Keep the newest RETAIN versions per package name so a bad build can be rolled
# back on-device with `pacman -U <url>`. Fewer than the kernel keeps: these are
# small, numerous, and far less likely to need a rollback. Pruning happens after the database is
# live, so a client mid-sync never loses a file the index still points at.
#
# Note what retention is FOR: repo-add keeps only the newest version of each
# package name in the database, so `pacman -S` can never reach an older one.
# The retained packages exist purely as direct-URL rollback targets. That is why
# pruning must not touch the current build, and why RETAIN below 2 would leave
# nothing to roll back to.
# Sort pacman versions oldest-first.
vercmp_sort() {
    local -a a=(); mapfile -t a
    [ ${#a[@]} -gt 0 ] || return 0

    # Run the whole sort inside the builder container when it is available, for
    # the same reason repo-add does: its pacman is the one that built these
    # packages. Version-comparison semantics between pacman 6.0.2 (what Ubuntu
    # ships) and 7.1.0 are exactly the sort of thing that differs quietly, and
    # this decides what gets DELETED.
    #
    # One container invocation for the entire sort, not one per comparison --
    # the insertion sort below is O(n^2) and a docker call per comparison would
    # turn a millisecond into a minute.
    if [ -n "${REPO_ADD_IN_CONTAINER}" ]; then
        printf '%s\n' "${a[@]}" | docker run --rm -i "${IMAGE}" bash -c "$(_vercmp_sort_body)"
    else
        printf '%s\n' "${a[@]}" | bash -c "$(_vercmp_sort_body)"
    fi
}

# The sort itself, as a string so it can run here or in the container unchanged.
#
# vercmp is the authority on pacman's ordering and `sort -V` is not a substitute:
# it places 7.2.ogc9 AFTER 7.2.1.ogc10, while pacman considers 7.2.ogc9 the older
# of the two. Pruning with sort -V would delete the newest package and keep the
# oldest the first time OGC moved to a new mainline base. (pacsort would do this
# in one call, but pacman 7.x no longer ships it.)
#
# Insertion sort: n is a handful of versions, so O(n^2) with a subprocess per
# comparison is still instant, and it is obviously correct at a glance.
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
    # Nothing was uploaded, so the only thing that could be there is what we just
    # built. Pretend exactly that, so the grouping and the vercmp sort still get
    # exercised without inventing remote state that does not exist.
    mapfile -t REMOTE_PKGS < <(for p in "${PKGS[@]}"; do basename "${p}"; done | sort)
else
    mapfile -t REMOTE_PKGS < <(rclone lsf "${REMOTE}" --include '*.pkg.tar.zst' 2>/dev/null | sort)
fi
declare -A KEEP=()
for p in "${PKGS[@]}"; do KEEP["$(basename "${p}")"]=1; done

# Group by package name: strip the trailing -<pkgver>-<pkgrel>-<arch>.pkg.tar.zst
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
