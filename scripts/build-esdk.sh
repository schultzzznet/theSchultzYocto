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
source "$WORK_DIR/$SCHULTZ_OE_INIT" "$WORK_DIR/$SCHULTZ_BUILD"
set -u

echo "-- bitbake $IMAGE -c $SDK_TASK --"
bitbake "$IMAGE" -c "$SDK_TASK"

INSTALLER="$(find "$WORK_DIR/$SCHULTZ_BUILD/tmp/deploy/sdk" -name "$SDK_GLOB" 2>/dev/null | sort | tail -1)"
[ -n "$INSTALLER" ] || { echo "no SDK installer matching $SDK_GLOB in tmp/deploy/sdk" >&2; exit 1; }
echo "built: $INSTALLER"

[ "$DO_INSTALL" = 1 ] || exit 0

echo "-- installing -> $SDK_INSTALL_DIR --"
sudo mkdir -p "$SDK_INSTALL_DIR"
sudo chown "$(id -u):$(id -g)" "$SDK_INSTALL_DIR"
"$INSTALLER" -y -d "$SDK_INSTALL_DIR"

echo
echo "SDK installed at $SDK_INSTALL_DIR"
echo "Use it:  . $SDK_INSTALL_DIR/environment-setup-*"
