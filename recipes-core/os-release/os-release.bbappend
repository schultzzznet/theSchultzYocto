# Stamp theSchultzYocto's release identity into /etc/os-release.
#
# os-release(5) defines IMAGE_ID / IMAGE_VERSION *specifically* for OS images
# that are "prepared, built, shipped and updated as comprehensive, consistent OS
# images" and A/B-updated -- which is exactly this RAUC setup. So the running
# device self-reports its CalVer release via `cat /etc/os-release`, and the
# stamp rides along with each A/B update (slot A vs B can report different
# IMAGE_VERSIONs). The poky base (5.0.19 scarthgap) stays untouched in the
# standard VERSION / VERSION_ID fields, so nothing about the Yocto identity is
# lost.
#
# Both fields use the restricted os-release charset (lower-case, digits, ".",
# "_", "-"), so they go in OS_RELEASE_UNQUOTED_FIELDS like ID / VERSION_ID.
#
# RELEASE NOTE: bump IMAGE_VERSION together with RAUC_BUNDLE_VERSION in
# recipes-core/images/schultz-bundle.bb when cutting a release (they are the
# same CalVer YYYY.MM.PATCH). Rolling/dev builds carry the in-development line.

OS_RELEASE_FIELDS:append = " IMAGE_ID IMAGE_VERSION"
OS_RELEASE_UNQUOTED_FIELDS:append = " IMAGE_ID IMAGE_VERSION"

IMAGE_ID = "theschultzyocto"
IMAGE_VERSION = "2026.07.1"
