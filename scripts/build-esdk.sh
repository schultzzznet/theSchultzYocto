#!/usr/bin/env bash
# Builds the extensible SDK (eSDK) for schultz-image-minimal and installs it
# on THIS host at $SDK_INSTALL_DIR. The eSDK is a self-contained cross
# toolchain + a sysroot matching the image byte-for-byte, PLUS `devtool` for
# the add/build/deploy-target workflow -- see tools/sdk-example/README.md for
# what it's actually for and docs/yocto-concepts.md for the full writeup.
#
# Run this ON THE BUILD HOST.
#
# Usage: ./scripts/build-esdk.sh [install-dir]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"
# shellcheck disable=SC1091
source "$REPO_DIR/scripts/release-profile.sh"

SDK_INSTALL_DIR="${1:-/opt/schultz-sdk}"
IMAGE="${SCHULTZ_IMAGE:-schultz-image-minimal}"

set +u
# shellcheck disable=SC1091
source "$WORK_DIR/$SCHULTZ_OE_INIT" "$WORK_DIR/$SCHULTZ_BUILD"
set -u

echo "-- bitbake $IMAGE -c populate_sdk_ext --"
bitbake "$IMAGE" -c populate_sdk_ext

INSTALLER="$(find "$WORK_DIR/$SCHULTZ_BUILD/tmp/deploy/sdk" -name '*-toolchain-ext-*.sh' -newer "$WORK_DIR/$SCHULTZ_BUILD/conf/local.conf" 2>/dev/null | sort | tail -1)"
[ -n "$INSTALLER" ] || INSTALLER="$(find "$WORK_DIR/$SCHULTZ_BUILD/tmp/deploy/sdk" -name '*-toolchain-ext-*.sh' 2>/dev/null | sort | tail -1)"
[ -n "$INSTALLER" ] || { echo "no eSDK installer found in tmp/deploy/sdk" >&2; exit 1; }

echo "-- installing $INSTALLER -> $SDK_INSTALL_DIR --"
sudo mkdir -p "$SDK_INSTALL_DIR"
sudo chown "$(id -u):$(id -g)" "$SDK_INSTALL_DIR"
"$INSTALLER" -y -d "$SDK_INSTALL_DIR"

echo
echo "eSDK installed at $SDK_INSTALL_DIR"
echo "Use it with:  . $SDK_INSTALL_DIR/environment-setup-*"
