#!/usr/bin/env bash
# Repair git worktrees left pointing at a DL_DIR that has since moved.
#
# WHY THIS EXISTS. Moving DL_DIR (we consolidated four per-build-dir
# `downloads/` into one shared `~/yocto-downloads` on 2026-08-30) is safe for
# FUTURE unpacks -- DL_DIR is in BB_BASEHASH_IGNORE_VARS, so no sstate is
# invalidated. But it does NOT retroactively fix worktrees that were ALREADY
# unpacked: git records the mirror clone as a plain absolute path in
#   <worktree>/.git/objects/info/alternates
# and never re-resolves it. Those worktrees keep pointing at a directory that
# no longer exists.
#
# The failure is delayed and misleading. Normal builds sstate-restore the
# affected tasks and never touch git, so this sat dormant for two weeks. It
# only surfaced on `do_validate_branches` (a kernel task that really does read
# git history):
#   error: unable to normalize alternate object path: .../downloads/git2/...
#   ERROR: <sha> is not a valid commit ID
#   ERROR: The kernel source tree may be out of sync
# which reads like a corrupt kernel checkout, not a stale path.
#
# TWO PLACES ARE EASY TO MISS:
#   - submodules keep theirs under .git/modules/<name>/objects/info/alternates
#   - kernel recipes share ONE checkout in tmp/work-shared/<machine>/kernel-source,
#     a sibling of tmp/work -- searching only tmp/work finds 108 files and still
#     misses the one that actually breaks the kernel build.
# So this scans the whole of tmp/.
#
# Idempotent and safe to re-run: it only rewrites files that contain a stale
# path, and rewriting alternates changes no build output (it is a pointer, not
# content -- the objects themselves live in the mirror clone).
#
# Usage:
#   ./scripts/fix-git-alternates.sh            # fix the active release's build dirs
#   ./scripts/fix-git-alternates.sh --dry-run  # report only, change nothing
#   ./scripts/fix-git-alternates.sh --all      # every known build dir, both releases

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"
# shellcheck disable=SC1091
source "$REPO_DIR/scripts/release-profile.sh"

DRY_RUN=0
ALL=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --all)     ALL=1 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

if [ "$ALL" = 1 ]; then
  BUILD_DIRS="build build-rauc build-wrynose build-rauc-wrynose"
else
  BUILD_DIRS="$SCHULTZ_BUILD $SCHULTZ_RAUC_BUILD"
fi

# The canonical location every stale path should now point at.
GOOD_DL="$WORK_DIR/$SCHULTZ_DL_DIR"

total=0 stale=0 fixed=0
for d in $BUILD_DIRS; do
  TMP="$WORK_DIR/$d/tmp"
  [ -d "$TMP" ] || { echo "  skip $d (no tmp/)"; continue; }
  echo "==> scanning $d/tmp"

  while IFS= read -r f; do
    total=$((total + 1))
    # Any downloads/git2 path that is NOT already the shared one is stale.
    line="$(cat "$f" 2>/dev/null || true)"
    case "$line" in
      "$GOOD_DL"/git2/*) continue ;;
      */downloads/git2/*) ;;
      *) continue ;;
    esac
    stale=$((stale + 1))
    echo "    stale: $f"
    echo "           -> $line"
    if [ "$DRY_RUN" = 0 ]; then
      # Rewrite whatever <something>/downloads/git2 prefix it has to the shared one.
      sed -i -E "s#^.*/downloads/git2/#${GOOD_DL}/git2/#" "$f"
      fixed=$((fixed + 1))
    fi
  done < <(find "$TMP" -path "*/objects/info/alternates" -type f 2>/dev/null)
done

echo
if [ "$DRY_RUN" = 1 ]; then
  echo "dry-run: $stale stale of $total alternates file(s) -- nothing changed"
  [ "$stale" -eq 0 ] || exit 1
else
  echo "checked $total alternates file(s); rewrote $fixed"
fi
