#!/usr/bin/env bash
# Uploads a CycloneDX SBOM (built from the image's .manifest file -- see
# scripts/manifest-to-cyclonedx.py for why not Yocto's own SPDX output) to a
# Dependency-Track instance. Run on the build host, after a successful build
# of schultz-image-minimal.
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
MANIFEST="$WORK_DIR/build/tmp/deploy/images/raspberrypi3-64/schultz-image-minimal-raspberrypi3-64.rootfs.manifest"

if [ ! -f "$MANIFEST" ]; then
  echo "No manifest at $MANIFEST -- build schultz-image-minimal first." >&2
  exit 1
fi

# Historical note: originally extracted+converted Yocto's own SPDX output
# (create-spdx-2.2) via cyclonedx-cli. Abandoned 2026-07-04 -- that SPDX
# output is a graph of 166+ linked documents (one per recipe/package via
# externalDocumentRefs), and converting just the top-level document only
# captures the image itself as a single "package", none of its actual
# constituent packages. Generating directly from the plain-text .manifest
# file (name/arch/version per line, exactly what's needed) is simpler and
# actually gets the full package list into Dependency-Track. See
# scripts/manifest-to-cyclonedx.py for the real, stated limitation (generic
# PURLs, not ecosystem-specific -- less precise vuln matching than a real
# distro's packages would get, but a genuine per-package list nonetheless).
SBOM_CDX="$(mktemp /tmp/schultz-sbom-XXXXXX.cdx.json)"
trap 'rm -f "$SBOM_CDX"' EXIT
python3 "$REPO_DIR/scripts/manifest-to-cyclonedx.py" "$MANIFEST" "$PROJECT_NAME" "$PROJECT_VERSION" > "$SBOM_CDX"

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

echo "Uploaded $SBOM_CDX to ${DTRACK_URL} as ${PROJECT_NAME}:${PROJECT_VERSION} (HTTP $HTTP_STATUS)"
