#!/usr/bin/env bash
# OPT-IN, not part of the default build: clones meta-rauc + meta-rauc-community
# (for the meta-rauc-raspberrypi reference layer) as siblings, for adapting
# RAUC's Raspberry Pi integration example. See docs/yocto-concepts.md before
# running this -- it's a starting point for a real feature, not a working
# A/B setup by itself.
#
# Usage: ./scripts/fetch-rauc-layers.sh [branch]
#   branch defaults to "scarthgap" -- matches poky/meta-raspberrypi. Verified
#   2026-07-03 via `git ls-remote --heads`. (Earlier in this project's life
#   meta-rauc used a "gh_<release>" naming scheme instead -- that's gone now.
#   Branch naming on upstream repos can change over time; re-verify with
#   `git ls-remote --heads <repo-url>` rather than trusting old notes.)

set -euo pipefail

BRANCH="${1:-scarthgap}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$ROOT_DIR"

if [ -d meta-rauc ]; then
  echo "meta-rauc/ already exists, skipping clone"
else
  git clone -b "$BRANCH" https://github.com/rauc/meta-rauc.git
fi

if [ -d meta-rauc-community ]; then
  echo "meta-rauc-community/ already exists, skipping clone"
else
  git clone https://github.com/rauc/meta-rauc-community.git
fi

# meta-rauc-community's master tracks the current dev release (wrynose as of
# 2026-07), whose meta-rauc-raspberrypi LAYERSERIES_COMPAT no longer lists
# scarthgap, so it refuses to load on our build. Pin to b28c04a -- the newest
# master commit still compatible with scarthgap ("meta-rauc-raspberrypi:
# Nanbield and Scarthgap"; the next commit moved to styhead and dropped it).
# DO NOT "upgrade" this to upstream's newer `scarthgap` BRANCH (222c6127, 80
# commits ahead). Tried on real hardware 2026-08-19 and reverted: that branch
# hard-depends on lts-u-boot-mixin (u-boot 2025.04, for RPi5), and 2025.04's
# rpi_arm64_defconfig boots via bootstd -- `bootcmd=bootflow scan` -- so our
# boot.scr is never sourced. The Pi 3 B+ then came up with the VideoCore
# firmware's bootargs: no rauc.slot=, no panic=10, no BOOT_ORDER handling, i.e.
# no slot switching and no rollback, while `rauc status` still reported both
# slots "good". It only booted at all because /boot/cmdline.txt hardcodes
# root=/dev/mmcblk0p2. (Ethernet also never enumerated.) Fixing it means
# restoring script boot in that u-boot's defconfig -- a real project, not a pin bump.
# Idempotent: re-checks out the pin even if the dir already existed.
RAUC_COMMUNITY_REV="b28c04a"
git -C meta-rauc-community checkout -q "$RAUC_COMMUNITY_REV"
echo "meta-rauc-community pinned to $RAUC_COMMUNITY_REV (scarthgap-compatible)"

cat <<'EOF'

Cloned meta-rauc and meta-rauc-community as siblings.

Next steps (not automated -- these are real design decisions, not config):
  1. Read meta-rauc-community/meta-rauc-raspberrypi/README.rst for the
     reference system.conf, wic layout, and boot script for RPi + RAUC.
  2. Adapt (don't blindly copy) it for raspberrypi3-64 + this repo's layer.
  3. Add both layers to bblayers.conf.
  4. Add a rauc-conf.bbappend providing your own system.conf + keyring.
  5. Build and test on real hardware -- A/B boot switching genuinely needs
     physical console access to verify, there's no way around that.
EOF
