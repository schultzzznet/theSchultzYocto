#!/usr/bin/env bash
# Unattended build of the A/B RAUC image + signed update bundle for
# raspberrypi3-64, in the SEPARATE build-rauc/ dir (it never touches build/,
# which the daily security scan and the simple single-partition image use).
#
# Safe to run from cron OR by hand. The daily security scan chains it as its
# final stage (scripts/daily-security-scan.sh), so the deployable image + signed
# bundle refresh themselves every night from the same freshly-pulled tree --
# "it happens by itself".
#
# What it does:
#   1. Ensure build-rauc/ exists (scripts/setup-rauc-build.sh, idempotent).
#   2. bitbake schultz-image-minimal  -> the 5-partition A/B .wic.bz2 (+ .bmap)
#   3. bitbake schultz-bundle         -> a signed, verity .raucb update bundle
#   4. Verify the bundle (rauc info): the inline signature must validate against
#      our dev keyring AND a Compatible string must be present -- an on-device
#      `rauc install` refuses a bundle whose Compatible != the running system's,
#      so a broken one here would silently become an un-installable update.
#   5. Archive .wic.bz2 / .wic.bmap / .raucb under a UTC timestamp, refresh the
#      stable latest.* symlinks, and prune to the newest RAUC_ARCHIVE_KEEP sets.
#
# Env (all optional):
#   RAUC_ARCHIVE_KEEP        how many timestamped sets to keep (default 5)
#   RAUC_ARCHIVE_DIR         archive location (default build-rauc/rauc-archive)
#   SCHULTZ_BUILD_LOCK_HELD  set to 1 by the daily scan, which already holds the
#                            shared heavy-build lock for the whole run, so we
#                            neither re-lock (deadlock) nor redirect its log.
#
# Exit: 0 = ok; non-zero = setup/build/verify failure (logged).

set -uo pipefail

# cron hands us a near-empty environment. Yocto refuses to build without a
# UTF-8 locale, and bitbake needs a sane PATH and HOME.
export HOME="${HOME:-/home/$(id -un)}"
export LC_ALL="${LC_ALL:-C.UTF-8}" LANG="${LANG:-C.UTF-8}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"
cd "$WORK_DIR"

# shellcheck disable=SC1091
source "$REPO_DIR/scripts/release-profile.sh"

MACHINE="${SCHULTZ_MACHINE:-raspberrypi3-64}"
export MACHINE
IMAGE="schultz-image-minimal"
BUNDLE="schultz-bundle"
RB="$SCHULTZ_RAUC_BUILD"
IMAGES_DIR="$WORK_DIR/$RB/tmp/deploy/images/$MACHINE"
ARCHIVE_DIR="${RAUC_ARCHIVE_DIR:-$WORK_DIR/$RB/rauc-archive}"
KEEP="${RAUC_ARCHIVE_KEEP:-5}"
CHAINED="${SCHULTZ_BUILD_LOCK_HELD:-0}"

# Standalone: write a dated, greppable log and keep the last 30. When chained,
# inherit the scan's stdout so everything lands in that one run's log instead.
if [ "$CHAINED" != "1" ]; then
  LOG_DIR="$WORK_DIR/$RB/rauc-build-logs"
  mkdir -p "$LOG_DIR"
  LOG="$LOG_DIR/rauc-$(date -u +%Y%m%dT%H%M%SZ).log"
  exec >>"$LOG" 2>&1
  ls -1t "$LOG_DIR"/rauc-*.log 2>/dev/null | tail -n +31 | xargs -r rm -f
fi

echo "==== [$(date -Is)] RAUC image+bundle build on $(hostname) ===="
echo "release: $SCHULTZ_RELEASE  (rauc build dir: $RB)"

# Serialize against the daily security scan and any other heavy build: they both
# coordinate on this one lock so a 4-core host never runs two full bitbakes at
# once. When chained, the scan already holds it -- re-acquiring here (a new fd to
# the same file) would block forever, so we skip. Standalone, we grab it
# non-blockingly and bow out if a scan/build is already running.
if [ "$CHAINED" != "1" ]; then
  exec 8>"$WORK_DIR/$SCHULTZ_BUILD_LOCK"
  if ! flock -n 8; then
    echo "another scan/build holds the lock -- skipping this RAUC run"
    exit 0
  fi
fi

# 1. First-time setup (idempotent). A fast no-op once the RAUC build dir exists.
if [ ! -f "$WORK_DIR/$RB/conf/local.conf" ]; then
  echo "-- $RB not initialised; running setup-rauc-build.sh --"
  "$REPO_DIR/scripts/setup-rauc-build.sh"
fi

# 2/3. Build the A/B image, then the bundle. oe-init-build-env is not set -u
#      safe, so relax strict mode just for sourcing it.
set +u
# shellcheck disable=SC1091
source "$SCHULTZ_OE_INIT" "$RB"
set -u

echo "-- bitbake $IMAGE --"
if ! bitbake "$IMAGE"; then
  echo "A/B image build FAILED -- not archiving"
  exit 1
fi
echo "-- bitbake $BUNDLE --"
if ! bitbake "$BUNDLE"; then
  echo "bundle build FAILED -- not archiving"
  exit 1
fi

# The disk image may be gzip- or bzip2-compressed (or raw) depending on
# IMAGE_FSTYPES; prefer wic.gz because it flashes far faster than wic.bz2.
WIC="" WIC_EXT=""
for ext in wic.gz wic.bz2 wic; do
  if [ -f "$IMAGES_DIR/${IMAGE}-${MACHINE}.rootfs.$ext" ]; then
    WIC="$IMAGES_DIR/${IMAGE}-${MACHINE}.rootfs.$ext"; WIC_EXT="$ext"; break
  fi
done
BMAP="$IMAGES_DIR/${IMAGE}-${MACHINE}.rootfs.wic.bmap"
RAUCB="$IMAGES_DIR/${BUNDLE}-${MACHINE}.raucb"

if [ ! -f "$RAUCB" ]; then
  echo "expected bundle not found at $RAUCB -- build produced no .raucb" >&2
  exit 1
fi

# 4. Verify: signature must validate against our dev keyring, and rauc must be
#    able to read the Compatible string (printed for the audit log).
#    Prefer a recipe-sysroot-native copy and run it with that sysroot's libs:
#    the bare sysroots-components binary resolves the HOST's glib, and wrynose's
#    rauc needs glib 2.88 symbols (g_unix_mount_entry_free) that Ubuntu 24.04
#    does not have -- it then dies with "symbol lookup error" before ever
#    looking at the signature.
RAUC_NATIVE="$(find "$WORK_DIR/$RB/tmp/work" -path '*/recipe-sysroot-native/usr/bin/rauc' -type f 2>/dev/null | head -1)"
[ -n "$RAUC_NATIVE" ] || RAUC_NATIVE="$(find "$WORK_DIR/$RB/tmp" -path '*rauc-native*/usr/bin/rauc' -type f 2>/dev/null | head -1)"
RAUC_LIB="$(dirname "$(dirname "$RAUC_NATIVE")")/lib"
CERT="$(find "$REPO_DIR" -name 'development-1.cert.pem' 2>/dev/null | head -1)"
if [ -x "$RAUC_NATIVE" ] && [ -n "$CERT" ]; then
  echo "-- rauc info (verify signature + compatible) --"
  # Separate "the tool could not run" from "the signature is bad": reporting a
  # broken toolchain as a signature failure would hide a real one.
  if ! LD_LIBRARY_PATH="$RAUC_LIB" "$RAUC_NATIVE" --version >/dev/null 2>&1; then
    echo "WARN: rauc-native at $RAUC_NATIVE cannot execute -- bundle NOT verified" >&2
    LD_LIBRARY_PATH="$RAUC_LIB" "$RAUC_NATIVE" --version 2>&1 | head -2 >&2
    exit 1
  fi
  if ! LD_LIBRARY_PATH="$RAUC_LIB" "$RAUC_NATIVE" info --keyring="$CERT" "$RAUCB"; then
    echo "bundle verification FAILED (bad signature or wrong keyring)" >&2
    exit 1
  fi
else
  echo "WARN: cannot verify bundle (rauc-native or dev cert not found) -- continuing"
fi

# 5. Archive under a UTC timestamp, refresh latest.* symlinks, prune to $KEEP.
mkdir -p "$ARCHIVE_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
archive_one() {  # archive_one <src> <ext>
  if [ ! -f "$1" ]; then echo "WARN: missing $1 -- not archived"; return 0; fi
  cp -f "$1" "$ARCHIVE_DIR/schultz-rauc-$TS.$2"       # cp dereferences the symlink
  ln -sfn "schultz-rauc-$TS.$2" "$ARCHIVE_DIR/latest.$2"
}
if [ -n "$WIC" ]; then archive_one "$WIC" "$WIC_EXT"; else echo "WARN: no .wic image found to archive"; fi
archive_one "$BMAP"  "wic.bmap"
archive_one "$RAUCB" "raucb"
echo "archived $TS -> $ARCHIVE_DIR (latest.${WIC_EXT:-wic.gz} / latest.wic.bmap / latest.raucb)"

# Prune each artifact type to the newest $KEEP (latest.* symlinks are named
# differently, so this never removes them).
for ext in wic.gz wic.bz2 wic wic.bmap raucb; do
  ls -1t "$ARCHIVE_DIR"/schultz-rauc-*."$ext" 2>/dev/null | tail -n +"$((KEEP + 1))" | xargs -r rm -f
done

echo "==== [$(date -Is)] RAUC build finished OK ===="
