#!/usr/bin/env bash
# Unattended DAILY security refresh for schultz-image-minimal, driven by cron
# (install with scripts/install-daily-scan.sh) on the build host.
#
# What it does, and why daily:
#   1. git pull (ff-only) so recipe changes pushed from the workstation are
#      picked up -- this is what keeps the VEX's recipe-scoping tracking the
#      *current* image: add or remove a recipe and the next scan reflects it.
#   1b. Track the Yocto LTS branch: ff-only pull scarthgap point-releases on
#      poky/meta-raspberrypi/meta-rauc so the image gets LTS CVE backports
#      (SCHULTZ_UPDATE_LTS_LAYERS=0 to freeze). meta-rauc-community stays pinned.
#   2. bitbake schultz-image-minimal -- refreshes the CVE database
#      (cve-update-db), re-runs cve-check, and regenerates the .manifest +
#      cve-summary.json + pkgdata that the SBOM and VEX are derived from.
#   3. upload-sbom.sh -- pushes the CPE-enriched SBOM and the freshly-scoped
#      VEX to Dependency-Track, archiving a timestamped copy of both.
#   4. build-rauc-bundle.sh -- rebuilds the deployable A/B RAUC image + signed
#      update bundle from the same tree, in build-rauc/, and archives them
#      (skippable with SCHULTZ_BUILD_RAUC=0). This keeps the flashable SD image
#      and the OTA bundle current with every recipe/CVE change too, not just DT.
#
# Dependency-Track re-scans NVD on its own daily, but it will NOT refresh the
# VEX suppressions -- so without this job, a CVE that Yocto has since patched
# would keep showing as active. This job keeps DT's dismissals honest and its
# package list current. See docs/security-and-auditing.md and
# docs/rauc-ab-updates.md.
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
# place each day) instead of spawning a new dated project every night. Named
# releases (YYYY.MM.PATCH) are a separate, explicit upload. Override in keys/dtrack.env.
export DTRACK_PROJECT_VERSION="${DTRACK_PROJECT_VERSION:-rolling}"

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

# 1b. Track the Yocto LTS branch. scarthgap (5.0) gets CVE backports as point
#     releases -- without pulling them, cve-check keeps reporting CVEs that LTS
#     has already fixed upstream, and the image never gets the fix. Pull ff-only
#     ONLY on layers actually on the scarthgap branch, so the deliberately
#     pinned meta-rauc-community (detached at b28c04a) is left untouched. A
#     failed pull is non-fatal: we build whatever is checked out. Set
#     SCHULTZ_UPDATE_LTS_LAYERS=0 to freeze the layers (e.g. to reproduce a build).
if [ "${SCHULTZ_UPDATE_LTS_LAYERS:-1}" = "1" ]; then
  echo "-- tracking Yocto LTS (scarthgap) point-releases --"
  for _layer in poky meta-raspberrypi meta-rauc; do
    _d="$WORK_DIR/$_layer"
    [ -d "$_d/.git" ] || continue
    if [ "$(git -C "$_d" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "scarthgap" ]; then
      _before="$(git -C "$_d" rev-parse --short HEAD)"
      git -C "$_d" pull --ff-only >/dev/null 2>&1 || echo "  $_layer: pull skipped/failed"
      _after="$(git -C "$_d" rev-parse --short HEAD)"
      if [ "$_before" != "$_after" ]; then echo "  $_layer: $_before -> $_after (LTS update)"; else echo "  $_layer: $_before (current)"; fi
    else
      echo "  $_layer: not on scarthgap (pinned/detached) -- left as-is"
    fi
  done
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

# 4. Rebuild the deployable A/B RAUC image + signed bundle from the same fresh
#    tree, in the separate build-rauc/ dir. We already hold the shared heavy-
#    build lock for this whole run, so tell the child not to re-acquire it (a
#    second flock on the same file would deadlock) and to log into THIS run's
#    log. A RAUC failure is surfaced but never masks the security result -- the
#    SBOM/VEX upload is the primary job here.
rauc_rc=0
if [ "${SCHULTZ_BUILD_RAUC:-1}" = "1" ]; then
  echo "-- build-rauc-bundle.sh (A/B image + signed bundle) --"
  SCHULTZ_BUILD_LOCK_HELD=1 "$REPO_DIR/scripts/build-rauc-bundle.sh"
  rauc_rc=$?
  echo "RAUC image/bundle build rc=$rauc_rc"
else
  echo "SCHULTZ_BUILD_RAUC=0 -- skipping RAUC image/bundle build"
fi

echo "==== [$(date -Is)] finished (upload rc=$rc, rauc rc=$rauc_rc) ===="
# Surface either failure; the security upload takes priority over the image.
if [ "$rc" -ne 0 ]; then exit "$rc"; fi
exit "$rauc_rc"
