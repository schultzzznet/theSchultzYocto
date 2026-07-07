# Bake SquashFS into the Raspberry Pi kernel (config fragment files/squashfs.cfg)
# so the hardened variant's squashfs rootfs can be mounted at boot without an
# initramfs. Applies wherever linux-raspberrypi is built; harmless for the plain
# ext4 image (adds a few KB), essential for schultz-image-hardened.
#
# IMPORTANT: the A/B setup boots a SHARED kernel from FAT /boot and RAUC only
# updates the rootfs slots -- so this only takes effect on a FRESH FLASH of an SD
# image built with it, not via a rootfs-only OTA. See docs/rauc-ab-updates.md.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://squashfs.cfg"
