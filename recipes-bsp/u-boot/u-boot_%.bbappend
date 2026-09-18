# Require a specific string to interrupt U-Boot's autoboot, instead of any byte.
#
# Stock U-Boot aborts autoboot on the first character that arrives on the
# console. On this BSP the console is the Pi's only header UART (GPIO14/15), so
# "the first character" is whatever else happens to be wired there -- and the
# failure is total, not cosmetic: a GNSS receiver on those pins fed NMEA into
# the prompt, the '$' counted as "hit any key", and every sentence afterwards
# was parsed as a U-Boot command ("Unknown command ',113726.000,,,,,0,00,...'").
# The board never loaded Linux at all. A bare unterminated jumper on pin 10 did
# the same thing, since a floating high-impedance input reads as noise bytes.
# Both observed on HDMI, 2026-09-18.
#
# The security half is the reason this lives in theSchultzYocto rather than in
# the mower layer. An interruptible bootloader console is a root shell for
# anyone who can touch the connector: interrupt, `setenv bootargs ... init=/bin/sh`,
# `boot`. Signed RAUC bundles and A/B rollback protect the update path and do
# nothing about that, so for schultz-image-hardened this closes a real hole.
#
# Keyed rather than bootdelay=-2, which would also stop the hijack but would
# throw away the recovery prompt entirely -- worth keeping on an A/B device
# where the bootloader is where you go when both slots misbehave.
#
# The stop string is lowercase deliberately: NMEA sentences are uppercase
# alphanumerics and punctuation, so they cannot spell it however long they run,
# and line noise spelling eight specific characters in order is not a thing that
# happens.
#
# Mechanism verified before writing this, not assumed: oe-core's
# u-boot-configure.inc merges any *.cfg in SRC_URI into .config via
# merge_config.sh. meta-raspberrypi also carries a u-boot_%.bbappend; bbappends
# are additive, so both apply.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://autoboot-keyed.cfg"
