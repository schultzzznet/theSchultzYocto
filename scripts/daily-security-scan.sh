#!/usr/bin/env bash
# Unattended DAILY security refresh for schultz-image-minimal, driven by cron
# (install with scripts/install-daily-scan.sh) on the build host.
#
# What it does, and why daily:
#   1. git pull (ff-only) so recipe changes pushed from the workstation are
#      picked up -- this is what keeps the VEX's recipe-scoping tracking the
#      *current* image: add or remove a recipe and the next scan reflects it.
#   2. bitbake schultz-image-minimal -- refreshes the CVE database
#      (cve-update-db), re-runs cve-check, and regenerates the .manifest +
#      cve-summary.json + pkgdata that the SBOM and VEX are derived from.
#   3. upload-sbom.sh -- pushes the CPE-enriched SBOM and the freshly-scoped
#      VEX to Dependency-Track, archiving a timestamped copy of both.
#
# Dependency-Track re-scans NVD on its own daily, but it will NOT refresh the
# VEX suppressions -- so without this job, a CVE that Yocto has since patched
# would keep showing as active. This job keeps DT's dismissals honest and its
# package list current. See docs/security-and-auditing.md.
#
# Exit: 0 = ok or cleanly skipped; non-zero = build/upload failure (logged).

set -uo pipefail

# cron hands us a near-empty environment. Yocto refuses to build without a
# UTF-8 locale, and bitbake needs a sane PATH and HOME.
export HOME="${HOME:-/home/$(id -un)}"
export LC_ALL="${LC_ALL:-C.UTF-8}" LANG="${LANG:-C.UTF-8}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"
cd "$WORK_DIR"

# Monitor a single, stable "living SBOM" project version by default (updated in
# place each day) instead of spawning a new dated project every night. Explicit
# dated release snapshots remain a separate upload. Override in keys/dtrack.env.
export DTRACK_PROJECT_VERSION="${DTRACK_PROJECT_VERSION:-raspberrypi3-64-rolling}"

LOG_DIR="$WORK_DIR/build/security-scan-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/scan-$(date -u +%Y%m%dT%H%M%SZ).log"
exec >>"$LOG" 2>&1   # dated, greppable audit log, one per run

echo "==== [$(date -Is)] daily security scan on $(hostname) ===="

# One build/scan at a time -- a manual remote-build.sh must not collide with us.
exec 9>"$WORK_DIR/build/.security-scan.lock"
if ! flock -n 9; then
  echo "another scan or build holds the lock -- skipping this run"
  exit 0
fi

# Keep the last 30 scan logs (this run's log is already open above).
ls -1t "$LOG_DIR"/scan-*.log 2>/dev/null | tail -n +31 | xargs -r rm -f

# 1. Pick up recipe changes pushed from the workstation. ff-only = never a
#    surprise merge; if the tree diverged, we build what is already checked out.
if [ "${SCHULTZ_GIT_PULL:-1}" = "1" ] && [ -d "$REPO_DIR/.git" ]; then
  echo "-- git pull --ff-only --"
  git -C "$REPO_DIR" pull --ff-only || echo "git pull skipped/failed; using current tree"
fi

# Dependency-Track creds (+ optional archive dir), gitignored sibling, same
# convention as builds.
if [ -f "$WORK_DIR/keys/dtrack.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$WORK_DIR/keys/dtrack.env"
  set +a
fi
if [ -z "${DTRACK_URL:-}" ]; then
  echo "DTRACK_URL not set (no keys/dtrack.env) -- nothing to upload to; aborting"
  exit 1
fi
export SBOM_ARCHIVE_DIR="${SBOM_ARCHIVE_DIR:-$WORK_DIR/build/sbom-archive}"

# 2. Refresh cve-check + regenerate the SBOM/VEX inputs. oe-init-build-env is
#    not set -u safe, so relax strict mode just for sourcing it.
set +u
# shellcheck disable=SC1091
source poky/oe-init-build-env build
set -u
echo "-- bitbake schultz-image-minimal --"
if ! bitbake schultz-image-minimal; then
  echo "build FAILED -- not uploading stale data"
  exit 1
fi

# 3. Upload SBOM + VEX. The VEX's recipe-scoping is derived fresh from THIS
#    build's manifest, so it always matches the image just built.
echo "-- upload-sbom.sh (SBOM + VEX, archived to $SBOM_ARCHIVE_DIR) --"
"$REPO_DIR/scripts/upload-sbom.sh"
rc=$?
echo "==== [$(date -Is)] finished (upload rc=$rc) ===="
exit "$rc"
