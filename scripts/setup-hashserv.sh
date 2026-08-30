#!/usr/bin/env bash
# Stand up a persistent, shared BitBake hash-equivalence server on the build
# host, and point local.conf at it.
#
# Why this exists: bitbake defaults to a *local* hashserv on a unix socket, with
# its database inside the build directory. That is fine until you have an sstate
# mirror -- at which point sanity.bbclass warns:
#
#   "You are using a local hash equivalence server but have configured an sstate
#    mirror. This will likely mean no sstate will match from the mirror."
#
# and it is right. Hash equivalence maps a task's *taskhash* to the *unihash*
# that actually names the sstate object. Mirrored sstate is named by the
# producer's unihashes, so a consumer that cannot resolve those mappings will
# compute a different name and miss every object in the mirror. The mappings
# have to live somewhere both sides can reach -- that is this server.
#
# Run ON THE BUILD HOST. Needs sudo for the systemd unit.
#
# Usage: ./scripts/setup-hashserv.sh [port]     (default 8686)

set -euo pipefail

PORT="${1:-8686}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"
# shellcheck disable=SC1091
source "$REPO_DIR/scripts/release-profile.sh"
BUILD_DIR="${BUILD_DIR:-$WORK_DIR/$SCHULTZ_BUILD}"
DB_DIR="${DB_DIR:-$HOME/hashserv}"
DB="$DB_DIR/hashserv.db"
# bitbake moved out of poky/ in wrynose, so the binary path is release-dependent.
HASHSERV_BIN="${HASHSERV_BIN:-$WORK_DIR/$SCHULTZ_HASHSERV_BIN}"
UNIT=/etc/systemd/system/bitbake-hashserv.service

[ -x "$HASHSERV_BIN" ] || { echo "no bitbake-hashserv at $HASHSERV_BIN" >&2; exit 1; }

# ── seed from the existing local database ────────────────────────────────────
# The equivalences for everything already in the sstate mirror live in the
# build-local db. Starting empty would strand every object already uploaded.
mkdir -p "$DB_DIR"
LOCAL_DB="$BUILD_DIR/cache/hashserv.db"
if [ ! -f "$DB" ] && [ -f "$LOCAL_DB" ]; then
  echo "==> seeding $DB from $LOCAL_DB"
  if command -v sqlite3 >/dev/null; then
    # .backup is WAL-safe; a plain cp of a live sqlite file can miss the -wal.
    sqlite3 "$LOCAL_DB" ".backup '$DB'"
  else
    cp "$LOCAL_DB" "$DB"
    for ext in -wal -shm; do [ -f "$LOCAL_DB$ext" ] && cp "$LOCAL_DB$ext" "$DB$ext"; done
  fi
else
  echo "==> $DB already present (or no local db to seed from) -- not touching it."
fi

# ── systemd unit ─────────────────────────────────────────────────────────────
# anon-perms drops the default @db-admin: clients only need to read and report
# equivalences, and this port is reachable from the LAN.
echo "==> writing $UNIT"
sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=BitBake hash equivalence server (backs the Nexus sstate mirror)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
Group=$(id -gn)
ExecStart=$HASHSERV_BIN --bind 0.0.0.0:$PORT --database $DB --anon-perms @read,@report --log INFO
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now bitbake-hashserv.service
sudo systemctl --no-pager --lines=5 status bitbake-hashserv.service || true

# ── point local.conf at it ───────────────────────────────────────────────────
# BB_HASHSERVE is in BB_BASEHASH_IGNORE_VARS, so switching servers does not
# change any task signature -- no rebuild is triggered by this.
CONF="$BUILD_DIR/conf/local.conf"
if [ -f "$CONF" ]; then
  if grep -q '^BB_HASHSERVE' "$CONF"; then
    sed -i "s|^BB_HASHSERVE.*|BB_HASHSERVE = \"localhost:$PORT\"|" "$CONF"
  else
    printf '\n# Shared hash-equivalence server (scripts/setup-hashserv.sh) -- without\n# this, sstate from the mirror resolves to different unihashes and never matches.\nBB_HASHSERVE = "localhost:%s"\n' "$PORT" >> "$CONF"
  fi
  echo "==> $CONF: $(grep '^BB_HASHSERVE' "$CONF")"
fi

echo ""
echo "Done. Verify with:"
echo "  $WORK_DIR/$SCHULTZ_HASHSERV_BIN --address localhost:$PORT stats"
echo "A second build host points BB_HASHSERVE at $(hostname):$PORT instead of localhost."
