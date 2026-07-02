#!/usr/bin/env bash
# Runs ON the build host (not macOS). Fetches poky/meta-raspberrypi if
# missing, bootstraps the build dir if missing, sanity-checks the layers,
# then launches `bitbake schultz-image-minimal` fully detached (setsid +
# nohup) so it survives SSH disconnects. Safe to re-run: setup steps are
# idempotent, but it always (re)launches a build.
#
# Usage: ./scripts/remote-build.sh   (path-independent, run from anywhere)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"
cd "$WORK_DIR"

if [ ! -d poky ] || [ ! -d meta-raspberrypi ]; then
  "$REPO_DIR/scripts/fetch-layers.sh"
fi

# oe-init-build-env isn't written to be `set -u`-safe (references variables
# like BBSERVER that it expects may be unset), so relax strict mode just for
# sourcing it.
set +u
if [ ! -f build/conf/local.conf ]; then
  TEMPLATECONF="$REPO_DIR/conf/templates/schultz" source poky/oe-init-build-env build
else
  source poky/oe-init-build-env build
fi
set -u

bitbake-layers show-layers

LOG="$WORK_DIR/build/schultz-build.log"
echo "Launching bitbake schultz-image-minimal in the background -- log: $LOG"
setsid nohup bitbake schultz-image-minimal > "$LOG" 2>&1 < /dev/null &
disown
echo "Build PID: $!  (tail -f $LOG to follow)"
