#!/usr/bin/env bash
# OPT-IN, not part of the default build: clones meta-rauc + meta-rauc-community
# (for the meta-rauc-raspberrypi reference layer) and meta-lts-mixins as
# siblings, for adapting RAUC's Raspberry Pi integration example. See
# docs/yocto-concepts.md before running this -- it's a starting point for a real
# feature, not a working A/B setup by itself.
#
# Usage: ./scripts/fetch-rauc-layers.sh [branch]
#   branch defaults to "scarthgap" -- matches poky/meta-raspberrypi. Verified
#   2026-07-03 via `git ls-remote --heads`. (Earlier in this project's life
#   meta-rauc used a "gh_<release>" naming scheme instead -- that's gone now.
#   Branch naming on upstream repos can change over time; re-verify with
#   `git ls-remote --heads <repo-url>` rather than trusting old notes.)

set -euo pipefail

BRANCH="${1:-scarthgap}"
# meta-rauc-raspberrypi's rpi_arm64_defconfig.patch only applies to u-boot
# 2025.x, so the layer hard-depends on lts-u-boot-mixin; poky scarthgap ships
# u-boot 2024.01. This branch is where that newer u-boot comes from.
MIXIN_BRANCH="scarthgap/u-boot"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$ROOT_DIR"

# Clone at $2, or move an existing checkout onto it (the meta-rauc-community
# checkout used to be detached at a pinned revision).
clone_or_track() {
  local url="$1" branch="$2" dir
  dir="$(basename "$url" .git)"
  if [ -d "$dir" ]; then
    git -C "$dir" fetch -q origin "$branch"
    git -C "$dir" checkout -q "$branch"
    git -C "$dir" merge -q --ff-only "origin/$branch"
    echo "$dir: tracking $branch ($(git -C "$dir" rev-parse --short HEAD))"
  else
    git clone -b "$branch" "$url"
  fi
}

clone_or_track https://github.com/rauc/meta-rauc.git "$BRANCH"

# Until 2025 meta-rauc-community had no per-release branches, so this was pinned
# detached at b28c04a -- the last master commit whose meta-rauc-raspberrypi still
# listed scarthgap in LAYERSERIES_COMPAT. It has a real `scarthgap` branch now
# (LAYERSERIES_COMPAT "nanbield scarthgap"), so track that instead.
clone_or_track https://github.com/rauc/meta-rauc-community.git "$BRANCH"

clone_or_track https://git.yoctoproject.org/meta-lts-mixins "$MIXIN_BRANCH"

cat <<'EOF'

Cloned meta-rauc, meta-rauc-community and meta-lts-mixins as siblings.

Next steps (not automated -- these are real design decisions, not config):
  1. Read meta-rauc-community/meta-rauc-raspberrypi/README.rst for the
     reference system.conf, wic layout, and boot script for RPi + RAUC.
  2. Adapt (don't blindly copy) it for raspberrypi3-64 + this repo's layer.
  3. Add all three layers to bblayers.conf.
  4. Add a rauc-conf.bbappend providing your own system.conf + keyring.
  5. Build and test on real hardware -- A/B boot switching genuinely needs
     physical console access to verify, there's no way around that.
EOF
