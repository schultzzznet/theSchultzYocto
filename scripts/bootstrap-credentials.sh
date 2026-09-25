#!/usr/bin/env bash
# Recreate the gitignored keys/*.env credential files from scratch.
#
# Every token this project uses is deliberately absent from git, which is right
# -- but it means a fresh build host, or a rebuilt service, leaves you clicking
# through three different UIs to get going again. That is not theoretical: when
# defectdojo-db was rebuilt on 2026-08-12 every API token was invalidated at
# once, and the nightly failed on a token that no longer existed.
#
# So mint them instead, from the admin credentials that already exist (gitignored)
# in the k3s project. Nothing secret is printed, passed in argv, or written
# world-readable.
#
# Idempotent by default: a credential that still authenticates is left alone.
#
# Usage (normally from the Mac, where the k3s .credentials live):
#   ./scripts/bootstrap-credentials.sh                 # mint whatever is missing/broken
#   ./scripts/bootstrap-credentials.sh --rotate        # force-mint new ones
#   ./scripts/bootstrap-credentials.sh --check         # report only, change nothing
#   ./scripts/bootstrap-credentials.sh --only defectdojo
#   ./scripts/bootstrap-credentials.sh --install-to rpi5g16nvme
#                                                      # ...and copy them to a build host
#
# What it produces in keys/ (a gitignored sibling of this repo):
#   dtrack.env      DTRACK_URL, DTRACK_API_KEY
#   defectdojo.env  DEFECTDOJO_URL, DEFECTDOJO_TOKEN, PENTEST_TARGET
#   nexus.env       NEXUS_URL, NEXUS_WRITE_USER, NEXUS_WRITE_PASS, NEXUS_REPO

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"
KEYS_DIR="${KEYS_DIR:-$WORK_DIR/keys}"
K3S_CREDS="${K3S_CREDS:-$WORK_DIR/the-docker-swarm-ai/infra/k3s/.credentials}"

DTRACK_URL="${DTRACK_URL:-http://delli7c6g32.local:30410}"
DTRACK_TEAM="${DTRACK_TEAM:-Automation}"
DEFECTDOJO_URL="${DEFECTDOJO_URL:-http://delli7c6g32.local:32438}"
NEXUS_URL="${NEXUS_URL:-http://192.168.1.250:8081}"
PENTEST_TARGET="${PENTEST_TARGET:-192.168.1.226}"

ROTATE=0 CHECK_ONLY=0 INSTALL_TO="" ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rotate)     ROTATE=1 ;;
    --check)      CHECK_ONLY=1 ;;
    --only)       ONLY="${2:?--only needs dtrack|defectdojo|nexus}"; shift ;;
    --install-to) INSTALL_TO="${2:?--install-to needs a host}"; shift ;;
    -h|--help)    sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

wants() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

umask 077
mkdir -p "$KEYS_DIR"

# Reads a secret from a file without it ever reaching a variable that gets
# echoed, and strips the trailing newline that otherwise breaks HTTP headers.
read_secret() { tr -d '\r\n' < "$1"; }

status() { printf '  %-14s %-38s %s\n' "$1" "$2" "$3"; }

# ── Dependency-Track ─────────────────────────────────────────────────────────
# Existing key still good? Then leave it: DT keys are per-team and minting
# spares is just clutter.
# Probe /api/v1/project (VIEW_PORTFOLIO), NOT /api/v1/team -- the latter needs
# ACCESS_MANAGEMENT, which the least-privilege Automation team does not have, so
# it would report a perfectly good upload key as broken.
dt_key_works() {
  [ -f "$KEYS_DIR/dtrack.env" ] || return 1
  local k; k="$(sed -n 's/^DTRACK_API_KEY=//p' "$KEYS_DIR/dtrack.env" | head -1 | tr -d '\r\n ')"
  [ -n "$k" ] || return 1
  [ "$(curl -sS -o /dev/null -m 10 -w '%{http_code}' -H "X-API-Key: $k" "$DTRACK_URL/api/v1/project")" = "200" ]
}

bootstrap_dtrack() {
  if [ "$ROTATE" -eq 0 ] && dt_key_works; then
    status "dependency-track" "$DTRACK_URL" "existing key OK -- skipped"
    return 0
  fi
  [ "$CHECK_ONLY" -eq 1 ] && { status "dependency-track" "$DTRACK_URL" "WOULD MINT a new API key"; return 0; }

  local pw jwt uuid code
  pw="$(read_secret "$K3S_CREDS/dtrack-admin-password")"
  # Form-encoded, and --data-urlencode so a password with & or = survives.
  jwt="$(curl -sS -m 20 -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
          --data-urlencode "username=admin" --data-urlencode "password=$pw" \
          "$DTRACK_URL/api/v1/user/login")"
  [ "${#jwt}" -gt 40 ] || { echo "  dependency-track: admin login failed" >&2; return 1; }

  uuid="$(curl -sS -m 20 -H "Authorization: Bearer $jwt" "$DTRACK_URL/api/v1/team" \
          | DTRACK_TEAM="$DTRACK_TEAM" python3 -c "import json,sys,os
team=os.environ['DTRACK_TEAM']
print(next((t['uuid'] for t in json.load(sys.stdin) if t['name']==team), ''))")"
  [ -n "$uuid" ] || { echo "  dependency-track: no team named '$DTRACK_TEAM'" >&2; return 1; }

  # PUT, not POST -- confirmed against this instance's own /api/openapi.json.
  code="$(curl -sS -o "$KEYS_DIR/.dt-key.json" -m 20 -w '%{http_code}' -X PUT \
           -H "Authorization: Bearer $jwt" "$DTRACK_URL/api/v1/team/$uuid/key")"
  case "$code" in
    2*) ;;
    *)  echo "  dependency-track: key creation failed (HTTP $code)" >&2
        rm -f "$KEYS_DIR/.dt-key.json"; return 1 ;;
  esac

  KEYS_DIR="$KEYS_DIR" DTRACK_URL="$DTRACK_URL" python3 -c "
import json, os
k = os.environ['KEYS_DIR']
d = json.load(open(k + '/.dt-key.json'))
key = d.get('key') or d.get('apiKey')   # field name moved between DT majors
fd = os.open(k + '/dtrack.env', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as f:
    f.write('DTRACK_URL=%s\nDTRACK_API_KEY=%s\n' % (os.environ['DTRACK_URL'], key))
"
  rm -f "$KEYS_DIR/.dt-key.json"
  dt_key_works && status "dependency-track" "$DTRACK_URL" "new key minted + verified" \
                || { echo "  dependency-track: minted key does NOT authenticate" >&2; return 1; }
}

# ── DefectDojo ───────────────────────────────────────────────────────────────
dd_token_works() {
  [ -f "$KEYS_DIR/defectdojo.env" ] || return 1
  local t; t="$(sed -n 's/^DEFECTDOJO_TOKEN=//p' "$KEYS_DIR/defectdojo.env" | head -1 | tr -d '\r\n ')"
  [ -n "$t" ] || return 1
  [ "$(curl -sS -o /dev/null -m 10 -w '%{http_code}' -H "Authorization: Token $t" \
        "$DEFECTDOJO_URL/api/v2/user_profile/")" = "200" ]
}

bootstrap_defectdojo() {
  if [ "$ROTATE" -eq 0 ] && dd_token_works; then
    status "defectdojo" "$DEFECTDOJO_URL" "existing token OK -- skipped"
    return 0
  fi
  [ "$CHECK_ONLY" -eq 1 ] && { status "defectdojo" "$DEFECTDOJO_URL" "WOULD MINT a new API token"; return 0; }

  # DD_ADMIN_PASSWORD lives in the k3s env file; there is no API token in there.
  local code
  set -a; # shellcheck disable=SC1090,SC1091
  source "$K3S_CREDS/defectdojo.env"; set +a
  code="$(python3 -c "import json,os;print(json.dumps({'username':'admin','password':os.environ['DD_ADMIN_PASSWORD']}))" \
    | curl -sS -o "$KEYS_DIR/.dd-token.json" -m 25 -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' --data-binary @- \
        "$DEFECTDOJO_URL/api/v2/api-token-auth/")"
  [ "$code" = "200" ] || { echo "  defectdojo: token request failed (HTTP $code)" >&2
                           rm -f "$KEYS_DIR/.dd-token.json"; return 1; }

  KEYS_DIR="$KEYS_DIR" DEFECTDOJO_URL="$DEFECTDOJO_URL" PENTEST_TARGET="$PENTEST_TARGET" python3 -c "
import json, os
k = os.environ['KEYS_DIR']
tok = json.load(open(k + '/.dd-token.json'))['token']
fd = os.open(k + '/defectdojo.env', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as f:
    f.write('DEFECTDOJO_URL=%s\nDEFECTDOJO_TOKEN=%s\nPENTEST_TARGET=%s\n'
            % (os.environ['DEFECTDOJO_URL'], tok, os.environ['PENTEST_TARGET']))
"
  rm -f "$KEYS_DIR/.dd-token.json"
  dd_token_works && status "defectdojo" "$DEFECTDOJO_URL" "new token minted + verified" \
                 || { echo "  defectdojo: minted token does NOT authenticate" >&2; return 1; }
}

# ── Nexus ────────────────────────────────────────────────────────────────────
# The yocto-ci account is IaC in the-docker-swarm-ai (infra/k3s/configs/nexus/
# nexus-config.json, applied by `make -C infra/k3s deploy-nexus`, which creates it
# from keys/nexus-write.env). This only mints or rotates that password, then
# normalises it into keys/nexus.env.
nexus_creds_work() {
  [ -f "$KEYS_DIR/nexus.env" ] || return 1
  local u p; u="$(sed -n 's/^NEXUS_WRITE_USER=//p' "$KEYS_DIR/nexus.env" | head -1)"
  p="$(sed -n 's/^NEXUS_WRITE_PASS=//p' "$KEYS_DIR/nexus.env" | head -1)"
  [ -n "$u" ] && [ -n "$p" ] || return 1
  local nrc; nrc="$(mktemp)"; chmod 600 "$nrc"
  printf 'machine %s login %s password %s\n' "$(echo "${NEXUS_URL#*://}" | cut -d: -f1)" "$u" "$p" > "$nrc"
  local code; code="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' --netrc-file "$nrc" \
                       "$NEXUS_URL/service/rest/v1/repositories")"
  rm -f "$nrc"; [ "$code" = "200" ]
}

bootstrap_nexus() {
  if [ "$ROTATE" -eq 0 ] && nexus_creds_work; then
    status "nexus" "$NEXUS_URL" "existing creds OK -- skipped"
    return 0
  fi
  [ "$CHECK_ONLY" -eq 1 ] && { status "nexus" "$NEXUS_URL" "WOULD mint/rotate the yocto-ci password"; return 0; }

  # A password can never be read back out of Nexus: a lost one is recovered by
  # setting a new one. printf is a builtin, so the value never reaches argv.
  if [ "$ROTATE" -eq 1 ] || [ ! -f "$KEYS_DIR/nexus-write.env" ]; then
    local user code
    user="${NEXUS_CI_USER:-yocto-ci}"
    printf 'NEXUS_URL=%s\nNEXUS_WRITE_USER=%s\nNEXUS_WRITE_PASS=%s\n' \
      "$NEXUS_URL" "$user" "$(openssl rand -hex 24)" > "$KEYS_DIR/nexus-write.env"
    # text/plain body, PUT -- confirmed against this Nexus's /service/rest/swagger.json.
    code="$(sed -n 's/^NEXUS_WRITE_PASS=//p' "$KEYS_DIR/nexus-write.env" | tr -d '\r\n' \
      | curl -sS -o /dev/null -m 20 -w '%{http_code}' \
          -K <(printf 'user = "admin:%s"\n' "$(read_secret "$K3S_CREDS/nexus-admin-password")") \
          -X PUT -H 'Content-Type: text/plain' --data-binary @- \
          "$NEXUS_URL/service/rest/v1/security/users/$user/change-password")"
    case "$code" in
      2*) status "nexus" "$NEXUS_URL" "yocto-ci password rotated" ;;
      404) echo "  nexus: no $user account -- run \`make -C the-docker-swarm-ai/infra/k3s deploy-nexus\`, which creates it from keys/nexus-write.env" >&2; return 1 ;;
      *)  echo "  nexus: password rotation failed (HTTP $code)" >&2; return 1 ;;
    esac
  fi

  { cat "$KEYS_DIR/nexus-write.env"; printf 'NEXUS_REPO=%s\n' "${NEXUS_REPO:-schultz-releases-raw}"; } > "$KEYS_DIR/nexus.env"
  chmod 600 "$KEYS_DIR/nexus.env"
  nexus_creds_work && status "nexus" "$NEXUS_URL" "scoped yocto-ci account ready + verified" \
                   || { echo "  nexus: credentials do NOT authenticate" >&2; return 1; }
}

# ── main ─────────────────────────────────────────────────────────────────────
[ -d "$K3S_CREDS" ] || { echo "no k3s credentials dir at $K3S_CREDS (set K3S_CREDS=)" >&2; exit 1; }

echo "==== bootstrap credentials -> $KEYS_DIR ===="
rc=0
wants dtrack     && { bootstrap_dtrack     || rc=1; }
wants defectdojo && { bootstrap_defectdojo || rc=1; }
wants nexus      && { bootstrap_nexus      || rc=1; }

# The URL differs per consumer: the build host reaches Nexus by LAN name, while
# this Mac would happily use localhost. Rewrite rather than ship the wrong one.
if [ -n "$INSTALL_TO" ] && [ "$CHECK_ONLY" -eq 0 ]; then
  echo "==== installing to $INSTALL_TO:~/keys/ ===="
  for f in dtrack.env defectdojo.env nexus.env; do
    [ -f "$KEYS_DIR/$f" ] || continue
    sed 's|^NEXUS_URL=http://localhost:|NEXUS_URL=http://192.168.1.250:|' "$KEYS_DIR/$f" \
      | ssh "$INSTALL_TO" "umask 077; mkdir -p ~/keys; cat > ~/keys/$f.tmp && mv ~/keys/$f.tmp ~/keys/$f && echo '  installed $f'"
  done
fi

echo "==== done (rc=$rc) ===="
exit "$rc"
