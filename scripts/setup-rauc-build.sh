#!/usr/bin/env bash
# Sets up (idempotently) a SEPARATE build directory that produces the A/B RAUC
# image + update bundle for raspberrypi3-64 -- WITHOUT touching the normal build
# dir (which the daily security scan and the simple single-partition image use).
# Run this ON THE BUILD HOST. Both directory names, and which layers are used,
# come from scripts/release-profile.sh.
#
# It reuses theSchultzYocto's normal config (TEMPLATECONF=schultz: Nexus mirror,
# the CVE scan, package-feed signing, and DISTRO_FEATURES += rauc / IMAGE_INSTALL +=
# "rauc rauc-conf" are already there) and layers on top the bits that turn a
# stock RPi build into an A/B RAUC one, following meta-rauc-community's
# meta-rauc-raspberrypi reference:
#   - the meta-rauc + meta-rauc-raspberrypi layers
#   - U-Boot as the bootloader (RPI_USE_U_BOOT) + a UART console
#   - systemd (the reference, the /data grow service, and /home growfs need it)
#   - the dual-slot wic layout + ext4 rootfs
#
# Then build (from the RAUC build dir this script prints):
#   bitbake schultz-image-minimal   # the A/B SD image  (.wic.gz)
#   bitbake schultz-bundle          # a signed update bundle (.raucb)
#
# See docs/rauc-ab-updates.md for the flash + on-hardware test walkthrough.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"
cd "$WORK_DIR"

# shellcheck disable=SC1091
source "$REPO_DIR/scripts/release-profile.sh"
RB="$SCHULTZ_RAUC_BUILD"

# 1. RAUC layers (idempotent clone).
if [ ! -d "$SCHULTZ_RAUC_COMMUNITY" ]; then
  "$REPO_DIR/scripts/fetch-rauc-layers.sh"
fi

# 2. Init the RAUC build dir from the SAME template as the normal build.
#    oe-init-build-env isn't set -u safe, so relax strict mode just for sourcing it.
set +u
if [ ! -f "$RB/conf/local.conf" ]; then
  TEMPLATECONF="$REPO_DIR/conf/templates/schultz" source "$SCHULTZ_OE_INIT" "$RB"
else
  source "$SCHULTZ_OE_INIT" "$RB"
fi
set -u

# 3. meta-rauc is already in the base template's bblayers; add only the RPi
#    integration layer.
if bitbake-layers show-layers 2>/dev/null | grep -q "meta-rauc-raspberrypi"; then
  echo "meta-rauc-raspberrypi already added"
else
  bitbake-layers add-layer "$WORK_DIR/$SCHULTZ_RAUC_COMMUNITY/meta-rauc-raspberrypi"
fi

# 4. Append the RAUC config block to local.conf exactly once (marker-guarded).
LC="$WORK_DIR/$RB/conf/local.conf"
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
# Ship a gzip-compressed .wic, not the default bzip2: balenaEtcher and every
# other flasher decompress gzip many times faster than bz2 (bz2 is what makes
# flashing feel like it has hung). The .bmap stays so `bmaptool copy` can skip
# the empty blocks entirely -- the genuinely fastest flash. See
# docs/rauc-ab-updates.md.
IMAGE_FSTYPES:remove = "wic.bz2"
IMAGE_FSTYPES:append = " wic.gz wic.bmap"
WKS_FILE = "sdimage-dual-raspberrypi.wks.in"
# Note: meta-rauc-raspberrypi boots a SHARED kernel from the FAT /boot partition
# -- only the rootfs is A/B -- and our layer's boot.cmd.in keeps that model, so
# we deliberately do NOT move the kernel into the rootfs slots.
# <<< theSchultzYocto RAUC A/B config <<<
RAUCEOF
  echo "Appended RAUC config to $LC"
fi

cat <<EOF

$RB is ready. Next (from $WORK_DIR/$RB):
  bitbake schultz-image-minimal   # A/B SD image -> tmp/deploy/images/raspberrypi3-64/*.wic.gz
  bitbake schultz-bundle          # signed update bundle -> *.raucb
EOF
