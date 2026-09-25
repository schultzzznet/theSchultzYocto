#!/usr/bin/env bash
# setup-sstate-server.sh — serve the build host's sstate cache read-only over HTTP,
# then prove it FROM THIS MACHINE (i.e. over the LAN, the way another builder sees it).
#
#   ./scripts/setup-sstate-server.sh [ssh-host]        (default rpi5g16nvme)
#
# Why not the Nexus yocto-sstate-raw repo: pushing sstate there filled the blob store
# (2026-08-30, GAPS I-7), so the nightly stopped and the repo went empty. Serving in place has no upload
# step to forget, costs no second copy, and is always current. Consumers set:
#   SSTATE_MIRRORS = "file://.* http://<host>:8687/PATH;downloadfilename=PATH"
#   BB_HASHSERVE   = "<host>:8686"
# shellcheck disable=SC2029  # every ssh line below expands on this side on purpose
set -euo pipefail

HOST="${1:-rpi5g16nvme}"
PORT=8687
UNIT=yocto-sstate-http.service
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_DIR/conf/build-host/$UNIT"

scp -q "$SRC" "$HOST:/tmp/$UNIT"
ssh "$HOST" "sudo install -m 0644 /tmp/$UNIT /etc/systemd/system/$UNIT && rm /tmp/$UNIT && sudo systemctl daemon-reload && sudo systemctl enable $UNIT && sudo systemctl restart $UNIT"
# A name, not an IP: .228 is a router reservation, but a name survives a re-address.
URL="http://$HOST.local:$PORT"
echo "==> $UNIT active on $HOST; checking $URL from $(hostname -s)"

for _ in 1 2 3 4 5; do curl -fsS -o /dev/null "$URL/" && break; sleep 1; done

rel="$(ssh "$HOST" "cd ~/yocto-sstate && find . -name '*.tar.zst' -size +1k -print -quit")"
rel="${rel#./}"
[ -n "$rel" ] || { echo "FAIL: no sstate objects in ~/yocto-sstate on $HOST"; exit 1; }
want="$(ssh "$HOST" "sha256sum ~/yocto-sstate/$rel" | awk '{print $1}')"
got="$(curl -fsS "$URL/$rel" | shasum -a 256 | awk '{print $1}')"
[ "$want" = "$got" ] || { echo "FAIL: $rel differs over HTTP ($got != $want)"; exit 1; }
echo "  ok    real object downloads byte-identical: $rel"

code="$(curl -s -o /dev/null -w '%{http_code}' "$URL/no/such/object.tar.zst")"
[ "$code" = 404 ] || { echo "FAIL: missing object answered $code, want 404 (bitbake needs a clean miss)"; exit 1; }
echo "  ok    missing object -> 404"

code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT --data x "$URL/$rel")"
case "$code" in 2*) echo "FAIL: PUT accepted ($code) - the cache must be read-only"; exit 1 ;; esac
echo "  ok    PUT refused ($code)"

# Existing build dirs keep the SSTATE_MIRRORS they were seeded with (the dead Nexus repo).
line="SSTATE_MIRRORS ?= \"file://.* $URL/PATH;downloadfilename=PATH\""
ssh "$HOST" "for c in ~/build*/conf/local.conf; do grep -qF '$line' \"\$c\" && continue; grep -q '^SSTATE_MIRRORS' \"\$c\" || continue; sed -i.bak-sstate -E 's#^SSTATE_MIRRORS.*#$line#' \"\$c\"; echo \"  rewrote \$c\"; done"
ssh "$HOST" "grep -H '^SSTATE_MIRRORS' ~/build*/conf/local.conf"
