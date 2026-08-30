#!/usr/bin/env bash
# Push this build host's caches INTO the Nexus raw mirrors that local.conf
# already points at.
#
# setup-nexus-mirror.sh (run on the Mac) only *creates* the repos. Nothing was
# ever filling them, so SOURCE_MIRROR_URL / SSTATE_MIRRORS pointed at two empty
# buckets: every fetch 404'd past Nexus straight to upstream, and the
# "upstream deleted the tag" resilience those variables are supposed to buy was
# exactly zero. This script is the missing half.
#
# Run it ON THE BUILD HOST (that is where downloads/ and sstate-cache/ live).
# The nightly (daily-security-scan.sh) calls it after each successful build, so
# the mirror tracks whatever the image currently needs.
#
# Usage:
#   ./scripts/populate-nexus-mirror.sh              # sources + sstate
#   ./scripts/populate-nexus-mirror.sh --sources    # DL_DIR only
#   ./scripts/populate-nexus-mirror.sh --sstate     # sstate-cache only
#   ./scripts/populate-nexus-mirror.sh --dry-run    # count + bytes, upload nothing
#
# Credentials: keys/nexus.env (gitignored sibling of the repo, the same file
# cut-release.sh already uses) holding NEXUS_URL / NEXUS_WRITE_USER /
# NEXUS_WRITE_PASS. Anonymous read is already on for these repos -- only
# writing needs auth.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"
# shellcheck disable=SC1091
source "$REPO_DIR/scripts/release-profile.sh"

if [ -f "$WORK_DIR/keys/nexus.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$WORK_DIR/keys/nexus.env"
  set +a
fi

NEXUS_URL="${NEXUS_URL:-http://MacStudioM2Max12.local:8081}"
NEXUS_WRITE_USER="${NEXUS_WRITE_USER:-}"
NEXUS_WRITE_PASS="${NEXUS_WRITE_PASS:-}"
# Deliberately NOT NEXUS_REPO -- keys/nexus.env already defines that as the
# release-bundle repo for cut-release.sh, and reusing it would publish sstate
# into the OTA feed.
SOURCES_REPO="${SOURCES_REPO:-yocto-sources-raw}"
SSTATE_REPO="${SSTATE_REPO:-yocto-sstate-raw}"

BUILD_DIR="${BUILD_DIR:-$WORK_DIR/$SCHULTZ_BUILD}"
DL_DIR="${DL_DIR:-$BUILD_DIR/downloads}"
SSTATE_DIR="${SSTATE_DIR:-$BUILD_DIR/sstate-cache}"
JOBS="${JOBS:-4}"

DO_SOURCES=1 DO_SSTATE=1 DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sources) DO_SSTATE=0 ;;
    --sstate)  DO_SOURCES=0 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# ── credentials ──────────────────────────────────────────────────────────────
# Via a 0600 netrc, not `curl -u user:pass`: command lines are world-readable in
# ps output, and this script is run from cron on a multi-process host.
NETRC=""
if [ "$DRY_RUN" -eq 0 ]; then
  if [ -z "$NEXUS_WRITE_USER" ] || [ -z "$NEXUS_WRITE_PASS" ]; then
    echo "no Nexus write creds (keys/nexus.env: NEXUS_WRITE_USER/NEXUS_WRITE_PASS) -- skipping." >&2
    exit 0
  fi
  NETRC="$(mktemp)"
  chmod 600 "$NETRC"
  trap 'rm -f "$NETRC"' EXIT
  _host="${NEXUS_URL#*://}"; _host="${_host%%[:/]*}"
  printf 'machine %s login %s password %s\n' \
    "$_host" "$NEXUS_WRITE_USER" "$NEXUS_WRITE_PASS" > "$NETRC"
fi

# ── backfill: make the git clones mirrorable at all ──────────────────────────
# bitbake only packs a clone into its mirror tarball when do_fetch actually
# runs. Clones fetched before BB_GENERATE_MIRROR_TARBALLS was turned on
# (2026-08-12) therefore have no tarball and would stay unmirrorable until
# their recipe happens to change -- and forcing do_fetch is not a cheap fix:
# measured, it re-runs unpack/patch/configure/compile for that recipe (+19
# tasks on e2fsprogs), which for linux-raspberrypi means a full kernel rebuild.
# So pack them exactly the way bitbake does instead; verified against
# poky/bitbake/lib/bb/fetch2/git.py, GitFetcher.download(). New fetches from
# here on are packed by bitbake itself and skip this loop.
backfill_git_tarballs() {
  local clone name tarball mtime made=0
  [ -d "$DL_DIR/git2" ] || return 0
  for clone in "$DL_DIR"/git2/*/; do
    [ -d "$clone" ] || continue
    name="$(basename "$clone")"
    tarball="$DL_DIR/git2_${name}.tar.gz"
    [ -e "$tarball" ] && continue
    if [ "$DRY_RUN" -eq 1 ]; then echo "  would pack $name"; made=$((made + 1)); continue; fi
    mtime="$(git -C "$clone" log --all -1 --format=%cD 2>/dev/null || true)"
    [ -n "$mtime" ] || mtime="@0"   # empty clone: keep the tarball reproducible anyway
    echo "  packing $name"
    if tar -czf "$tarball.tmp" --owner oe:0 --group oe:0 --mtime "$mtime" -C "$clone" .; then
      mv "$tarball.tmp" "$tarball"
      touch "$tarball.done"
      made=$((made + 1))
    else
      echo "  WARNING: could not pack $name -- skipping" >&2
      rm -f "$tarball.tmp"
    fi
  done
  echo "  git mirror tarballs created: $made"
}

# ── upload ───────────────────────────────────────────────────────────────────
# One file, addressed by its path relative to MIRROR_BASE -- which is exactly
# the layout both BitBake variables expect (flat filenames under
# SOURCE_MIRROR_URL, hash-split subdirs for the SSTATE_MIRRORS PATH token).
# shellcheck disable=SC2329  # invoked indirectly by xargs via `export -f`
_put() {
  local rel="$1" url code
  url="$MIRROR_URL/repository/$MIRROR_REPO/$rel"
  # HEAD first: without it every nightly re-PUTs gigabytes that are already there.
  code="$(curl -sS --netrc-file "$MIRROR_NETRC" -o /dev/null -w '%{http_code}' -I "$url" || echo 000)"
  [ "$code" = "200" ] && return 0
  # curl exits 0 on a 401/403/400 unless asked otherwise, so check the code, not $?.
  code="$(curl -sS --netrc-file "$MIRROR_NETRC" --retry 3 --retry-connrefused \
            -o /dev/null -w '%{http_code}' --upload-file "$MIRROR_BASE/$rel" "$url" || echo 000)"
  case "$code" in
    2*) return 0 ;;
    *)  echo "  FAILED HTTP $code: $rel" >&2; return 1 ;;
  esac
}
export -f _put

mirror_tree() {
  local base="$1" repo="$2" label="$3"; shift 3
  if [ ! -d "$base" ]; then
    echo "==> $label: $base does not exist -- skipping."
    return 0
  fi

  local list count bytes rc=0
  list="$(mktemp)"
  (cd "$base" && find . "$@" -printf '%P\n') | LC_ALL=C sort > "$list"
  count="$(wc -l < "$list")"
  bytes="$( (cd "$base" && tr '\n' '\0' < "$list" | du -ch --files0-from=- 2>/dev/null | tail -1 | cut -f1) || echo '?')"
  echo "==> $label: $count candidate files ($bytes on disk) -> $repo"

  if [ "$DRY_RUN" -eq 1 ]; then rm -f "$list"; return 0; fi

  MIRROR_BASE="$base" MIRROR_REPO="$repo" MIRROR_URL="$NEXUS_URL" MIRROR_NETRC="$NETRC" \
    xargs -a "$list" -r -d '\n' -P "$JOBS" -n 1 \
      bash -c '_put "$1"' _ || rc=$?   # shellcheck disable=SC2016 -- runs in the child shell
  rm -f "$list"
  if [ "$rc" -eq 0 ]; then
    echo "    $label done."
  else
    echo "    $label finished with failures (xargs rc=$rc)" >&2
  fi
  return "$rc"
}

echo "==== [$(date -Is)] populate Nexus mirror -> $NEXUS_URL ===="
rc=0

if [ "$DO_SOURCES" -eq 1 ]; then
  echo "==> backfilling git mirror tarballs in $DL_DIR"
  backfill_git_tarballs
  # maxdepth 1: the flat files only. The git2/ clone dirs are represented by the
  # git2_*.tar.gz above, and .done/.lock are local bookkeeping, not artifacts.
  mirror_tree "$DL_DIR" "$SOURCES_REPO" "sources" \
    -maxdepth 1 -type f ! -name '*.done' ! -name '*.lock' ! -name '*.tmp' || rc=$?
fi

if [ "$DO_SSTATE" -eq 1 ]; then
  # .siginfo files are deliberately left out: they roughly double the file count
  # and are only needed for bitbake-diffsigs forensics, not for cache restores.
  mirror_tree "$SSTATE_DIR" "$SSTATE_REPO" "sstate" \
    -type f -name '*.tar.zst' || rc=$?
fi

echo "==== [$(date -Is)] finished (rc=$rc) ===="
exit "$rc"
