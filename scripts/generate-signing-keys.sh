#!/usr/bin/env bash
# Generates DEVELOPMENT-ONLY signing key material for:
#   1. The IPK package feed (GPG key, used by the `sign_package_feed` class)
#   2. RAUC update bundles (self-signed x509 cert, used by a bundle recipe's
#      RAUC_KEY_FILE/RAUC_CERT_FILE)
#
# Output goes to ../keys/ (a sibling of this repo, NOT committed -- it's
# private key material, see .gitignore). Safe to re-run: skips anything that
# already exists.
#
# This is dev/learning signing material, not a real trust root. Rotate/
# regenerate before anything resembling production use.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS_DIR="$(dirname "$REPO_DIR")/keys"
mkdir -p "$KEYS_DIR"
chmod 700 "$KEYS_DIR"

# --- 1. GPG key for package feed signing ---
if gpg --list-secret-keys "schultz-dev" > /dev/null 2>&1; then
  echo "GPG key 'schultz-dev' already exists, skipping"
else
  PASSPHRASE_FILE="$KEYS_DIR/gpg-passphrase.txt"
  if [ ! -f "$PASSPHRASE_FILE" ]; then
    openssl rand -base64 24 > "$PASSPHRASE_FILE"
    chmod 600 "$PASSPHRASE_FILE"
  fi
  gpg --batch --pinentry-mode loopback --passphrase-file "$PASSPHRASE_FILE" \
    --quick-generate-key "schultz-dev (package feed signing)" rsa4096 sign 0
  echo "Generated GPG key 'schultz-dev' -- passphrase at $PASSPHRASE_FILE"
fi

# --- 2. RAUC bundle signing cert (self-signed, development-only) ---
if [ -f "$KEYS_DIR/development-1.key.pem" ]; then
  echo "RAUC dev keypair already exists, skipping"
else
  openssl req -x509 -newkey rsa:4096 -nodes \
    -keyout "$KEYS_DIR/development-1.key.pem" \
    -out "$KEYS_DIR/development-1.cert.pem" \
    -days 3650 \
    -subj "/O=theSchultzYocto/CN=rauc-development-1"
  chmod 600 "$KEYS_DIR/development-1.key.pem"
  echo "Generated RAUC dev keypair at $KEYS_DIR/development-1.{key,cert}.pem"
fi

echo
echo "Key material is in $KEYS_DIR (outside this repo, gitignored)."
echo "Dev-only signing material -- do not treat it as a real trust root."
