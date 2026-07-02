SUMMARY = "RAUC update bundle for schultz-image-minimal (raspberrypi3-64)"
DESCRIPTION = "Builds a signed RAUC bundle wrapping schultz-image-minimal. \
Requires RAUC_KEY_FILE/RAUC_CERT_FILE (see scripts/generate-signing-keys.sh) \
and a matching rauc-conf (system.conf/keyring) providing the platform's \
'compatible' string -- neither of those exist yet in this repo. See \
docs/yocto-concepts.md for exactly what's scaffolded vs. what's still \
needed (adapted from meta-rauc-community's meta-rauc-raspberrypi layer)."

inherit bundle

RAUC_BUNDLE_FORMAT = "verity"
RAUC_BUNDLE_SLOTS = "rootfs"
RAUC_SLOT_rootfs = "schultz-image-minimal"

RAUC_KEY_FILE ?= "${TOPDIR}/../../keys/development-1.key.pem"
RAUC_CERT_FILE ?= "${TOPDIR}/../../keys/development-1.cert.pem"
