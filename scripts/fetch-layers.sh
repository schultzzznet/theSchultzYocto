#!/usr/bin/env bash
# Clones poky, meta-raspberrypi, and meta-rauc as siblings of this repo, on
# a matching release branch, and generates dev signing key material. Run
# this on the Linux build host -- BitBake needs Linux, this won't do
# anything useful on macOS.
#
# Usage: ./scripts/fetch-layers.sh [branch]
#   branch defaults to "scarthgap" (Yocto 5.0 LTS). Verified via
#   `git ls-remote --heads` that neither poky nor meta-raspberrypi have a
#   "wrynose" branch yet (2026-07-02), despite the official Yocto Quick
#   Build doc showing a wrynose clone example for meta-raspberrypi -- docs
#   were apparently ahead of the actual repo state. Re-check with
#   `git ls-remote --heads <repo-url>` before switching to wrynose.
#
#   meta-rauc tracks the same "scarthgap"-style naming as of 2026-07-03 (it
#   used a "gh_<release>" scheme earlier in this project's life -- that's
#   gone now; upstream branch names do change, re-verify rather than trust
#   old notes). See fetch-rauc-layers.sh for meta-rauc-community, which is
#   just reference examples, not something this build depends on.

set -euo pipefail

BRANCH="${1:-scarthgap}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

if [ -d meta-rauc ]; then
  echo "meta-rauc/ already exists, skipping clone"
else
  git clone -b "$BRANCH" https://github.com/rauc/meta-rauc.git
fi

"$REPO_DIR/scripts/generate-signing-keys.sh"

cat <<EOF

Layers ready in: $ROOT_DIR

Next steps:
  cd "$ROOT_DIR"
  TEMPLATECONF="\$PWD/theSchultzYocto/conf/templates/schultz" source poky/oe-init-build-env build
  bitbake schultz-image-minimal
EOF
