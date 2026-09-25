#!/usr/bin/env bash
# set-nexus-url.sh — repoint this BUILD HOST at a (moved) Nexus, then prove it works.
#
#   ssh rpi5g16nvme bash -s -- http://192.168.1.250:8081 < scripts/set-nexus-url.sh
#
# The URL is copied, not referenced: conf/templates/schultz/local.conf.sample only
# seeds a build dir the FIRST time oe-init-build-env creates it, so every existing
# ~/build*/conf/local.conf keeps its own SSTATE_MIRRORS / SOURCE_MIRROR_URL, and
# ~/keys/nexus.env carries NEXUS_URL for cut-release / ota-deploy / populate-mirror.
# Changing the template alone leaves every existing build on the old host.
#
# Rewrites the host:port in those lines (backups: *.bak-<date>), then asserts from
# THIS host: Nexus is writable, and a real object in yocto-sstate-raw downloads.
set -euo pipefail

NEW="${1:?usage: set-nexus-url.sh http://<host>:8081}"
NEW="${NEW%/}"
stamp="$(date +%Y%m%d-%H%M%S)"
changed=0

rewrite() { # <file> <line-regex>
    local f="$1" lines="$2"
    [ -f "$f" ] || return 0
    if grep -qE "$lines" "$f" && grep -E "$lines" "$f" | grep -qv "$NEW"; then
        cp -p "$f" "$f.bak-$stamp"
        sed -i -E "/$lines/ s#https?://[A-Za-z0-9.-]+:8081#$NEW#g" "$f"
        echo "  rewrote $f"
        changed=$((changed + 1))
    fi
}

# SSTATE_MIRRORS is not Nexus any more (scripts/setup-sstate-server.sh owns it).
for conf in "$HOME"/build*/conf/local.conf; do
    rewrite "$conf" '^SOURCE_MIRROR_URL'
done
rewrite "$HOME/keys/nexus.env" '^NEXUS_URL='
echo "  $changed file(s) changed"

stale="$(grep -lE '^(SOURCE_MIRROR_URL|NEXUS_URL)' "$HOME"/build*/conf/local.conf "$HOME/keys/nexus.env" 2>/dev/null |
    xargs grep -hE '^(SOURCE_MIRROR_URL|NEXUS_URL)' | grep -v "$NEW" || true)"
if [ -n "$stale" ]; then
    echo "FAIL: lines still pointing elsewhere:"
    echo "$stale"
    exit 1
fi

curl -fsS -o /dev/null "$NEW/service/rest/v1/status/writable"
echo "  ok    $NEW is writable, reached from $(hostname)"

# Prove a real download from the source mirror. (yocto-sstate-raw was always empty;
# sstate is served by the build host itself - scripts/setup-sstate-server.sh.)
repo=yocto-sources-raw
obj="$(curl -fsS "$NEW/service/rest/v1/assets?repository=$repo" |
    python3 -c 'import json,sys; i=json.load(sys.stdin)["items"]; print(i[0]["path"] if i else "")')"
[ -n "$obj" ] || { echo "FAIL: $repo is EMPTY - builds get no source-mirror hits"; exit 1; }
curl -fsS -o /dev/null "$NEW/repository/$repo/$obj"
echo "  ok    $repo: $obj downloads"
