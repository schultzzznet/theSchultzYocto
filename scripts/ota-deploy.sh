#!/usr/bin/env bash
# Over-the-air deploy of a cut release to a RUNNING device -- NO scp/rsync.
#
# Default (Nexus): the device pulls the signed bundle straight from the release
# artifact repo and STREAMS it into its inactive A/B slot:
#   rauc install http://<nexus>/repository/schultz-releases-raw/theSchultzYocto/<v>/schultz-bundle-<v>.raucb
# Nexus honours HTTP range requests, so nothing is copied to the device's disk.
#
# --local: this build host instead serves the release over an ephemeral HTTP
# server (fallback for when Nexus is down / the release was not published). The
# stock python http.server has no range support, so the device wget-downloads
# then installs -- still no scp.
#
# Either way RAUC verifies the signature; --reboot then boots the new slot and
# verifies; the old slot is left as a one-reboot rollback.
#
# Usage:
#   scripts/ota-deploy.sh <version> <device> [--reboot] [--local]
#     <version>  e.g. 2026.07.1
#     <device>   e.g. 192.168.1.226   or   root@192.168.1.226
#     --reboot   reboot into the new slot and verify os-release afterwards
#     --local    force the ephemeral local HTTP server instead of Nexus
#
# Env: NEXUS_URL (default from keys/nexus.env, else http://MacStudioM2Max12.local:8081),
#      NEXUS_REPO (default schultz-releases-raw), OTA_HTTP_PORT (default 8099, --local).

set -uo pipefail

VERSION="" DEVICE_ARG="" REBOOT=0 LOCAL=0
for a in "$@"; do
  case "$a" in
    --reboot) REBOOT=1 ;;
    --local)  LOCAL=1 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *) if [ -z "$VERSION" ]; then VERSION="$a"; elif [ -z "$DEVICE_ARG" ]; then DEVICE_ARG="$a"; fi ;;
  esac
done
[ -n "$VERSION" ] && [ -n "$DEVICE_ARG" ] || { echo "usage: ota-deploy.sh <version> <device> [--reboot] [--local]" >&2; exit 2; }
case "$DEVICE_ARG" in *@*) TARGET="$DEVICE_ARG" ;; *) TARGET="root@$DEVICE_ARG" ;; esac
DEVICE_HOST="${TARGET#*@}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"
REL_ROOT="$WORK_DIR/build-rauc/releases"
BUNDLE_NAME="schultz-bundle-$VERSION.raucb"

# ssh opts as an array so word-splitting is explicit (device = root, empty pw).
SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

# Rewrite a URL's hostname to an IP the device can reach (the minimal image has
# no mDNS, so a .local name must be pre-resolved here on the build host).
resolve_url_for_device() { # $1 = http://host:port/path
  local url="$1" host ip
  host="$(printf '%s' "$url" | sed -E 's#^https?://([^:/]+).*#\1#')"
  case "$host" in
    *[a-zA-Z]*)
      ip="$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}')"
      [ -n "$ip" ] || ip="$(avahi-resolve -4 -n "$host" 2>/dev/null | awk '{print $2; exit}')"
      [ -n "$ip" ] && printf '%s\n' "${url/$host/$ip}" || printf '%s\n' "$url" ;;
    *) printf '%s\n' "$url" ;;
  esac
}

show_before() {
  echo ">>> BEFORE (device):"
  "${SSH[@]}" "$TARGET" 'grep -E "IMAGE_VERSION|^VERSION=" /etc/os-release 2>/dev/null || true; rauc status | grep -E "Booted from|Activated"' \
    || { echo "cannot reach $TARGET over ssh" >&2; exit 1; }
}
show_after() {
  echo ">>> AFTER install (idle slot now holds $VERSION, activated for next boot):"
  "${SSH[@]}" "$TARGET" 'rauc status | grep -E "Booted from|Activated|bootname|boot status"'
}
reboot_verify() {
  [ "$REBOOT" = 1 ] || return 0
  echo ">>> rebooting into the new slot ..."
  "${SSH[@]}" "$TARGET" 'reboot' >/dev/null 2>&1 || true
  echo ">>> reconnecting + verifying (ssh ConnectionAttempts handles the wait) ..."
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 -o ConnectionAttempts=45 "$TARGET" \
    'echo "-- /etc/os-release --"; grep -E "IMAGE_ID|IMAGE_VERSION|^VERSION=" /etc/os-release; echo "-- rauc --"; rauc status | grep -E "Booted from|Activated|boot status"' \
    || echo "could not reconnect after reboot -- check serial/power"
}

# ---- default: pull from Nexus (true streaming, stable URL) ----
if [ "$LOCAL" = 0 ]; then
  NEXUS_URL_EFF="${NEXUS_URL:-}"
  if [ -z "$NEXUS_URL_EFF" ] && [ -f "$WORK_DIR/keys/nexus.env" ]; then
    NEXUS_URL_EFF="$(sed -nE 's/^NEXUS_URL=//p' "$WORK_DIR/keys/nexus.env" | head -1)"
  fi
  NEXUS_URL_EFF="${NEXUS_URL_EFF:-http://MacStudioM2Max12.local:8081}"
  NREPO="${NEXUS_REPO:-schultz-releases-raw}"
  NEXUS_BUNDLE_URL="$NEXUS_URL_EFF/repository/$NREPO/theSchultzYocto/$VERSION/$BUNDLE_NAME"
  if curl -sfI -o /dev/null "$NEXUS_BUNDLE_URL"; then
    DEV_URL="$(resolve_url_for_device "$NEXUS_BUNDLE_URL")"
    echo ">>> source: Nexus  ->  $DEV_URL"
    show_before
    echo ">>> rauc install (device streams the signed bundle from Nexus into its idle slot) ..."
    "${SSH[@]}" "$TARGET" "rauc install '$DEV_URL'" || { echo "OTA install failed" >&2; exit 1; }
    show_after
    reboot_verify
    echo ">>> OTA of $VERSION -> $TARGET complete via Nexus (old slot kept as rollback)."
    exit 0
  fi
  echo ">>> $VERSION not in Nexus ($NEXUS_BUNDLE_URL); falling back to --local." >&2
  LOCAL=1
fi

# ---- --local: serve the release from this host over an ephemeral HTTP server ----
[ -f "$REL_ROOT/$VERSION/$BUNDLE_NAME" ] || { echo "no bundle for $VERSION at $REL_ROOT/$VERSION/$BUNDLE_NAME -- run cut-release.sh first" >&2; exit 1; }
HOST_IP="$(ip route get "$DEVICE_HOST" 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')"
[ -n "$HOST_IP" ] || HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PORT="${OTA_HTTP_PORT:-8099}"
URL="http://$HOST_IP:$PORT/$VERSION/$BUNDLE_NAME"
python3 -m http.server "$PORT" --directory "$REL_ROOT" --bind 0.0.0.0 >/dev/null 2>&1 &
HTTP_PID=$!
trap 'kill "$HTTP_PID" 2>/dev/null' EXIT
curl --retry 20 --retry-delay 1 --retry-all-errors -sfo /dev/null "http://127.0.0.1:$PORT/$VERSION/" \
  || { echo "local HTTP server did not come up on :$PORT" >&2; exit 1; }
echo ">>> source: local ephemeral server  ->  $URL"
show_before
echo ">>> rauc install ..."
if ! "${SSH[@]}" "$TARGET" "rauc install '$URL'"; then
  echo "streaming install failed (python http.server has no range support); device-side wget instead (still no scp) ..." >&2
  "${SSH[@]}" "$TARGET" "wget -q -O /tmp/ota.raucb '$URL' && rauc install /tmp/ota.raucb && rm -f /tmp/ota.raucb" \
    || { echo "OTA install failed" >&2; exit 1; }
fi
show_after
reboot_verify
echo ">>> OTA of $VERSION -> $TARGET complete via local server (old slot kept as rollback)."
