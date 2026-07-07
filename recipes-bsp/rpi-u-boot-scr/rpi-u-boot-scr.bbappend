# Override meta-rauc-raspberrypi's A/B U-Boot boot script (boot.cmd.in) to append
# panic=10 to the kernel bootargs.
#
# Why here and not a kernel config fragment: the linux-raspberrypi kernel is built
# CONFIG_CMDLINE_FROM_BOOTLOADER=y, so it IGNORES CONFIG_CMDLINE and uses only what
# U-Boot passes -- the boot script's `bootargs` is the one place a cmdline addition
# actually takes effect. (recipes-kernel/linux/files/cmdline.cfg is therefore inert
# on this kernel; kept only for a future kernel that honours CMDLINE_EXTEND.)
#
# panic=10 makes a failed A/B boot reboot after 10s instead of hanging, so U-Boot
# decrements the slot's BOOT_x_LEFT each try and rolls back to the good slot on its
# own -- no power-cycle/serial (the first hardened boot panic just hung).
#
# Our layer priority (10 > meta-rauc-raspberrypi's 6) + FILESEXTRAPATHS:prepend make
# this boot.cmd.in win; it is already in SRC_URI (added by meta-rauc-raspberrypi
# under the rauc-integration override), so we only need to shadow the file.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
