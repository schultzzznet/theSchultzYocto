#!/usr/bin/env bash
# Builds a cross-development SDK for this distro and installs it on THIS host.
# A Yocto SDK is a self-contained cross-toolchain plus a sysroot that matches
# the image byte-for-byte (same libc, same library versions), so a Linux app
# can be built against this exact device with no Yocto checkout at all.
# See tools/sdk-example/ for a worked example, proven on the real Pi 3 B+.
#
# Run this ON THE BUILD HOST.
#
# Usage:
#   ./scripts/build-esdk.sh                 # standard SDK (works)
#   ./scripts/build-esdk.sh --ext           # extensible SDK -- SEE WARNING
#   ./scripts/build-esdk.sh --no-install    # build only, don't install
#   ./scripts/build-esdk.sh [install-dir]   # default /opt/schultz-sdk
#
# Env: SCHULTZ_IMAGE (image to match), SCHULTZ_MACHINE (board; overrides
#      local.conf), SCHULTZ_BUILD_DIR (build tree to cut from).
#      cut-release.sh sets all three so the SDK matches the released image.
#
# WHY NOT THE eSDK BY DEFAULT (measured 2026-09-16, not assumed):
# `populate_sdk_ext` re-runs bitbake inside a renamed copy of the build system
# to compute a filtered task list, and that pass requires EVERY image task to
# be restorable from sstate. The sbom-cve-check fragment's tasks are not --
# do_sbom_cve_check, do_create_image_spdx, do_create_image_sbom_spdx and
# do_create_rootfs_spdx have no usable setscene there -- so bitbake tries to
# genuinely fetch the NVD database and aborts:
#     Task sbom-cve-check-update-nvd-native.do_fetch attempted to execute
#     unexpectedly ... failed with exit code 'setscene ignore_tasks'
# The standard SDK has no such pass and builds fine. The trade is devtool:
# the eSDK adds `devtool add/build/deploy-target`, the standard SDK gives the
# toolchain only. Tracked in docs/GAPS.md.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"
# shellcheck disable=SC1091
source "$REPO_DIR/scripts/release-profile.sh"

SDK_TASK="populate_sdk"
SDK_GLOB='*-toolchain-*.sh'
DO_INSTALL=1
SDK_INSTALL_DIR="/opt/schultz-sdk"
IMAGE="${SCHULTZ_IMAGE:-schultz-image-minimal}"
# Which build dir to cut the SDK from. cut-release.sh passes its RAUC build dir,
# so the SDK's sysroot comes from the same tree as the image being released --
# an SDK built elsewhere could match a different config and still look fine.
BUILD_DIR="${SCHULTZ_BUILD_DIR:-$SCHULTZ_BUILD}"
# MACHINE is in bitbake's default env passthrough, so exporting it overrides
# local.conf without editing it -- which is how one tree serves several boards.
[ -n "${SCHULTZ_MACHINE:-}" ] && export MACHINE="$SCHULTZ_MACHINE"

for a in "$@"; do
  case "$a" in
    --ext)        SDK_TASK="populate_sdk_ext"; SDK_GLOB='*-toolchain-ext-*.sh' ;;
    --no-install) DO_INSTALL=0 ;;
    -h|--help)    sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)           echo "unknown option: $a" >&2; exit 2 ;;
    *)            SDK_INSTALL_DIR="$a" ;;
  esac
done

# Stale DL_DIR pointers break do_validate_branches long before the SDK task
# runs, with an error that looks like kernel corruption. Cheap to pre-empt.
"$REPO_DIR/scripts/fix-git-alternates.sh" || true

set +u
# shellcheck disable=SC1091
source "$WORK_DIR/$SCHULTZ_OE_INIT" "$WORK_DIR/$BUILD_DIR"
set -u

echo "-- bitbake $IMAGE -c $SDK_TASK ${MACHINE:+(MACHINE=$MACHINE)} --"
bitbake "$IMAGE" -c "$SDK_TASK"

INSTALLER="$(find "$WORK_DIR/$BUILD_DIR/tmp/deploy/sdk" -name "$SDK_GLOB" -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)"
[ -n "$INSTALLER" ] || { echo "no SDK installer matching $SDK_GLOB in $BUILD_DIR/tmp/deploy/sdk" >&2; exit 1; }
echo "built: $INSTALLER"

[ "$DO_INSTALL" = 1 ] || exit 0

echo "-- installing -> $SDK_INSTALL_DIR --"
sudo mkdir -p "$SDK_INSTALL_DIR"
sudo chown "$(id -u):$(id -g)" "$SDK_INSTALL_DIR"
"$INSTALLER" -y -d "$SDK_INSTALL_DIR"

echo
echo "SDK installed at $SDK_INSTALL_DIR"
echo "Use it:  . $SDK_INSTALL_DIR/environment-setup-*"
