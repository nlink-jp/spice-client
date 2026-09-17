#!/bin/sh
# Runs inside the pinned Alpine image (see build-guest.sh). Builds the agent
# guest (ADR-0003): an Alpine rootfs with dbus, spice-vdagent, xclip, Xorg and
# xrandr from the official CDN, the linux-virt kernel and a pruned module tree,
# this repository's init and Xorg config. Writes kernel, initramfs and
# guest.json with the provenance of everything installed.
set -eu
: "${GUEST_BASE_IMAGE:?GUEST_BASE_IMAGE is required}"
MIRROR="https://dl-cdn.alpinelinux.org/alpine"
apk add --no-cache cpio > /dev/null
mkdir /rootfs
apk --root /rootfs --keys-dir /etc/apk/keys --initdb --no-cache \
    --repository "$MIRROR/v3.22/main" --repository "$MIRROR/v3.22/community" \
    add alpine-base alsa-utils dbus spice-vdagent xclip xorg-server xrandr linux-virt > /tmp/apk.log 2>&1 \
    || { cat /tmp/apk.log; exit 1; }
KVER="$(ls /rootfs/lib/modules)"
test -n "$KVER"
PACKAGES="$(apk --root /rootfs list -I 2> /dev/null | awk '{print $1}' | LC_ALL=C sort | tr '\n' ' ')"
PACKAGES="${PACKAGES% }"
cp /rootfs/boot/vmlinuz-virt /out/vmlinuz-virt
rm -rf /rootfs/boot
# Keep virtio, DRM, input (with uinput) and their dependencies; drop the trees this guest never loads.
for tree in net fs crypto arch drivers/net drivers/usb drivers/scsi drivers/md \
            drivers/nvme drivers/infiniband drivers/mmc drivers/ata drivers/hid \
            drivers/bluetooth drivers/staging drivers/iio drivers/media; do
    rm -rf "/rootfs/lib/modules/$KVER/kernel/$tree"
done
depmod -b /rootfs "$KVER"
# devtmpfs supplies the device nodes at boot.
rm -rf /rootfs/dev
mkdir -p /rootfs/dev /rootfs/proc /rootfs/sys /rootfs/run /rootfs/tmp /rootfs/etc/X11
install -m 0755 /guest/init /rootfs/init
install -m 0644 /guest/xorg.conf /rootfs/etc/X11/xorg.conf
( cd /rootfs && find . -print | LC_ALL=C sort | cpio -o -H newc 2> /dev/null | gzip -1 -n > /out/initramfs.cpio.gz )
KERNEL_SHA="$(sha256sum /out/vmlinuz-virt | cut -d' ' -f1)"
INIT_SHA="$(sha256sum /guest/init | cut -d' ' -f1)"
BUILD_SHA="$(sha256sum /guest/build-in-container.sh | cut -d' ' -f1)"
INITRAMFS_SHA="$(sha256sum /out/initramfs.cpio.gz | cut -d' ' -f1)"
PACKAGE_JSON="\"$(printf '%s' "$PACKAGES" | sed 's/ /","/g')\""
printf '{"kernel": "%s", "package": "%s", "base_image": "%s", "mirror": "%s", "packages": [%s], "vmlinuz_sha256": "%s", "initramfs_sha256": "%s", "init_sha256": "%s", "build_sha256": "%s", "built": "%s"}\n' \
    "$KVER" "$(printf '%s\n' $PACKAGES | grep '^linux-virt-' | head -n 1)" "$GUEST_BASE_IMAGE" "$MIRROR" "$PACKAGE_JSON" \
    "$KERNEL_SHA" "$INITRAMFS_SHA" "$INIT_SHA" "$BUILD_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /out/guest.json
cat /out/guest.json
