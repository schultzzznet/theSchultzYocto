#!/usr/bin/env bash
# Installs (idempotently) a cron job that runs scripts/daily-security-scan.sh
# once a day ON THE BUILD HOST. Re-run any time to change the schedule; it
# replaces the previous schultz entry rather than stacking duplicates.
#
# Run this on the build host, e.g.:
#   ssh rpi5g16nvme '~/theSchultzYocto/scripts/install-daily-scan.sh 03:30'
#
# Usage: ./scripts/install-daily-scan.sh [HH:MM]   (default 03:30, host local time)
#
# Why cron and not a systemd timer: the build host is headless and this runs as
# an unprivileged user, so cron avoids the user-lingering / D-Bus friction of
# `systemctl --user`. A systemd timer is a fine alternative if you prefer
# Persistent= catch-up -- see docs/security-and-auditing.md.

set -euo pipefail

WHEN="${1:-03:30}"
case "$WHEN" in
  [0-9]*:[0-9]*) : ;;
  *) echo "Time must be HH:MM (got '$WHEN')" >&2; exit 1 ;;
esac
HOUR="${WHEN%:*}"
MIN="${WHEN#*:}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/daily-security-scan.sh"
MARKER="# schultz-daily-security-scan"

if [ ! -f "$SCRIPT" ]; then
  echo "Cannot find $SCRIPT" >&2
  exit 1
fi
chmod +x "$SCRIPT"

LINE="${MIN} ${HOUR} * * * ${SCRIPT} ${MARKER}"
# Drop any prior schultz line, then append the fresh one. `crontab -l` exits
# non-zero when the user has no crontab yet, hence the `|| true`.
( crontab -l 2>/dev/null | grep -v -F "$MARKER" || true; echo "$LINE" ) | crontab -

echo "Installed. Daily security scan scheduled at ${HOUR}:${MIN} (host local time):"
crontab -l | grep -F "$MARKER"
