#!/usr/bin/env bash
# Runs ON the build host (not macOS). Fetches the layers if missing, bootstraps
# the build dir if missing, sanity-checks the layers, then launches
# `bitbake schultz-image-minimal` fully detached (setsid + nohup) so it survives
# SSH disconnects. Safe to re-run: setup steps are idempotent, but it always
# (re)launches a build. Which Yocto release it builds comes from
# scripts/release-profile.sh.
#
# Usage: ./scripts/remote-build.sh   (path-independent, run from anywhere)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"
cd "$WORK_DIR"

# shellcheck disable=SC1091
source "$REPO_DIR/scripts/release-profile.sh"

"$REPO_DIR/scripts/remote-prereqs.sh"

if [ ! -f "$WORK_DIR/$SCHULTZ_OE_INIT" ]; then
  "$REPO_DIR/scripts/fetch-layers.sh"
fi

# Pick up DTRACK_URL/DTRACK_API_KEY automatically if present, without ever
# committing them -- same gitignored-sibling convention as keys/development-1.*
# (see scripts/generate-signing-keys.sh). Doesn't override already-exported
# values, so `DTRACK_URL=... ./remote-build.sh` still works for one-offs.
if [ -f "$WORK_DIR/keys/dtrack.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$WORK_DIR/keys/dtrack.env"
  set +a
fi

# oe-init-build-env isn't written to be `set -u`-safe (references variables
# like BBSERVER that it expects may be unset), so relax strict mode just for
# sourcing it.
set +u
if [ ! -f "$SCHULTZ_BUILD/conf/local.conf" ]; then
  TEMPLATECONF="$REPO_DIR/conf/templates/schultz" source "$SCHULTZ_OE_INIT" "$SCHULTZ_BUILD"
else
  source "$SCHULTZ_OE_INIT" "$SCHULTZ_BUILD"
fi
set -u

bitbake-layers show-layers

LOG="$WORK_DIR/$SCHULTZ_BUILD/schultz-build.log"
echo "Launching bitbake schultz-image-minimal ($SCHULTZ_RELEASE) in the background -- log: $LOG"
if [ -n "${DTRACK_URL:-}" ]; then
  echo "DTRACK_URL is set -- will auto-upload the SBOM on a successful build."
fi
setsid nohup "$REPO_DIR/scripts/run-build-and-report.sh" > "$LOG" 2>&1 < /dev/null &
disown
echo "Build PID: $!  (tail -f $LOG to follow)"
