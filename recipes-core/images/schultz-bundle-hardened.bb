# Signed RAUC bundle wrapping the HARDENED (squashfs, read-only) image -- an
# opt-in sibling of schultz-bundle.bb. Same compatible string, so it installs on
# the same device; a distinct Version so `rauc info` and the release archive can
# tell them apart.
#
# BUILD-VERIFIED, boot pending: a squashfs slot wants system.conf slot
# `type=raw` (not `type=ext4`), because RAUC must write it block-for-block and
# must NOT try ext4 operations on it. The running system's system.conf governs
# that at install time, so switching a device to the hardened track is a
# fresh-flash / slot-type change, not a drop-in OTA over the ext4 image. Full
# writeup + the dm-verity integrity follow-on: docs/rauc-ab-updates.md
# ('Hardened variant').
require recipes-core/images/schultz-bundle.bb

# Wrap the hardened image instead of schultz-image-minimal.
RAUC_SLOT_rootfs = "schultz-image-hardened"

# squashfs image, written to the slot block-for-block (read-only, no mkfs).
RAUC_SLOT_rootfs[fstype] = "squashfs"

# Same CalVer line, -hardened qualifier, so a release can ship both flavours.
RAUC_BUNDLE_VERSION = "2026.09.1-hardened"
