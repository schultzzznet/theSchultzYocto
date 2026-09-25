#!/usr/bin/env bash
# probe-sstate-mirror.sh — prove a build actually restores from an sstate mirror.
# Runs ON a build host, in a throwaway build dir whose own SSTATE_DIR starts EMPTY,
# so every hit bitbake reports can only have come from the mirror.
#
#   ssh rpi5g16nvme bash -s -- http://rpi5g16nvme.local:8687 rpi5g16nvme.local:8686 < scripts/probe-sstate-mirror.sh
#   ... add --setscene-only as a 4th arg for a cheap check (no compiling on a miss)
#
# Args: <mirror-url> <hashserv host:port> [target=busybox] [--setscene-only]
# Exits non-zero unless bitbake's own "Sstate summary" shows Local 0 and Mirrors > 0.
# Must-FAIL check: point <mirror-url> at a dead port with --setscene-only.
set -euo pipefail

MIRROR="${1:?usage: probe-sstate-mirror.sh <mirror-url> <hashserv> [target] [--setscene-only]}"
HASHSERV="${2:?hashserv host:port}"
TARGET="${3:-busybox}"
EXTRA="${4:-}"
WORK="$HOME"
# Not ~/build*: set-nexus-url.sh and friends glob that, and must never see this dir.
PROBE="$WORK/sstate-probe"
LOG="$WORK/sstate-probe.log"

# shellcheck disable=SC1091
source "$WORK/theSchultzYocto/scripts/release-profile.sh"
SRC_CONF="$WORK/$SCHULTZ_BUILD/conf"

rm -rf "$PROBE"
mkdir -p "$PROBE/conf"
cp "$SRC_CONF/local.conf" "$SRC_CONF/bblayers.conf" "$PROBE/conf/"
# Appended, so these win over the production values copied above.
printf '\n# --- probe-sstate-mirror.sh overrides ---\nSSTATE_DIR = "%s"\nSSTATE_MIRRORS = "file://.* %s/PATH;downloadfilename=PATH"\nBB_HASHSERVE = "%s"\n' \
  "$PROBE/sstate-empty" "${MIRROR%/}" "$HASHSERV" >> "$PROBE/conf/local.conf"

cd "$WORK"
set +u
# shellcheck disable=SC1090
source "$WORK/$SCHULTZ_OE_INIT" "$PROBE" > /dev/null
set -u

echo "==> bitbake $TARGET $EXTRA in $PROBE (mirror $MIRROR, hashserv $HASHSERV); log: $LOG"
rc=0
# shellcheck disable=SC2086
bitbake $EXTRA "$TARGET" > "$LOG" 2>&1 || rc=$?

summary="$(grep -m1 'Sstate summary:' "$LOG" || true)"
rm -rf "$PROBE"
[ -n "$summary" ] || { echo "FAIL: no 'Sstate summary' in $LOG (bitbake rc=$rc)"; exit 1; }
echo "  $summary"
echo "  bitbake rc=$rc"
local_hits="$(sed -E 's/.* Local ([0-9]+) .*/\1/' <<< "$summary")"
mirror_hits="$(sed -E 's/.* Mirrors ([0-9]+) .*/\1/' <<< "$summary")"

[ "$local_hits" = 0 ] || { echo "FAIL: $local_hits local hits - the probe's SSTATE_DIR was not empty"; exit 1; }
[ "$mirror_hits" -gt 0 ] || { echo "FAIL: 0 mirror hits - $MIRROR served nothing this build could use"; exit 1; }
[ "$rc" = 0 ] || { echo "FAIL: bitbake failed (rc=$rc) - see $LOG"; exit 1; }
echo "  ok    $mirror_hits tasks restored from $MIRROR"
