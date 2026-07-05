#!/usr/bin/env bash
# Sets up (idempotently) a SEPARATE build directory, build-rauc/, that produces
# the A/B RAUC image + update bundle for raspberrypi3-64 -- WITHOUT touching the
# normal build/ dir (which the daily security scan and the simple single-
# partition image use). Run this ON THE BUILD HOST.
#
# It reuses theSchultzYocto's normal config (TEMPLATECONF=schultz: Nexus mirror,
# cve-check, package-feed signing, and DISTRO_FEATURES += rauc / IMAGE_INSTALL +=
# "rauc rauc-conf" are already there) and layers on top the bits that turn a
# stock RPi build into an A/B RAUC one, following meta-rauc-community's
# meta-rauc-raspberrypi reference:
#   - the meta-rauc + meta-rauc-raspberrypi layers
#   - U-Boot as the bootloader (RPI_USE_U_BOOT) + a UART console
#   - systemd (the reference, the /data grow service, and /home growfs need it)
#   - the dual-slot wic layout + ext4 rootfs
#   - the kernel stored IN each rootfs slot (removed from the shared FAT boot
#     partition) so a slot boots its own kernel
#
# Then build:
#   cd ../build-rauc
#   bitbake schultz-image-minimal   # the A/B SD image  (.wic.bz2)
#   bitbake schultz-bundle          # a signed update bundle (.raucb)
#
# See docs/rauc-ab-updates.md for the flash + on-hardware test walkthrough.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"
cd "$WORK_DIR"

# 1. RAUC layers (idempotent clone).
if [ ! -d meta-rauc ] || [ ! -d meta-rauc-community ]; then
  "$REPO_DIR/scripts/fetch-rauc-layers.sh"
fi

# 2. Init build-rauc from the SAME template as the normal build. oe-init-build-env
#    isn't set -u safe, so relax strict mode just for sourcing it.
set +u
if [ ! -f build-rauc/conf/local.conf ]; then
  TEMPLATECONF="$REPO_DIR/conf/templates/schultz" source poky/oe-init-build-env build-rauc
else
  source poky/oe-init-build-env build-rauc
fi
set -u

# 3. Add the RAUC layers (add-layer is a no-op if already present).
bitbake-layers add-layer "$WORK_DIR/meta-rauc" 2>/dev/null || true
bitbake-layers add-layer "$WORK_DIR/meta-rauc-community/meta-rauc-raspberrypi" 2>/dev/null || true

# 4. Append the RAUC config block to local.conf exactly once (marker-guarded).
LC="$WORK_DIR/build-rauc/conf/local.conf"
MARKER="# >>> theSchultzYocto RAUC A/B config >>>"
if grep -qF "$MARKER" "$LC"; then
  echo "RAUC config already present in $LC"
else
  cat >> "$LC" <<'RAUCEOF'

# >>> theSchultzYocto RAUC A/B config >>>
# Turns this build into the A/B RAUC image (scripts/setup-rauc-build.sh +
# docs/rauc-ab-updates.md). The base template already sets DISTRO_FEATURES +=
# "rauc" and IMAGE_INSTALL += "rauc rauc-conf".
ENABLE_UART = "1"
RPI_USE_U_BOOT = "1"
INIT_MANAGER = "systemd"
IMAGE_FSTYPES:append = " ext4"
WKS_FILE = "sdimage-dual-raspberrypi.wks.in"
# Kernel lives in each rootfs slot (so a slot boots its own kernel), not in the
# shared FAT boot partition. meta-rauc-raspberrypi does this for core-image-
# minimal via a bbappend; we set it here so it also applies to our image.
IMAGE_INSTALL:append = " kernel-image kernel-modules"
RPI_EXTRA_IMAGE_BOOT_FILES:remove = "${KERNEL_IMAGETYPE}"
# <<< theSchultzYocto RAUC A/B config <<<
RAUCEOF
  echo "Appended RAUC config to $LC"
fi

cat <<EOF

build-rauc is ready. Next (from $WORK_DIR/build-rauc):
  bitbake schultz-image-minimal   # A/B SD image -> tmp/deploy/images/raspberrypi3-64/*.wic.bz2
  bitbake schultz-bundle          # signed update bundle -> *.raucb
EOF
