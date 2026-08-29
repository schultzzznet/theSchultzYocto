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
#   DTRACK_PROJECT_NAME     default: theSchultzYocto (the repo/layer -- the DT
#                           project groups every version of this firmware)
#   DTRACK_PROJECT_VERSION  release: YYYY.MM.PATCH (Ubuntu-style CalVer, e.g.
#                           2026.07.0); rolling line: "rolling"; unset falls back
#                           to a build id (build-<UTC timestamp>)
#
# Usage: DTRACK_URL=... DTRACK_API_KEY=... ./scripts/upload-sbom.sh

set -euo pipefail

: "${DTRACK_URL:?Set DTRACK_URL, e.g. https://dtrack.example.com}"
: "${DTRACK_API_KEY:?Set DTRACK_API_KEY}"

# The Dependency-Track PROJECT is named after the repo/layer (theSchultzYocto)
# so DT groups all builds of it together. IMAGE_NAME is the actual firmware
# component recorded *inside* the SBOM/VEX (the image recipe) -- keeping the two
# separate means DT's project list reads as the repo while the BOM still names
# the real artifact it describes.
PROJECT_NAME="${DTRACK_PROJECT_NAME:-theSchultzYocto}"
# Ubuntu-style CalVer for releases (YYYY.MM.PATCH, e.g. 2026.07.0); "rolling" for
# the daily living SBOM. The fallback is a build id, not a release -- set
# DTRACK_PROJECT_VERSION explicitly when cutting a real release.
PROJECT_VERSION="${DTRACK_PROJECT_VERSION:-build-$(date -u +%Y%m%dT%H%M%SZ)}"
IMAGE_NAME="${SCHULTZ_IMAGE_NAME:-schultz-image-minimal}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"

# Which build dir to read the manifest/cve-summary/pkgdata from. "build" is the
# single-partition rolling image the daily scan tracks; set SCHULTZ_BUILD_SUBDIR
# to "build-rauc" to snapshot the A/B RAUC image instead (e.g. for a dated
# release of what actually ships to hardware). See docs/security-and-auditing.md.
BUILD_SUBDIR="${SCHULTZ_BUILD_SUBDIR:-build}"
MANIFEST="$WORK_DIR/$BUILD_SUBDIR/tmp/deploy/images/raspberrypi3-64/${IMAGE_NAME}-raspberrypi3-64.rootfs.manifest"

if [ ! -f "$MANIFEST" ]; then
  echo "No manifest at $MANIFEST -- build ${IMAGE_NAME} first." >&2
  exit 1
fi

# Wrynose 6.0: cve-check was removed; sbom-cve-check produces a yocto-format
# JSON in DEPLOY_DIR_IMAGE (same structure as cve-summary.json, so
# manifest-to-cyclonedx.py and manifest-to-vex.py work unchanged).
# NOTE: build/conf/local.conf is NOT git-managed (only copied from the
# template when a build dir is first created), so production still runs
# cve-check, not sbom-cve-check, until it's explicitly switched over.
CVE_SUMMARY="$WORK_DIR/$BUILD_SUBDIR/tmp/log/cve/cve-summary.json"
PKGDATA_DIR="$WORK_DIR/$BUILD_SUBDIR/tmp/pkgdata/raspberrypi3-64/runtime-reverse"

SBOM_CDX="$(mktemp /tmp/schultz-sbom-XXXXXX.cdx.json)"
VEX_CDX="$(mktemp /tmp/schultz-vex-XXXXXX.cdx.json)"
trap 'rm -f "$SBOM_CDX" "$VEX_CDX"' EXIT

# Optional audit trail: if SBOM_ARCHIVE_DIR is set, keep a timestamped copy of
# every SBOM and VEX actually generated (the temp files above are deleted on
# exit). This is what an auditor reads to answer "what exactly did we assert
# about this image, and when?" -- see docs/security-and-auditing.md.
ARCHIVE_TS="$(date -u +%Y%m%dT%H%M%SZ)"
archive_artifact() {  # archive_artifact <file> <suffix>
  [ -n "${SBOM_ARCHIVE_DIR:-}" ] || return 0
  mkdir -p "$SBOM_ARCHIVE_DIR"
  cp "$1" "$SBOM_ARCHIVE_DIR/${PROJECT_NAME}-${PROJECT_VERSION}-${ARCHIVE_TS}.$2"
}

if [ -f "$CVE_SUMMARY" ]; then
  # pkgdata is the authoritative pkg->recipe map: it lets lib* package names
  # (libssl3 -> openssl, libc6 -> glibc) get CPEs too. Passing a missing dir is
  # harmless -- the generator just falls back to name/prefix matching.
  python3 "$REPO_DIR/scripts/manifest-to-cyclonedx.py" "$MANIFEST" "$IMAGE_NAME" "$PROJECT_VERSION" "$CVE_SUMMARY" "$PKGDATA_DIR" > "$SBOM_CDX"
else
  echo "No cve-summary.json at $CVE_SUMMARY -- uploading with generic PURLs only (no CPEs; enable cve-check for real DT matching)." >&2
  python3 "$REPO_DIR/scripts/manifest-to-cyclonedx.py" "$MANIFEST" "$IMAGE_NAME" "$PROJECT_VERSION" > "$SBOM_CDX"
fi
archive_artifact "$SBOM_CDX" sbom.cdx.json

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
python3 "$REPO_DIR/scripts/manifest-to-vex.py" "$MANIFEST" "$IMAGE_NAME" "$PROJECT_VERSION" "$CVE_SUMMARY" "$PKGDATA_DIR" > "$VEX_CDX"
archive_artifact "$VEX_CDX" vex.cdx.json

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
