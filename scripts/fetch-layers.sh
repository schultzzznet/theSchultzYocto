#!/usr/bin/env bash
# Clones poky and meta-raspberrypi as siblings of this repo, on a matching
# release branch. Run this on the Linux build host -- BitBake needs Linux,
# this won't do anything useful on macOS.
#
# Usage: ./scripts/fetch-layers.sh [branch]
#   branch defaults to "scarthgap" (Yocto 5.0 LTS). Verified via
#   `git ls-remote --heads` that neither poky nor meta-raspberrypi have a
#   "wrynose" branch yet (2026-07-02), despite the official Yocto Quick
#   Build doc showing a wrynose clone example for meta-raspberrypi -- docs
#   were apparently ahead of the actual repo state. Re-check with
#   `git ls-remote --heads <repo-url>` before switching to wrynose.

set -euo pipefail

BRANCH="${1:-scarthgap}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$ROOT_DIR"

if [ -d poky ]; then
  echo "poky/ already exists, skipping clone"
else
  git clone -b "$BRANCH" https://git.yoctoproject.org/poky
fi

if [ -d meta-raspberrypi ]; then
  echo "meta-raspberrypi/ already exists, skipping clone"
else
  git clone -b "$BRANCH" https://git.yoctoproject.org/meta-raspberrypi
fi

cat <<EOF

Layers ready in: $ROOT_DIR

Next steps:
  cd "$ROOT_DIR"
  TEMPLATECONF="\$PWD/theSchultzYocto/conf/templates/schultz" source poky/oe-init-build-env build
  bitbake schultz-image-minimal
EOF
