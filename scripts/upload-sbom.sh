#!/usr/bin/env bash
# Uploads a CycloneDX SBOM (built from the image's .manifest file -- see
# scripts/manifest-to-cyclonedx.py for why not Yocto's own SPDX output) to a
# Dependency-Track instance, then applies a VEX generated from cve-check so DT
# auto-dismisses the CVEs Yocto has already Patched/Ignored (see
# scripts/manifest-to-vex.py). Run on the build host, after a successful build
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
# scripts/manifest-to-cyclonedx.py for details. Components carry generic
# `pkg:generic/...` PURLs (no ecosystem-specific PURL type exists for OE
# packages), so on their own DT can't match CVEs -- but we also feed in
# cve-check's per-recipe CPE product table below so each component gets a real
# CPE and DT's NVD matching actually works.
CVE_SUMMARY="$WORK_DIR/build/tmp/log/cve/cve-summary.json"
PKGDATA_DIR="$WORK_DIR/build/tmp/pkgdata/raspberrypi3-64/runtime-reverse"

SBOM_CDX="$(mktemp /tmp/schultz-sbom-XXXXXX.cdx.json)"
VEX_CDX="$(mktemp /tmp/schultz-vex-XXXXXX.cdx.json)"
trap 'rm -f "$SBOM_CDX" "$VEX_CDX"' EXIT
if [ -f "$CVE_SUMMARY" ]; then
  # pkgdata is the authoritative pkg->recipe map: it lets lib* package names
  # (libssl3 -> openssl, libc6 -> glibc) get CPEs too. Passing a missing dir is
  # harmless -- the generator just falls back to name/prefix matching.
  python3 "$REPO_DIR/scripts/manifest-to-cyclonedx.py" "$MANIFEST" "$PROJECT_NAME" "$PROJECT_VERSION" "$CVE_SUMMARY" "$PKGDATA_DIR" > "$SBOM_CDX"
else
  echo "No cve-summary.json at $CVE_SUMMARY -- uploading with generic PURLs only (no CPEs; enable cve-check for real DT matching)." >&2
  python3 "$REPO_DIR/scripts/manifest-to-cyclonedx.py" "$MANIFEST" "$PROJECT_NAME" "$PROJECT_VERSION" > "$SBOM_CDX"
fi

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

echo "Uploaded SBOM to ${DTRACK_URL} as ${PROJECT_NAME}:${PROJECT_VERSION} (HTTP $HTTP_STATUS)"

# Without cve-check data there is nothing to assert about which findings Yocto
# already fixed, so the VEX step is skipped and DT keeps every CPE match active.
if [ ! -f "$CVE_SUMMARY" ]; then
  echo "No cve-summary.json -- skipping VEX (findings will not be auto-dismissed)."
  exit 0
fi

json_field() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"; }

# The VEX can only annotate findings that already exist, so wait for DT to
# finish ingesting the SBOM first. Both endpoints return a processing token
# that is polled on the same /api/v1/bom/token/<token> route.
poll_token() {
  local token="$1" i
  for i in $(seq 1 60); do
    case "$(curl -sS -H "X-Api-Key: ${API_KEY}" "${DTRACK_URL%/}/api/v1/bom/token/${token}" | json_field processing)" in
      False|false) return 0 ;;
    esac
    sleep 2
  done
  return 1
}

BOM_TOKEN="$(printf '%s' "$RESPONSE_BODY" | json_field token)"
PROJECT_UUID="$(printf '%s' "$RESPONSE_BODY" | json_field projectUuid)"
if [ -n "$BOM_TOKEN" ]; then
  echo "Waiting for DT to finish processing the SBOM (token $BOM_TOKEN)..."
  poll_token "$BOM_TOKEN" || echo "  (still processing after 120s; applying VEX anyway)" >&2
fi
if [ -z "$PROJECT_UUID" ]; then
  # Some responses omit the UUID; fall back to a name+version lookup.
  PROJECT_UUID="$(curl -sS -H "X-Api-Key: ${API_KEY}" \
    "${DTRACK_URL%/}/api/v1/project/lookup?name=${PROJECT_NAME}&version=${PROJECT_VERSION}" | json_field uuid)"
fi

# Generate the VEX from cve-check and apply it. DT correlates a standalone VEX
# by the single root bom-ref (not per-component), so this document is
# CVE-centric -- see scripts/manifest-to-vex.py for the full rationale.
python3 "$REPO_DIR/scripts/manifest-to-vex.py" "$MANIFEST" "$PROJECT_NAME" "$PROJECT_VERSION" "$CVE_SUMMARY" "$PKGDATA_DIR" > "$VEX_CDX"

# Multipart upload: the VEX can be several hundred KB, which overflows the
# shell's argument-length limit if base64'd into a JSON body on the command line.
VEX_STATUS="$(curl -sS -o /tmp/dtrack-vex-response.$$ -w '%{http_code}' -X POST "${DTRACK_URL%/}/api/v1/vex" \
  -H "X-Api-Key: ${API_KEY}" \
  -F "project=${PROJECT_UUID}" \
  -F "vex=@${VEX_CDX}")"
VEX_BODY="$(cat /tmp/dtrack-vex-response.$$)"
rm -f "/tmp/dtrack-vex-response.$$"

if [ "$VEX_STATUS" -lt 200 ] || [ "$VEX_STATUS" -ge 300 ]; then
  echo "VEX upload FAILED: HTTP $VEX_STATUS" >&2
  echo "$VEX_BODY" >&2
  exit 1
fi

VEX_TOKEN="$(printf '%s' "$VEX_BODY" | json_field token)"
[ -n "$VEX_TOKEN" ] && poll_token "$VEX_TOKEN" >/dev/null 2>&1 || true
echo "Applied VEX to ${PROJECT_NAME}:${PROJECT_VERSION} (HTTP $VEX_STATUS) -- Yocto-fixed CVEs auto-dismissed."
