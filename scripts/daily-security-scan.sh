#!/usr/bin/env bash
# Unattended DAILY security refresh for schultz-image-minimal, driven by cron
# (install with scripts/install-daily-scan.sh) on the build host.
#
# What it does, and why daily:
#   1. git pull (ff-only) so recipe changes pushed from the workstation are
#      picked up -- this is what keeps the VEX's recipe-scoping tracking the
#      *current* image: add or remove a recipe and the next scan reflects it.
#   1b. Track the Yocto LTS branch: ff-only pull point-releases on whichever
#      layers the active release profile lists, so the image gets LTS CVE
#      backports (SCHULTZ_UPDATE_LTS_LAYERS=0 to freeze). A layer that is not on
#      its expected branch is left alone; meta-rauc-community stays pinned.
#   1c. Preflight every endpoint before building. A stale URL costs seconds to
#      detect here and ~20 wasted minutes to detect at the upload stage.
#      Dependency-Track unreachable aborts; DefectDojo or Nexus unreachable just
#      disables that stage.
#   2. bitbake schultz-image-minimal -- refreshes the CVE database, re-runs the
#      CVE scan, and regenerates the .manifest + per-package CVE report +
#      pkgdata that the SBOM and VEX are derived from.
#   3. upload-sbom.sh -- pushes the CPE-enriched SBOM and the freshly-scoped
#      VEX to Dependency-Track, archiving a timestamped copy of both.
#   4. build-rauc-bundle.sh -- rebuilds the deployable A/B RAUC image + signed
#      update bundle from the same tree, in the profile's RAUC build dir, and
#      archives them
#      (skippable with SCHULTZ_BUILD_RAUC=0). This keeps the flashable SD image
#      and the OTA bundle current with every recipe/CVE change too, not just DT.#   5. pentest-scan.sh + upload-pentest.sh -- runs the pen-test/hardening tools
#      (nmap/ssh-audit/testssl/lynis/checksec/kernel-hardening-checker) and
#      pushes them, plus a mirror of DT's triaged findings, into DefectDojo (the
#      cross-tool aggregation pane). Non-fatal and OPT-IN: only runs when
#      keys/defectdojo.env (DEFECTDOJO_URL) and PENTEST_TARGET are set, and
#      never masks the primary SBOM result. Skip entirely with SCHULTZ_PENTEST=0.#
#   6. populate-nexus-mirror.sh -- pushes downloads/ into the Nexus raw mirror
#      that local.conf's SOURCE_MIRROR_URL already points at. Those were
#      configured but never populated, so they bought nothing until this step
#      existed. sstate is NOT pushed by default (SCHULTZ_MIRROR_SSTATE=1) --
#      see the note at that step for why.
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

# Which Yocto release this pipeline builds (scarthgap|wrynose) and every path
# that follows from it. See scripts/release-profile.sh.
# shellcheck disable=SC1091
source "$REPO_DIR/scripts/release-profile.sh"

# Monitor a single, stable "living SBOM" project version by default (updated in
# place each day) instead of spawning a new dated project every night. Named
# releases (YYYY.MM.PATCH) are a separate, explicit upload. Override in keys/dtrack.env.
export DTRACK_PROJECT_VERSION="${DTRACK_PROJECT_VERSION:-rolling}"

LOG_DIR="$WORK_DIR/$SCHULTZ_BUILD/security-scan-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/scan-$(date -u +%Y%m%dT%H%M%SZ).log"
exec >>"$LOG" 2>&1   # dated, greppable audit log, one per run

echo "==== [$(date -Is)] daily security scan on $(hostname) ===="
echo "release: $SCHULTZ_RELEASE  (build=$SCHULTZ_BUILD, rauc=$SCHULTZ_RAUC_BUILD)"

# One build/scan at a time -- a manual remote-build.sh must not collide with us.
exec 9>"$WORK_DIR/$SCHULTZ_BUILD_LOCK"
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

# 1b. Track the Yocto LTS branch. An LTS series gets CVE backports as point
#     releases -- without pulling them, the SBOM misses fixes already landed
#     upstream. Which layers (and which branch each must be on) comes from the
#     release profile, so this follows a cutover automatically and never pulls a
#     layer that is pinned or on another series. meta-rauc-community and
#     meta-lts-mixins carry the bootloader/A-B integration, so they move
#     deliberately with an on-hardware retest, never unattended overnight. A
#     failed pull is non-fatal: we build whatever is checked out. Set
#     SCHULTZ_UPDATE_LTS_LAYERS=0 to freeze the layers.
if [ "${SCHULTZ_UPDATE_LTS_LAYERS:-1}" = "1" ]; then
  echo "-- tracking Yocto LTS ($SCHULTZ_RELEASE) point-releases --"
  for _spec in $SCHULTZ_LTS_LAYERS; do
    _layer="${_spec%%:*}"
    _want="${_spec##*:}"
    _d="$WORK_DIR/$_layer"
    [ -d "$_d/.git" ] || continue
    _head_branch="$(git -C "$_d" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ "$_head_branch" = "$_want" ]; then
      _before="$(git -C "$_d" rev-parse --short HEAD)"
      git -C "$_d" pull --ff-only >/dev/null 2>&1 || echo "  $_layer: pull skipped/failed"
      _after="$(git -C "$_d" rev-parse --short HEAD)"
      if [ "$_before" != "$_after" ]; then echo "  $_layer: $_before -> $_after (LTS update)"; else echo "  $_layer: $_before (current)"; fi
    else
      echo "  $_layer: on '$_head_branch', expected '$_want' (pinned/detached) -- left as-is"
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

# The other two services' creds, loaded here rather than at their stages so the
# preflight below can actually test them.
for _envf in defectdojo nexus; do
  [ -f "$WORK_DIR/keys/$_envf.env" ] && { set -a; # shellcheck disable=SC1091
    source "$WORK_DIR/keys/$_envf.env"; set +a; }
done

# 1c. Preflight. A stale endpoint used to surface as connection-refused twenty
#     minutes into the build -- DefectDojo's k3s NodePort silently moved
#     30602 -> 32438 and nothing noticed until the upload stage, by which point
#     the pen-test scan had also run for nothing. Probing costs seconds and
#     decides up front which optional stages are worth running at all.
#     Note a refused connection here usually means a stale port, NOT an outage.
http_code() {
  local url="$1"; shift
  curl -sS -o /dev/null -m 8 --retry 2 --retry-delay 2 -w '%{http_code}' "$@" "$url" 2>/dev/null || echo 000
}

echo "-- preflight: endpoint reachability --"
_dt="$(http_code "${DTRACK_URL%/}/api/version")"
echo "   dependency-track  ${DTRACK_URL} -> $_dt"
if [ "$_dt" != "200" ]; then
  echo "   ABORT: Dependency-Track unreachable -- refusing to spend a build we cannot publish."
  exit 1
fi

if [ "${SCHULTZ_PENTEST:-1}" = "1" ] && [ -n "${DEFECTDOJO_URL:-}" ] && [ -n "${PENTEST_TARGET:-}" ]; then
  _dd="$(http_code "${DEFECTDOJO_URL%/}/api/v2/user_profile/" -H "Authorization: Token ${DEFECTDOJO_TOKEN:-}")"
  echo "   defectdojo        ${DEFECTDOJO_URL} -> $_dd"
  if [ "$_dd" != "200" ]; then
    case "$_dd" in
      000)     echo "   -> unreachable (stale NodePort?); skipping the pen-test stage" ;;
      401|403) echo "   -> auth rejected (stale API token?); skipping the pen-test stage" ;;
      *)       echo "   -> unexpected status; skipping the pen-test stage" ;;
    esac
    SCHULTZ_PENTEST=0
  fi
fi

if [ "${SCHULTZ_MIRROR_PUSH:-1}" = "1" ] && [ -n "${NEXUS_URL:-}" ]; then
  _nx="$(http_code "${NEXUS_URL%/}/service/rest/v1/status")"
  echo "   nexus             ${NEXUS_URL} -> $_nx"
  if [ "$_nx" != "200" ]; then
    echo "   -> unreachable; skipping the mirror push (builds are unaffected, fetches just go upstream)"
    SCHULTZ_MIRROR_PUSH=0
  fi
fi

# 2. Refresh the CVE data + regenerate the SBOM/VEX inputs. oe-init-build-env
#    is not set -u safe, so relax strict mode just for sourcing it.
#    The init script and build dir BOTH come from the release profile -- pairing
#    one release's oe-init-build-env with another's build dir is what broke the
#    nightly cron on 2026-08-29 ("Could not include required file
#    conf/multiconfig/.conf"), so they must never be set independently.
set +u
# shellcheck disable=SC1091
source "$SCHULTZ_OE_INIT" "$SCHULTZ_BUILD"
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

# 5. Optional pen-test + hardening scan -> DefectDojo (the aggregation pane).
#    Opt-in and non-fatal, same discipline as the RAUC step: it only runs when
#    DefectDojo creds (keys/defectdojo.env) and a scan target (PENTEST_TARGET,
#    usually the device IP) are present, and a failure here is surfaced but
#    never masks the SBOM/VEX result, which is the primary job of this run.
pentest_rc=0
if [ "${SCHULTZ_PENTEST:-1}" = "1" ] && [ -n "${DEFECTDOJO_URL:-}" ] && [ -n "${PENTEST_TARGET:-}" ]; then
  echo "-- pentest-scan.sh + upload-pentest.sh (DefectDojo) --"
  export PENTEST_ARCHIVE_DIR="${PENTEST_ARCHIVE_DIR:-$WORK_DIR/build/pentest-archive}"
  "$REPO_DIR/scripts/pentest-scan.sh" || echo "pentest-scan reported an error (non-fatal)"
  "$REPO_DIR/scripts/upload-pentest.sh"
  pentest_rc=$?
  echo "pentest upload rc=$pentest_rc"
elif [ "${SCHULTZ_PENTEST:-1}" = "1" ]; then
  echo "-- pentest stage skipped: needs keys/defectdojo.env (DEFECTDOJO_URL) + PENTEST_TARGET --"
fi

# 6. Fill the Nexus source mirror from the caches this run just refreshed, so a
#    fresh build host -- or this one after a tmp/ wipe -- can restore from the LAN
#    instead of re-fetching the internet. Runs last and is deliberately excluded
#    from the exit code: a full mirror is a convenience, a current SBOM is the job.
#
#    SSTATE IS NOT PUSHED BY DEFAULT. Sources and sstate hold different things and
#    are worth mirroring for different reasons: upstream tarballs genuinely
#    disappear, so mirroring them is a reproducibility guarantee that cannot be
#    reconstructed later; sstate is derived data that can always be rebuilt from
#    those sources. With a single build host, SSTATE_DIR serves every hit locally
#    and the Nexus copy only adds disaster recovery -- for 24.6G against 18.0G,
#    which is what overflowed the blob store on 2026-08-30. Set
#    SCHULTZ_MIRROR_SSTATE=1 to push it anyway (check the blob store has room).
mirror_rc=0
if [ "${SCHULTZ_MIRROR_PUSH:-1}" = "1" ] && [ -f "$WORK_DIR/keys/nexus.env" ]; then
  if [ "${SCHULTZ_MIRROR_SSTATE:-0}" = "1" ]; then
    echo "-- populate-nexus-mirror.sh (downloads + sstate -> Nexus) --"
    "$REPO_DIR/scripts/populate-nexus-mirror.sh" || mirror_rc=$?
  else
    echo "-- populate-nexus-mirror.sh (sources -> Nexus; sstate skipped) --"
    "$REPO_DIR/scripts/populate-nexus-mirror.sh" --sources || mirror_rc=$?
  fi
  echo "mirror push rc=$mirror_rc"
fi

echo "==== [$(date -Is)] finished (upload rc=$rc, rauc rc=$rauc_rc, pentest rc=$pentest_rc, mirror rc=$mirror_rc) ===="
# Surface any failure; the SBOM/VEX security upload takes priority over the rest.
if [ "$rc" -ne 0 ]; then exit "$rc"; fi
if [ "$rauc_rc" -ne 0 ]; then exit "$rauc_rc"; fi
exit "$pentest_rc"
