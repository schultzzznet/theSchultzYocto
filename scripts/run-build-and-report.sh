#!/usr/bin/env bash
# Runs the actual bitbake build, then uploads the SBOM to Dependency-Track
# if DTRACK_URL/DTRACK_API_KEY are set in the environment. Meant to be
# launched detached by remote-build.sh -- not usually run directly.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bitbake schultz-image-minimal
ret=$?

if [ "$ret" -eq 0 ] && [ -n "${DTRACK_URL:-}" ]; then
  "$REPO_DIR/scripts/upload-sbom.sh" || echo "SBOM upload failed (build itself succeeded, see above)"
fi

exit "$ret"
