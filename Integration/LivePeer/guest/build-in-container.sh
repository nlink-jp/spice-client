#!/bin/sh
# Runs inside the pinned Alpine image (see build-guest.sh). Writes the guest
# kernel, an initramfs built from this image's own userland plus the pruned
# module tree and init, and guest.json with the provenance of both.
set -eu
: "${GUEST_BASE_IMAGE:?GUEST_BASE_IMAGE is required}"
apk add --no-cache linux-virt cpio > /dev/null
KVER="$(ls /lib/modules)"
test -n "$KVER"
PACKAGE="$(apk list -I linux-virt 2>/dev/null | head -n 1 | cut -d' ' -f1)"
cp /boot/vmlinuz-virt /out/vmlinuz-virt
mkdir -p /rootfs
for directory in bin sbin lib usr etc root; do cp -a "/$directory" /rootfs/; done
mkdir -p /rootfs/dev /rootfs/proc /rootfs/sys /rootfs/run /rootfs/tmp /rootfs/var
# Keep virtio, DRM, input and their dependencies; drop the trees this guest never loads.
for tree in net fs sound crypto arch drivers/net drivers/usb drivers/scsi drivers/md \
            drivers/nvme drivers/infiniband drivers/mmc drivers/ata drivers/hid \
            drivers/bluetooth drivers/staging drivers/iio drivers/media; do
    rm -rf "/rootfs/lib/modules/$KVER/kernel/$tree"
done
depmod -b /rootfs "$KVER"
install -m 0755 /guest/init /rootfs/init
( cd /rootfs && find . -print | LC_ALL=C sort | cpio -o -H newc 2> /dev/null | gzip -1 -n > /out/initramfs.cpio.gz )
KERNEL_SHA="$(sha256sum /out/vmlinuz-virt | cut -d' ' -f1)"
INITRAMFS_SHA="$(sha256sum /out/initramfs.cpio.gz | cut -d' ' -f1)"
printf '{"kernel": "%s", "package": "%s", "base_image": "%s", "vmlinuz_sha256": "%s", "initramfs_sha256": "%s", "built": "%s"}\n' \
    "$KVER" "$PACKAGE" "$GUEST_BASE_IMAGE" "$KERNEL_SHA" "$INITRAMFS_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /out/guest.json
cat /out/guest.json
