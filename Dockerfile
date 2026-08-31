# syntax=docker/dockerfile:1
#
# Build environment for the kernel packages. Not the OS being shipped -- a
# hermetic box with pacman, base-devel and the kernel's build dependencies.
#
# It is an Arch Linux ARM rootfs rather than a stock archlinux image or a
# third-party archlinuxarm mirror, for one reason: the packages built here are
# installed on Arch Linux ARM, so the glibc and toolchain that build them should
# be the ones that will run them. A gcc/glibc skew between builder and target is
# the sort of thing that produces a module that loads everywhere except the
# device you care about.
#
# We are already on aarch64 (native GitHub ARM runner, or your machine), so this
# builds natively -- no qemu-user, no binfmt.

# ---- stage 1: fetch and slim the ALARM generic aarch64 rootfs ----------------
FROM alpine:3 AS fetch
ARG ALARM_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
RUN apk add --no-cache curl tar zstd

RUN mkdir -p /alarm \
 && curl --retry 3 --retry-delay 2 -fsSL "$ALARM_URL" -o /tmp/alarm.tar.gz \
 && tar -xpf /tmp/alarm.tar.gz -C /alarm \
 && rm /tmp/alarm.tar.gz \
 # The tarball is a full bootable system, so it drags in a kernel and the whole
 # linux-firmware family -- around 1.3 GB a build container can never use,
 # because it never boots:
 #     /usr/lib/firmware  ~980M
 #     /boot              ~197M   (linux-aarch64)
 #     /usr/lib/modules   ~188M
 #
 # This MUST happen in the fetch stage. A `pacman -Rns` in the builder stage
 # would only add another layer -- the COPY --from below would still carry every
 # byte and the image would not shrink at all.
 #
 # Nothing depends on them: linux-aarch64 is only optional-for base, and
 # linux-firmware only optional-for linux-aarch64. Dropping the matching
 # /var/lib/pacman/local entries keeps the package database coherent.
 && rm -rf /alarm/usr/lib/firmware /alarm/boot/* /alarm/usr/lib/modules \
 && rm -rf /alarm/var/lib/pacman/local/linux-aarch64-* \
           /alarm/var/lib/pacman/local/linux-firmware-*

# ---- stage 2: the builder ---------------------------------------------------
FROM scratch
COPY --from=fetch /alarm/ /

# pacman 7 sandboxes downloads with Landlock and drops to an 'alpm' user. Neither
# works under Docker's default seccomp profile, and the failure is opaque:
#     error: restricting filesystem access failed because the Landlock ruleset
#            could not be applied: Operation not permitted
#     error: failed to synchronize all databases
# Turning it off is the right call here specifically because this container IS
# the sandbox -- it is disposable, unprivileged and holds no secrets.
RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf

# ALARM ships an expired-by-default keyring on old tarballs; initialise before
# the first sync or every package fails signature verification.
RUN pacman-key --init \
 && pacman-key --populate archlinuxarm \
 && pacman -Syu --noconfirm \
 && pacman -S --noconfirm --needed \
      base-devel ccache git rsync \
      bc cpio gettext kmod libelf pahole perl python tar xz zstd \
      dtc bison flex openssl inetutils \
 && pacman -Scc --noconfirm

# makepkg refuses to run as root, and building as root is a bad habit besides.
RUN useradd -m -s /bin/bash build \
 && echo 'build ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/build

# ccache is the difference between a 40-minute rebuild and a 10-minute one when
# only the patch stack moved. The cache directory is bind-mounted in.
RUN sed -i 's/^BUILDENV=.*/BUILDENV=(!distcc color ccache check !sign)/' /etc/makepkg.conf \
 && sed -i 's/^#MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' /etc/makepkg.conf \
 && sed -i 's/^COMPRESSZST=.*/COMPRESSZST=(zstd -c -T0 -19 -)/' /etc/makepkg.conf \
 # ALARM still defaults PKGEXT to .pkg.tar.xz. zstd at -19 compresses about as
 # well and decompresses several times faster, which is the half that happens on
 # the handheld -- and it is what pacman and the rest of Arch have defaulted to
 # since 2020. The publish scripts glob for .pkg.tar.zst.
 && sed -i "s/^PKGEXT=.*/PKGEXT='.pkg.tar.zst'/" /etc/makepkg.conf

USER build
WORKDIR /work

# unrelated
