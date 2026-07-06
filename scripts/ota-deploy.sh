#!/usr/bin/env bash
# Over-the-air deploy of a cut release to a RUNNING device -- NO scp/rsync.
#
# This build host acts as a tiny update server: it serves the release bundle
# over HTTP, and the device streams it straight into its inactive A/B slot with
#   rauc install http://<this-host>:<port>/<version>/schultz-bundle-<version>.raucb
# RAUC verifies the signature *as it streams* (nothing is copied to the device's
# disk). With --reboot it then reboots into the new slot and verifies. The old
# slot is left untouched as a one-reboot rollback.
#
# Usage:
#   scripts/ota-deploy.sh <version> <device> [--reboot]
#     <version>  e.g. 2026.07.1   (must exist under build-rauc/releases/)
#     <device>   e.g. 192.168.1.226   or   root@192.168.1.226
#     --reboot   reboot into the new slot and verify os-release afterwards
#
# Env: OTA_HTTP_PORT (default 8099).

set -uo pipefail

VERSION="${1:?usage: ota-deploy.sh <version> <device> [--reboot]}"
DEVICE_ARG="${2:?usage: ota-deploy.sh <version> <device> [--reboot]}"
REBOOT=0; [ "${3:-}" = "--reboot" ] && REBOOT=1
case "$DEVICE_ARG" in *@*) TARGET="$DEVICE_ARG" ;; *) TARGET="root@$DEVICE_ARG" ;; esac
DEVICE_HOST="${TARGET#*@}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"
REL_ROOT="$WORK_DIR/build-rauc/releases"
BUNDLE_REL="$VERSION/schultz-bundle-$VERSION.raucb"
[ -f "$REL_ROOT/$BUNDLE_REL" ] || { echo "no bundle for $VERSION at $REL_ROOT/$BUNDLE_REL -- run cut-release.sh first" >&2; exit 1; }

# ssh opts as an array so word-splitting is explicit (device = root, empty pw).
SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

# The LAN IP the device must reach us on (route toward the device; mDNS .local
# is NOT assumed to resolve on the minimal image).
HOST_IP="$(ip route get "$DEVICE_HOST" 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')"
[ -n "$HOST_IP" ] || HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PORT="${OTA_HTTP_PORT:-8099}"
URL="http://$HOST_IP:$PORT/$BUNDLE_REL"

# Serve the releases tree over HTTP; always kill it on exit.
python3 -m http.server "$PORT" --directory "$REL_ROOT" --bind 0.0.0.0 >/dev/null 2>&1 &
HTTP_PID=$!
trap 'kill "$HTTP_PID" 2>/dev/null' EXIT
# Wait for the server to accept connections (curl --retry, no fixed sleep).
curl --retry 20 --retry-delay 1 --retry-all-errors -sfo /dev/null "http://127.0.0.1:$PORT/$VERSION/" \
  || { echo "local HTTP server did not come up on :$PORT" >&2; exit 1; }

echo ">>> update server: $URL"
echo ">>> BEFORE (device):"
"${SSH[@]}" "$TARGET" 'grep -E "IMAGE_VERSION|^VERSION=" /etc/os-release 2>/dev/null || true; rauc status | grep -E "Booted from|Activated"' || {
  echo "cannot reach $TARGET over ssh" >&2; exit 1; }

echo ">>> rauc install (device streams the signed bundle into its idle slot) ..."
if ! "${SSH[@]}" "$TARGET" "rauc install '$URL'"; then
  echo "streaming install failed; falling back to device-side HTTP download (still no scp) ..." >&2
  "${SSH[@]}" "$TARGET" "wget -q -O /tmp/ota.raucb '$URL' && rauc install /tmp/ota.raucb && rm -f /tmp/ota.raucb" \
    || { echo "OTA install failed" >&2; exit 1; }
fi

echo ">>> AFTER install (idle slot now holds $VERSION, activated for next boot):"
"${SSH[@]}" "$TARGET" 'rauc status | grep -E "Booted from|Activated|bootname|boot status"'

if [ "$REBOOT" = 1 ]; then
  echo ">>> rebooting into the new slot ..."
  "${SSH[@]}" "$TARGET" 'reboot' >/dev/null 2>&1 || true
  echo ">>> reconnecting + verifying (ssh ConnectionAttempts handles the wait) ..."
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 -o ConnectionAttempts=45 "$TARGET" \
    'echo "-- /etc/os-release --"; grep -E "IMAGE_ID|IMAGE_VERSION|^VERSION=" /etc/os-release; echo "-- rauc --"; rauc status | grep -E "Booted from|Activated|boot status"' \
    || echo "could not reconnect after reboot -- check serial/power"
fi

echo ">>> OTA of $VERSION -> $TARGET complete (old slot kept as rollback)."
