#!/usr/bin/env bash
# One-time (idempotent) setup of 3 Nexus "raw" hosted repositories on the
# Mac's existing Nexus instance (see
# ../the-docker-swarm-ai/infra/dev-server/):
#   - yocto-sources-raw    Yocto SOURCE_MIRROR_URL target
#   - yocto-sstate-raw     Yocto SSTATE_MIRRORS target
#   - schultz-releases-raw signed RAUC release bundles + A/B images that the
#                          device pulls over the air (rauc install http://.../x.raucb)
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

# ── schultz-releases-raw: signed RAUC bundles the device pulls OTA ────────────
# writePolicy ALLOW_ONCE = a published <version>/ path can't be overwritten
# (immutable releases); cut-release.sh checks-then-skips already-published files.
if repo_exists schultz-releases-raw; then
  echo "==> schultz-releases-raw already exists, skipping."
else
  echo "==> Creating schultz-releases-raw..."
  curl -sf "${AUTH[@]}" -X POST -H "Content-Type: application/json" \
    -d '{
      "name": "schultz-releases-raw",
      "online": true,
      "storage": {"blobStoreName": "default", "strictContentTypeValidation": false, "writePolicy": "ALLOW_ONCE"},
      "cleanup": {"policyNames": []}
    }' \
    "$NEXUS_URL/service/rest/v1/repositories/raw/hosted" \
    && echo "    created."
fi

# ── yocto-ci: a write account that is NOT admin ──────────────────────────────
# Writing to yocto-sstate-raw is effectively commit access to every future
# image: sstate is executable build output that gets unpacked into builds, and
# unlike source tarballs it is not checksum-pinned by the recipe. So the build
# host gets an account scoped to these three repos, with no delete and no
# admin, rather than the shared instance admin login.
CI_USER="${NEXUS_CI_USER:-yocto-ci}"
CI_ROLE="yocto-ci-writer"
REPOS=(yocto-sources-raw yocto-sstate-raw schultz-releases-raw)

echo ""
echo "==> Ensuring scoped write account '$CI_USER'..."

PRIVS=()
for repo in "${REPOS[@]}"; do
  priv="nx-yocto-write-$repo"
  PRIVS+=("$priv")
  if curl -sf "${AUTH[@]}" -o /dev/null "$NEXUS_URL/service/rest/v1/security/privileges/$priv"; then
    echo "    privilege $priv exists."
  else
    # No DELETE: a mirror push never needs to remove anything, and releases are
    # immutable (ALLOW_ONCE) anyway.
    curl -sf "${AUTH[@]}" -X POST -H "Content-Type: application/json" \
      -d "{\"name\":\"$priv\",\"description\":\"Yocto CI write access to $repo\",\"actions\":[\"BROWSE\",\"READ\",\"EDIT\",\"ADD\"],\"format\":\"raw\",\"repository\":\"$repo\"}" \
      "$NEXUS_URL/service/rest/v1/security/privileges/repository-view" \
      && echo "    privilege $priv created."
  fi
done

if curl -sf "${AUTH[@]}" -o /dev/null "$NEXUS_URL/service/rest/v1/security/roles/$CI_ROLE"; then
  echo "    role $CI_ROLE exists."
else
  privs_json="$(printf '"%s",' "${PRIVS[@]}")"; privs_json="[${privs_json%,}]"
  curl -sf "${AUTH[@]}" -X POST -H "Content-Type: application/json" \
    -d "{\"id\":\"$CI_ROLE\",\"name\":\"$CI_ROLE\",\"description\":\"Populate the Yocto mirrors and publish releases\",\"privileges\":$privs_json,\"roles\":[]}" \
    "$NEXUS_URL/service/rest/v1/security/roles" \
    && echo "    role $CI_ROLE created."
fi

if curl -sf "${AUTH[@]}" "$NEXUS_URL/service/rest/v1/security/users?userId=$CI_USER" | grep -q "\"userId\""; then
  echo "    user $CI_USER exists -- leaving its password alone."
  echo "    (to rotate: delete it in the UI and re-run, or use the change-password API)"
else
  # The password is generated here and written straight to a 0600 file. It is
  # never echoed, never passed as a command-line argument (argv is world-readable
  # in ps), and the JSON body goes to curl over stdin for the same reason.
  SECRET_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/keys/nexus-write.env"
  mkdir -p "$(dirname "$SECRET_FILE")"
  umask 077
  python3 - "$CI_USER" "$CI_ROLE" "$SECRET_FILE" "$NEXUS_URL" <<'PY' | \
    curl -sf "${AUTH[@]}" -X POST -H "Content-Type: application/json" \
      --data-binary @- "$NEXUS_URL/service/rest/v1/security/users" >/dev/null \
    && echo "    user $CI_USER created; credentials written to keys/nexus-write.env"
import json, secrets, sys, os
user, role, secret_file, nexus_url = sys.argv[1:5]
pw = secrets.token_urlsafe(32)
fd = os.open(secret_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(f"NEXUS_URL={nexus_url}\nNEXUS_WRITE_USER={user}\nNEXUS_WRITE_PASS={pw}\n")
json.dump({"userId": user, "firstName": "Yocto", "lastName": "CI",
           "emailAddress": f"{user}@localhost", "password": pw,
           "status": "active", "roles": [role]}, sys.stdout)
PY
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
echo "maven/npm/docker) -- reads work with no credentials. Writes use the"
echo "scoped '$CI_USER' account above; copy keys/nexus-write.env to the build"
echo "host as keys/nexus.env -- see docs/yocto-concepts.md."
