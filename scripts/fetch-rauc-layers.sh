#!/usr/bin/env bash
# OPT-IN, not part of the default build: clones meta-rauc + meta-rauc-community
# (for the meta-rauc-raspberrypi reference layer) as siblings, for adapting
# RAUC's Raspberry Pi integration example. See docs/yocto-concepts.md before
# running this -- it's a starting point for a real feature, not a working
# A/B setup by itself.
#
# Usage: ./scripts/fetch-rauc-layers.sh [branch]
#   branch defaults to "gh_scarthgap" -- meta-rauc's branch naming for the
#   Yocto 5.0 LTS series is "gh_<release>", NOT plain "<release>" like
#   poky/meta-raspberrypi. Verify with `git ls-remote --heads` if in doubt.

set -euo pipefail

BRANCH="${1:-gh_scarthgap}"
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
  # meta-rauc-community doesn't use per-release branches (it's example/demo
  # code, master tracks current practice) -- always clone master.
  git clone https://github.com/rauc/meta-rauc-community.git
fi

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
