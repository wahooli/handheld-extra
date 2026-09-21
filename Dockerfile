FROM alpine:3 AS fetch
ARG ALARM_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
RUN apk add --no-cache curl tar zstd

RUN mkdir -p /alarm \
 && curl --retry 3 --retry-delay 2 -fsSL "$ALARM_URL" -o /tmp/alarm.tar.gz \
 && tar -xpf /tmp/alarm.tar.gz -C /alarm \
 && rm /tmp/alarm.tar.gz \
 && rm -rf /alarm/usr/lib/firmware /alarm/boot/* /alarm/usr/lib/modules \
 && rm -rf /alarm/var/lib/pacman/local/linux-aarch64-* \
           /alarm/var/lib/pacman/local/linux-firmware-*

FROM scratch
COPY --from=fetch /alarm/ /

RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf

RUN pacman-key --init \
 && pacman-key --populate archlinuxarm \
 && pacman -Syu --noconfirm \
 && pacman -S --noconfirm --needed \
      base-devel ccache git rsync \
      bc cpio gettext kmod libelf pahole perl python tar xz zstd \
      dtc bison flex openssl inetutils \
 && pacman -Scc --noconfirm

RUN useradd -m -s /bin/bash build \
 && echo 'build ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/build

RUN sed -i 's/^BUILDENV=.*/BUILDENV=(!distcc color ccache check !sign)/' /etc/makepkg.conf \
 && sed -i 's/^#MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' /etc/makepkg.conf \
 && sed -i 's/^COMPRESSZST=.*/COMPRESSZST=(zstd -c -T0 -19 -)/' /etc/makepkg.conf \
 && sed -i "s/^PKGEXT=.*/PKGEXT='.pkg.tar.zst'/" /etc/makepkg.conf

USER build
WORKDIR /work
