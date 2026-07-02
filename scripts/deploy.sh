#!/usr/bin/env bash
# One command from the Mac: sync this repo to the build host via git (no
# scp/rsync), then kick off (or resume) the remote build.
#
# Usage: ./scripts/deploy.sh [host]

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:-rpi5g16nvme}"

"$DIR/scripts/sync-to-host.sh" "$HOST"
ssh "$HOST" "cd theSchultzYocto && ./scripts/remote-build.sh"
