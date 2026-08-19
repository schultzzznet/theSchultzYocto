#!/usr/bin/env bash
# Verify that what is RUNNING on hardware has an SBOM in Dependency-Track.
#
# WHY THIS EXISTS (2026-08-19). The whole SBOM chain describes an artifact that
# was BUILT. Nothing checked that the artifact is the one actually DEPLOYED, and
# the first time anyone looked, it wasn't: raspberrypi3-64 reports
# IMAGE_VERSION=2026.07.1, while Dependency-Track held only `rolling` and a
# nameless `build-20260730T054210Z` snapshot. The firmware on real hardware had
# no SBOM of its own -- so "0 criticals in DT" was a statement about something
# nobody was running.
#
# The versioning scheme is already right and needed no change:
#   RAUC_BUNDLE_VERSION (recipes-core/images/schultz-bundle.bb)  <- source of truth
#   IMAGE_VERSION       (recipes-core/os-release/os-release.bbappend)
#   DTRACK_PROJECT_VERSION (exported by cut-release.sh as "$VERSION")
# all carry the SAME CalVer. cut-release.sh even warns when the first two drift.
# The gap was that nothing ever asserted the third one exists for a version that
# is genuinely on a device -- i.e. that `cut-release.sh --publish` was actually
# run for the release someone flashed. It is the repo's recurring shape:
# mechanism correct, complete, and never exercised.
#
# WHY NOT TRIVY. A Poky image carries no package manager database at all
# (verified on the device: dpkg, rpm, opkg and apk are all absent, BusyBox
# userland). `trivy rootfs --pkg-types os` would return zero findings and file a
# green, freshly-timestamped engagement that inspected nothing -- worse than no
# scan, because it looks like coverage. Yocto's coverage is the build-time SBOM;
# this script checks that the build-time SBOM corresponds to reality.
#
# BOTH A/B SLOTS ARE CHECKED. The inactive RAUC slot is a bootable image: one
# `rauc status --mark-active` or a failed boot away from being what runs. An
# untracked inactive slot is the same defect as an untracked retained kernel --
# invisible until it is suddenly the thing you are running.
#
# Exit 0 = every deployed image version has a matching DT project version.
# Exit 1 = at least one does not (this is the state today, deliberately).
#
# Usage:
#   scripts/verify-deployed-sbom.sh [device ...]      # default: 192.168.1.226
#   DTRACK_URL=... DTRACK_API_KEY=... scripts/verify-deployed-sbom.sh
#
# Creds come from keys/dtrack.env + keys/dtrack-api-key, exactly as
# cut-release.sh loads them.
#
# NOTE ON SSH: same options as ota-deploy.sh -- the devices are root/empty-pw
# appliances whose host keys change on every reflash, so UserKnownHostsFile is
# /dev/null on purpose. Set SSH_JUMP=<host> to reach them through a jump box
# (e.g. SSH_JUMP=rpi5g16nvme when the workstation has no direct route).

set -uo pipefail

DEVICES=("$@")
[ ${#DEVICES[@]} -gt 0 ] || DEVICES=(192.168.1.226)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"

# shellcheck disable=SC1091  # keys/dtrack.env is a gitignored sibling, as in cut-release.sh
[ -f "$WORK_DIR/keys/dtrack.env" ] && { set -a; . "$WORK_DIR/keys/dtrack.env"; set +a; }
[ -z "${DTRACK_API_KEY:-}" ] && [ -f "$WORK_DIR/keys/dtrack-api-key" ] && \
  DTRACK_API_KEY="$(tr -d '\r\n ' < "$WORK_DIR/keys/dtrack-api-key")"

: "${DTRACK_URL:?Set DTRACK_URL (or provide keys/dtrack.env)}"
: "${DTRACK_API_KEY:?Set DTRACK_API_KEY (or provide keys/dtrack-api-key)}"
PROJECT_NAME="${DTRACK_PROJECT_NAME:-theSchultzYocto}"

SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
[ -n "${SSH_JUMP:-}" ] && SSH+=(-J "$SSH_JUMP")

# --- what versions does DT know about? -------------------------------------
# A trailing newline in the API key makes DT answer 400 with an empty body, so
# the key is stripped above -- see /memories/dtrack-api-key-newline.md.
dt_versions() {
  curl -sS --max-time 30 -H "X-Api-Key: $DTRACK_API_KEY" \
    "${DTRACK_URL%/}/api/v1/project?pageSize=200&pageNumber=1" \
  | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(3)
for p in d:
    if p.get('name')=='$PROJECT_NAME' and p.get('version'):
        print(p['version'])"
}

KNOWN="$(dt_versions)" || { echo "FATAL: could not read projects from $DTRACK_URL" >&2; exit 2; }
if [ -z "$KNOWN" ]; then
  echo "FATAL: DT has no project named '$PROJECT_NAME' at all" >&2
  exit 2
fi
echo "Dependency-Track knows these '$PROJECT_NAME' versions:"
printf '%s\n' "$KNOWN" | sed 's/^/  /'
echo

# --- what is actually on each device? ---------------------------------------
# Reads the booted slot from /etc/os-release, then mounts the INACTIVE slot
# read-only to read its os-release too. The inactive partition is discovered
# from `rauc status` rather than hard-coded, so this survives a layout change.
probe_device() { # $1 = host; prints "slot<TAB>version" lines
  # shellcheck disable=SC2016  # single quotes are deliberate: this runs on the DEVICE
  "${SSH[@]}" "root@$1" '
    booted_ver="$(sed -n "s/^IMAGE_VERSION=//p" /etc/os-release)"
    booted_slot="$(rauc status 2>/dev/null | sed -n "s/^Booted from:[[:space:]]*//p")"
    printf "booted(%s)\t%s\n" "${booted_slot:-unknown}" "${booted_ver:-UNKNOWN}"

    # BusyBox head on this image rejects the one-dash shorthand (head -1) with an
    # invalid-option error and silently yields NOTHING, which made this whole
    # branch report UNREADABLE forever. Always head -n 1 in device-side snippets.
    inactive_dev="$(rauc status 2>/dev/null | grep inactive | head -n 1 | sed "s/.*(\([^,]*\),.*/\1/")"
    if [ -n "$inactive_dev" ] && mkdir -p /tmp/_slotchk && mount -o ro "$inactive_dev" /tmp/_slotchk 2>/dev/null; then
      inactive_ver="$(sed -n "s/^IMAGE_VERSION=//p" /tmp/_slotchk/etc/os-release 2>/dev/null)"
      umount /tmp/_slotchk 2>/dev/null
      printf "inactive(%s)\t%s\n" "$inactive_dev" "${inactive_ver:-UNKNOWN}"
    else
      printf "inactive(%s)\tUNREADABLE\n" "${inactive_dev:-none}"
    fi
  ' 2>/dev/null
}

RC=0
for dev in "${DEVICES[@]}"; do
  echo "=== $dev ==="
  OUT="$(probe_device "$dev")"
  if [ -z "$OUT" ]; then
    echo "  UNREACHABLE over ssh -- cannot verify (treated as failure)"
    RC=1
    continue
  fi
  while IFS="$(printf '\t')" read -r slot ver; do
    [ -n "$slot" ] || continue
    if [ "$ver" = "UNKNOWN" ] || [ "$ver" = "UNREADABLE" ]; then
      echo "  $slot -> $ver  (cannot establish what this slot holds)"
      RC=1
    elif printf '%s\n' "$KNOWN" | grep -qxF "$ver"; then
      echo "  $slot -> $ver  OK (SBOM present in DT)"
    else
      echo "  $slot -> $ver  NO SBOM IN DEPENDENCY-TRACK"
      RC=1
    fi
  done <<< "$OUT"
  echo
done

if [ "$RC" -ne 0 ]; then
  cat >&2 <<'EOF'
FAIL: at least one deployed image version has no SBOM in Dependency-Track.
      Whatever DT reports about this firmware describes something else.
      Fix by cutting/publishing that version so its SBOM is uploaded under it:
        scripts/cut-release.sh            # exports DTRACK_PROJECT_VERSION="$VERSION"
      or, for an already-built image, re-run upload-sbom.sh with the version set:
        DTRACK_PROJECT_VERSION=<CalVer> SCHULTZ_BUILD_SUBDIR=build-rauc \
          scripts/upload-sbom.sh
EOF
  exit 1
fi
echo "OK: every deployed image version has a matching SBOM in Dependency-Track."
