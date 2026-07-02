#!/usr/bin/env bash
# Syncs this repo to a build host using git -- NOT scp/rsync. Pushes over
# ssh (git's own smart transport) to a plain repo on the host configured
# with receive.denyCurrentBranch=updateInstead, so its working tree updates
# automatically on every push. Safe to re-run any time you have local
# changes to send over.
#
# Usage: ./scripts/sync-to-host.sh [host] [remote-dir-name]
#   host defaults to "rpi5g16nvme".
#   remote-dir-name defaults to "theSchultzYocto" (relative to the remote
#   user's home directory).

set -euo pipefail

HOST="${1:-rpi5g16nvme}"
REMOTE_DIR="${2:-theSchultzYocto}"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
REMOTE_NAME="pi-sync-tmp"

# One-time (idempotent) remote repo setup: a plain (non-bare) repo whose
# working tree gets updated in place on every push.
ssh "$HOST" "set -e
if [ ! -d '$REMOTE_DIR/.git' ]; then
  mkdir -p '$REMOTE_DIR'
  git init -q -b '$BRANCH' '$REMOTE_DIR'
fi
git -C '$REMOTE_DIR' config receive.denyCurrentBranch updateInstead"

# 'host:path' below is git's own scp-like remote URL syntax -- it invokes
# git-receive-pack over ssh. This is NOT the scp binary; no file-copy tool
# is involved anywhere in this script.
git remote remove "$REMOTE_NAME" 2>/dev/null || true
git remote add "$REMOTE_NAME" "${HOST}:${REMOTE_DIR}"
git push "$REMOTE_NAME" "${BRANCH}:${BRANCH}"
git remote remove "$REMOTE_NAME"

echo "Synced to ${HOST}:${REMOTE_DIR} (branch ${BRANCH})"
