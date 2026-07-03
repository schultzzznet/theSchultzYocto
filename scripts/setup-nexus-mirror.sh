#!/usr/bin/env bash
# One-time (idempotent) setup of 2 Nexus "raw" hosted repositories on the
# Mac's existing Nexus instance (see
# ../the-docker-swarm-ai/infra/dev-server/), for use as a Yocto
# SOURCE_MIRROR_URL + SSTATE_MIRRORS target.
#
# This is a genuinely new addition to that Nexus instance -- it only had
# maven-public/npm-proxy/docker-hub-proxy configured before (checked
# 2026-07-03), no generic "raw" repo, which is what Yocto's mirrors need
# (plain HTTP GET for reads, PUT for CI/build hosts to populate them).
#
# Mirrors the idempotent style of
# ../the-docker-swarm-ai/infra/dev-server/setup-nexus-repos.sh (same repo,
# same admin password convention) rather than inventing a different one.
#
# Run this ON THE MAC -- Nexus lives here, not on the Yocto build host.
#
# Usage: ./scripts/setup-nexus-mirror.sh

set -euo pipefail

NEXUS_URL="${NEXUS_URL:-http://localhost:8081}"
ADMIN_PASSWORD="${NEXUS_ADMIN_PASSWORD:-nexusadmin123}"
AUTH=(-u "admin:$ADMIN_PASSWORD")

repo_exists() {
  local name="$1"
  curl -sf "${AUTH[@]}" -o /dev/null "$NEXUS_URL/service/rest/v1/repositories/$name"
}

# ── yocto-sources-raw: SOURCE_MIRROR_URL target ──────────────────────────────
if repo_exists yocto-sources-raw; then
  echo "==> yocto-sources-raw already exists, skipping."
else
  echo "==> Creating yocto-sources-raw..."
  curl -sf "${AUTH[@]}" -X POST -H "Content-Type: application/json" \
    -d '{
      "name": "yocto-sources-raw",
      "online": true,
      "storage": {"blobStoreName": "default", "strictContentTypeValidation": false, "writePolicy": "ALLOW"},
      "cleanup": {"policyNames": []}
    }' \
    "$NEXUS_URL/service/rest/v1/repositories/raw/hosted" \
    && echo "    created."
fi

# ── yocto-sstate-raw: SSTATE_MIRRORS target ──────────────────────────────────
if repo_exists yocto-sstate-raw; then
  echo "==> yocto-sstate-raw already exists, skipping."
else
  echo "==> Creating yocto-sstate-raw..."
  curl -sf "${AUTH[@]}" -X POST -H "Content-Type: application/json" \
    -d '{
      "name": "yocto-sstate-raw",
      "online": true,
      "storage": {"blobStoreName": "default", "strictContentTypeValidation": false, "writePolicy": "ALLOW"},
      "cleanup": {"policyNames": []}
    }' \
    "$NEXUS_URL/service/rest/v1/repositories/raw/hosted" \
    && echo "    created."
fi

echo ""
echo "==> Done. Repositories:"
curl -sf "${AUTH[@]}" "$NEXUS_URL/service/rest/v1/repositories" | python3 -c "
import json, sys
for r in json.load(sys.stdin):
    if r['format'] == 'raw':
        print(f\"  - {r['name']:20s} {r['type']:8s} {r['url']}\")
"
echo ""
echo "Anonymous read is already enabled on this Nexus instance (set up for"
echo "maven/npm/docker) -- reads work with no credentials. Writes (CI/build"
echo "hosts populating the mirror) need admin:\$NEXUS_ADMIN_PASSWORD or a"
echo "dedicated token -- see docs/yocto-concepts.md."
