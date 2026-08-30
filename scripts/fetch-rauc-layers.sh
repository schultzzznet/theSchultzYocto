#!/usr/bin/env bash
# OPT-IN, not part of the default build: clones meta-rauc + meta-rauc-community
# (for the meta-rauc-raspberrypi reference layer) as siblings, for adapting
# RAUC's Raspberry Pi integration example. See docs/yocto-concepts.md before
# running this -- it's a starting point for a real feature, not a working
# A/B setup by itself.
#
# Usage: ./scripts/fetch-rauc-layers.sh [branch]
#   branch defaults to the active release codename (scripts/release-profile.sh).
#   Both layers are cloned into that release's layer directory, so two Yocto
#   series never share a checkout. (Earlier in this project's life meta-rauc
#   used a "gh_<release>" naming scheme instead -- that's gone now. Branch
#   naming on upstream repos can change over time; re-verify with
#   `git ls-remote --heads <repo-url>` rather than trusting old notes.)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_DIR/scripts/release-profile.sh"
BRANCH="${1:-$SCHULTZ_RELEASE}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$ROOT_DIR"
mkdir -p "$SCHULTZ_LAYER_DIR"

if [ -d "$SCHULTZ_LAYER_DIR/meta-rauc" ]; then
  echo "$SCHULTZ_LAYER_DIR/meta-rauc already exists, skipping clone"
else
  git clone -b "$BRANCH" https://github.com/rauc/meta-rauc.git "$SCHULTZ_LAYER_DIR/meta-rauc"
fi

if [ -d "$SCHULTZ_RAUC_COMMUNITY" ]; then
  echo "$SCHULTZ_RAUC_COMMUNITY already exists, skipping clone"
else
  git clone https://github.com/rauc/meta-rauc-community.git "$SCHULTZ_RAUC_COMMUNITY"
fi

# Which revision is usable is release-specific, and the scarthgap answer is not
# obvious -- see the notes in scripts/release-profile.sh:
#   scarthgap -> pinned to b28c04a. DO NOT "upgrade" this to upstream's newer
#     `scarthgap` BRANCH (222c6127, 80 commits ahead). Tried on real hardware
#     2026-08-19 and reverted: that branch hard-depends on lts-u-boot-mixin
#     (u-boot 2025.04, which exists for RPi5), and under 2025.04 our boot.scr
#     never took effect on the Pi 3 B+ -- /proc/cmdline and the saved bootargs
#     were the VideoCore firmware's, with no rauc.slot=, no panic=10 and no
#     BOOT_ORDER handling, i.e. no slot switching and no rollback, while
#     `rauc status` still reported both slots "good". It only booted at all
#     because /boot/cmdline.txt hardcodes root=/dev/mmcblk0p2.
#     The mechanism is NOT bootstd per se: 2024.01 also runs
#     `bootcmd=bootflow scan` and does source boot.scr correctly (verified on
#     the reverted card) -- something else in 2025.04's rpi_arm64_defconfig
#     changes which bootflow wins. Diagnosing that is a project, not a pin bump.
#   wrynose -> master, which drops the mixin and uses oe-core's stock u-boot
#     2026.01. Proven on hardware 2026-08-30 with a full A -> B -> A rollback.
# Idempotent: re-checks out the pin even if the dir already existed.
git -C "$SCHULTZ_RAUC_COMMUNITY" checkout -q "$SCHULTZ_RAUC_COMMUNITY_REV"
echo "$SCHULTZ_RAUC_COMMUNITY pinned to $SCHULTZ_RAUC_COMMUNITY_REV ($SCHULTZ_RELEASE-compatible)"

cat <<EOF

Cloned meta-rauc and meta-rauc-community into $SCHULTZ_LAYER_DIR/.
EOF
cat <<'EOF'

Next steps (not automated -- these are real design decisions, not config):
  1. Read meta-rauc-community/meta-rauc-raspberrypi/README.rst for the
     reference system.conf, wic layout, and boot script for RPi + RAUC.
  2. Adapt (don't blindly copy) it for raspberrypi3-64 + this repo's layer.
  3. Add both layers to bblayers.conf.
  4. Add a rauc-conf.bbappend providing your own system.conf + keyring.
  5. Build and test on real hardware -- A/B boot switching genuinely needs
     physical console access to verify, there's no way around that.
EOF
