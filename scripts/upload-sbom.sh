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
SBOM_TARBALL="$WORK_DIR/build/tmp/deploy/images/raspberrypi3-64/schultz-image-minimal-raspberrypi3-64.rootfs.spdx.tar.zst"

if [ ! -f "$SBOM_TARBALL" ]; then
  echo "No SBOM at $SBOM_TARBALL -- build schultz-image-minimal first (create-spdx" >&2
  echo "runs automatically as part of the image build, no extra step needed)." >&2
  exit 1
fi

# create-spdx-2.2 produces a tarball of many linked SPDX documents (one per
# recipe/package), not a single flat .spdx.json. The top-level image
# document -- the one to actually hand to Dependency-Track -- is the entry
# with the same base name as the tarball itself, just without .tar.zst.
# (Confirmed by inspecting a real tarball 2026-07-03: first entry listed is
# exactly this, e.g. tarball
# "...rootfs-20260703080504.spdx.tar.zst" contains member
# "...rootfs-20260703080504.spdx.json".)
RESOLVED_BASENAME="$(basename "$(readlink -f "$SBOM_TARBALL")")"
MEMBER="${RESOLVED_BASENAME%.tar.zst}.json"

SBOM_SPDX="$(mktemp /tmp/schultz-sbom-XXXXXX.spdx.json)"
SBOM_CDX="$(mktemp /tmp/schultz-sbom-XXXXXX.cdx.json)"
trap 'rm -f "$SBOM_SPDX" "$SBOM_CDX"' EXIT
tar --zstd -xO -f "$SBOM_TARBALL" "$MEMBER" > "$SBOM_SPDX"

# Dependency-Track's /api/v1/bom endpoint validates uploads as CycloneDX --
# it does NOT accept SPDX (confirmed 2026-07-04 via DependencyTrack's own
# CycloneDxValidator.java source: it throws "Unable to determine schema
# version from JSON" because it's looking for CycloneDX's specVersion
# field, not SPDX's spdxVersion). Yocto's create-spdx has no CycloneDX
# equivalent (checked oe-core/meta-openembedded -- no such class exists),
# so convert with cyclonedx-cli (github.com/CycloneDX/cyclonedx-cli,
# installed at /usr/local/bin/cyclonedx-cli).
if ! command -v cyclonedx-cli > /dev/null 2>&1; then
  echo "cyclonedx-cli not found -- install it first (see docs/build-operations.md)" >&2
  exit 1
fi
cyclonedx-cli convert --input-file "$SBOM_SPDX" --input-format spdxjson \
  --output-file "$SBOM_CDX" --output-format json

# Strip whitespace/newlines from the key -- a trailing \n in an API key
# header causes a bare HTTP 400 with no response body, easy to mistake for
# an auth failure (see /memories/dtrack-api-key-newline.md).
API_KEY="$(printf '%s' "$DTRACK_API_KEY" | tr -d '\r\n ')"

# -w + explicit status check: curl exits 0 for HTTP error responses too
# (401/403/etc) unless -f/--fail is passed, and -f swallows the response
# body that would actually explain the failure. Capture status separately
# instead so a rejected upload is loud, not silently reported as success
# (learned the hard way 2026-07-04 -- this used to always print "Uploaded"
# regardless of whether the request actually succeeded).
HTTP_STATUS="$(curl -sS -o /tmp/dtrack-upload-response.$$ -w '%{http_code}' -X POST "${DTRACK_URL%/}/api/v1/bom" \
  -H "X-Api-Key: ${API_KEY}" \
  -F "autoCreate=true" \
  -F "projectName=${PROJECT_NAME}" \
  -F "projectVersion=${PROJECT_VERSION}" \
  -F "bom=@${SBOM_CDX}")"
RESPONSE_BODY="$(cat /tmp/dtrack-upload-response.$$)"
rm -f "/tmp/dtrack-upload-response.$$"

if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
  echo "SBOM upload FAILED: HTTP $HTTP_STATUS" >&2
  echo "$RESPONSE_BODY" >&2
  exit 1
fi

echo "Uploaded $SBOM_CDX (converted from $SBOM_SPDX) to ${DTRACK_URL} as ${PROJECT_NAME}:${PROJECT_VERSION} (HTTP $HTTP_STATUS)"
