#!/usr/bin/env bash
set -euo pipefail

HOST_UID="${HOST_UID:?}"
HOST_GID="${HOST_GID:?}"

if [ "$(id -u build)" != "${HOST_UID}" ] || [ "$(id -g build)" != "${HOST_GID}" ]; then
    existing_u="$(getent passwd "${HOST_UID}" | cut -d: -f1 || true)"
    existing_g="$(getent group  "${HOST_GID}" | cut -d: -f1 || true)"
    if [ -n "${existing_u}" ] && [ "${existing_u}" != build ]; then
        userdel -r "${existing_u}" 2>/dev/null || true
    fi
    if [ -n "${existing_g}" ] && [ "${existing_g}" != build ]; then
        groupdel "${existing_g}" 2>/dev/null || true
    fi
    groupmod -g "${HOST_GID}" build
    usermod  -u "${HOST_UID}" -g "${HOST_GID}" build
    chown -R build:build /home/build
fi
pacman -Syu --noconfirm >/dev/null 2>&1 || pacman -Syu --noconfirm

chown build:build /ccache 2>/dev/null || true
mkdir -p /work/out
chown build:build /work/out 2>/dev/null || true

exec setpriv --reuid=build --regid=build --init-groups \
    /usr/bin/env HOME=/home/build \
                 CCACHE_DIR="${CCACHE_DIR}" \
                 CCACHE_MAXSIZE="${CCACHE_MAXSIZE}" \
                 PACKAGER="${PACKAGER}" \
                 PKGDEST=/work/out \
                 BUILDDIR=/work/.build \
                 SRCDEST=/work/.cache \
                 TARGETS="${TARGETS}" \
    bash -euo pipefail /work/scripts/makepkg-each.sh
