#!/usr/bin/env bash
# Uploads the built image's SPDX SBOM (generated automatically by Yocto's
# create-spdx class) to a Dependency-Track instance. Run on the build host,
# after a successful build of schultz-image-minimal.
#
# Required environment variables:
#   DTRACK_URL       e.g. https://dtrack.example.com
#   DTRACK_API_KEY   API key for a team with BOM_UPLOAD permission
# Optional:
#   DTRACK_PROJECT_NAME     default: schultz-image-minimal
#   DTRACK_PROJECT_VERSION  default: raspberrypi3-64-<today's date>
#
# Usage: DTRACK_URL=... DTRACK_API_KEY=... ./scripts/upload-sbom.sh

set -euo pipefail

: "${DTRACK_URL:?Set DTRACK_URL, e.g. https://dtrack.example.com}"
: "${DTRACK_API_KEY:?Set DTRACK_API_KEY}"

PROJECT_NAME="${DTRACK_PROJECT_NAME:-schultz-image-minimal}"
PROJECT_VERSION="${DTRACK_PROJECT_VERSION:-raspberrypi3-64-$(date +%Y%m%d)}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"
SBOM="$WORK_DIR/build/tmp/deploy/images/raspberrypi3-64/schultz-image-minimal-raspberrypi3-64.spdx.json"

if [ ! -f "$SBOM" ]; then
  echo "No SBOM at $SBOM -- build schultz-image-minimal first (create-spdx" >&2
  echo "runs automatically as part of the image build, no extra step needed)." >&2
  exit 1
fi

# Strip whitespace/newlines from the key -- a trailing \n in an API key
# header causes a bare HTTP 400 with no response body, easy to mistake for
# an auth failure (see /memories/dtrack-api-key-newline.md).
API_KEY="$(printf '%s' "$DTRACK_API_KEY" | tr -d '\r\n ')"

curl -sS -X POST "${DTRACK_URL%/}/api/v1/bom" \
  -H "X-Api-Key: ${API_KEY}" \
  -F "autoCreate=true" \
  -F "projectName=${PROJECT_NAME}" \
  -F "projectVersion=${PROJECT_VERSION}" \
  -F "bom=@${SBOM}"

echo
echo "Uploaded $SBOM to ${DTRACK_URL} as ${PROJECT_NAME}:${PROJECT_VERSION}"
