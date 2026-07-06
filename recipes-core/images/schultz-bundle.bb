# RAUC update bundle for schultz-image-minimal (raspberrypi3-64).
#
# Active recipe -- meta-rauc is in bblayers.conf. The A/B setup this targets
# (U-Boot, dual-slot wic, slotted system.conf) is built in the dedicated
# build-rauc/ dir from scripts/setup-rauc-build.sh, NOT the plain build/ dir
# (whose image is a single rootfs partition). See docs/rauc-ab-updates.md.
#
# Gotcha kept for posterity: `inherit bundle` needs meta-rauc's bundle.bbclass.
# If you ever drop meta-rauc from bblayers, rename this to .bb.example --
# BitBake parses every .bb up front, so a missing bundle.bbclass hard-fails
# EVERY bitbake call, not just a build of this recipe.
SUMMARY = "RAUC update bundle for schultz-image-minimal (raspberrypi3-64)"
DESCRIPTION = "Builds a signed RAUC bundle wrapping schultz-image-minimal. \
Signing uses RAUC_KEY_FILE/RAUC_CERT_FILE (scripts/generate-signing-keys.sh); \
the on-target keyring + A/B slots live in recipes-core/rauc/ (rauc-conf.bbappend). \
A/B on-target installs are wired as of 2026-07-05: system.conf defines \
rootfs.0/rootfs.1 and scripts/setup-rauc-build.sh builds the dual-partition \
image + U-Boot. Final proof is on physical hardware -- see docs/rauc-ab-updates.md."

inherit bundle

RAUC_BUNDLE_FORMAT = "verity"
RAUC_BUNDLE_SLOTS = "rootfs"
RAUC_SLOT_rootfs = "schultz-image-minimal"

# Ship the rootfs as a raw ext4 filesystem image, NOT meta-rauc's default tar
# archive. Why: RAUC's archive (tar) handler formats the target slot with
# mkfs.ext4 before extracting -- but this minimal image ships no mkfs.ext4
# (no e2fsprogs-mke2fs) and no package manager to add one, so a tar install
# fails at 99% with "failed to run mkfs.ext4: No such file or directory". A
# filesystem image is instead written to the slot block-for-block, needing no
# mkfs on the running system. (This exact line is the first example in
# meta-rauc's own bundle.bbclass header -- it's the idiomatic choice.)
# Trade-off: a bigger bundle (the ~164MB ext4 vs a ~34MB tar). The small-bundle
# alternative is to add "e2fsprogs-mke2fs" to the image and keep the tar -- see
# the troubleshooting note in docs/rauc-ab-updates.md.
RAUC_SLOT_rootfs[fstype] = "ext4"

# Must equal the `compatible` in recipes-core/rauc/files/system.conf, or rauc
# rejects the bundle on the target. Without this it defaults to
# "${MACHINE}-${TARGET_VENDOR}" (raspberrypi3-64-poky), which would NOT match.
RAUC_BUNDLE_COMPATIBLE = "theSchultzYocto-raspberrypi3-64"

# Release version shown by `rauc info` (Version:). Ubuntu-style CalVer
# YYYY.MM.PATCH: bump PATCH when re-cutting a line with fresh Yocto-LTS backports
# (2026.07.0 -> 2026.07.1), bump YYYY.MM for a new line. The codename tracks the
# Yocto LTS base (scarthgap). See the versioning note in docs/security-and-auditing.md.
# Keep this in sync with IMAGE_VERSION in recipes-core/os-release/os-release.bbappend
# (the device stamps the same CalVer into /etc/os-release).
RAUC_BUNDLE_VERSION = "2026.07.1"

RAUC_KEY_FILE ?= "${TOPDIR}/../keys/development-1.key.pem"
RAUC_CERT_FILE ?= "${TOPDIR}/../keys/development-1.cert.pem"
