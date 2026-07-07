# The RAUC A/B layout boots either an ext4 slot (default image) or a squashfs
# slot (the hardened, read-only image) from the SAME shared /boot/cmdline.txt.
# meta-raspberrypi hard-codes `rootfstype=ext4` into the kernel command line, so
# when U-Boot points root= at the squashfs slot the kernel still tries to mount
# it as ext4, fails ("Unable to mount root fs"), and panics -> auto-rollback.
#
# Clear the forced fstype so the kernel auto-detects the root filesystem. Both
# ext4 and squashfs are built into the kernel (see recipes-kernel/linux), so
# auto-detection mounts either slot correctly.
CMDLINE_ROOT_FSTYPE = ""
