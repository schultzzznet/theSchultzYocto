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

# Must equal the `compatible` in recipes-core/rauc/files/system.conf, or rauc
# rejects the bundle on the target. Without this it defaults to
# "${MACHINE}-${TARGET_VENDOR}" (raspberrypi3-64-poky), which would NOT match.
RAUC_BUNDLE_COMPATIBLE = "theSchultzYocto-raspberrypi3-64"

RAUC_KEY_FILE ?= "${TOPDIR}/../keys/development-1.key.pem"
RAUC_CERT_FILE ?= "${TOPDIR}/../keys/development-1.cert.pem"
