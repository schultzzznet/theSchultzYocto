#!/usr/bin/env bash
# Clones the OE/Yocto layer set as siblings of this repo, on a matching
# release branch, and generates dev signing key material. Run this on the
# Linux build host -- BitBake needs Linux, this won't do anything useful on
# macOS.
#
# Usage: ./scripts/fetch-layers.sh [branch]
#   branch defaults to "wrynose" (Yocto 6.0 LTS).
#
# Wrynose changed the repo structure: the `poky` convenience bundle (which
# combined oe-core + bitbake + meta-yocto into one repo) was retired after
# scarthgap. wrynose ships as three separate repos:
#   openembedded-core  -- the core recipe set (was poky/meta/)
#   bitbake            -- the build engine (was poky/bitbake/); branch = 2.18
#   meta-yocto         -- the Poky distro + BSP layers (was poky/meta-poky/,
#                         poky/meta-yocto-bsp/)
# oe-init-build-env still exists, now in openembedded-core/ rather than poky/.
# bblayers.conf.sample is updated accordingly.
#
#   meta-rauc and meta-raspberrypi still use codename branches (wrynose).

set -euo pipefail

BRANCH="${1:-wrynose}"
# BitBake uses a version-numbered branch, not a codename.
BITBAKE_BRANCH="2.18"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

clone_or_update() {
  local url="$1" branch="$2" dir
  dir="$(basename "$url" .git)"
  if [ -d "$dir" ]; then
    echo "$dir/ already present -- updating $branch"
    git -C "$dir" fetch -q origin "$branch"
    git -C "$dir" checkout -q "$branch"
    git -C "$dir" merge -q --ff-only "origin/$branch" || echo "  (ff-only failed -- working tree may be ahead)"
  else
    git clone -b "$branch" "$url"
  fi
}

clone_or_update https://git.openembedded.org/openembedded-core "$BRANCH"
clone_or_update https://git.openembedded.org/bitbake            "$BITBAKE_BRANCH"
clone_or_update https://git.yoctoproject.org/meta-yocto         "$BRANCH"
clone_or_update https://git.yoctoproject.org/meta-raspberrypi   "$BRANCH"
clone_or_update https://github.com/rauc/meta-rauc.git           "$BRANCH"

"$REPO_DIR/scripts/generate-signing-keys.sh"

cat <<EOF

Layers ready in: $ROOT_DIR

Next steps:
  cd "$ROOT_DIR"
  TEMPLATECONF="\$PWD/theSchultzYocto/conf/templates/schultz" source openembedded-core/oe-init-build-env build
  bitbake schultz-image-minimal
EOF
