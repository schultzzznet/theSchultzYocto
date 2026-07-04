#!/usr/bin/env bash
# Installs the Ubuntu/Debian build packages Yocto needs (see
# docs/build-host-setup.md) plus whatever BitBake's HOSTTOOLS check turns up
# as missing. Idempotent -- apt-get install on already-present packages is a
# no-op. Requires passwordless sudo (confirmed available on rpi5g16nvme).
#
# Usage: ./scripts/remote-prereqs.sh

set -euo pipefail

sudo apt-get update -qq
sudo apt-get install -y -qq \
  build-essential chrpath cpio debianutils diffstat file gawk gcc git \
  iputils-ping libacl1 libcrypt-dev locales python3 python3-git \
  python3-jinja2 python3-pexpect python3-pip python3-subunit socat texinfo \
  unzip wget xz-utils zstd liblz4-tool python3-websockets

if ! locale --all-locales | grep -q en_US.utf8; then
  echo "en_US.UTF-8 UTF-8" | sudo tee -a /etc/locale.gen > /dev/null
  sudo locale-gen
fi

# Ubuntu 24.04 restricts unprivileged user namespaces by default (AppArmor
# hardening) -- BitBake's pseudo/fakeroot mechanism needs them, and fails
# with "User namespaces are not usable by BitBake, possibly due to
# AppArmor." Relaxing this only makes sense on a dedicated, non-shared build
# box (which this is) -- see
# https://discourse.ubuntu.com/t/ubuntu-24-04-lts-noble-numbat-release-notes/39890#unprivileged-user-namespace-restrictions
if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = "1" ]; then
  echo "kernel.apparmor_restrict_unprivileged_userns=0" | sudo tee /etc/sysctl.d/60-apparmor-namespace.conf > /dev/null
  sudo sysctl --system > /dev/null
fi

# cyclonedx-cli: converts Yocto's SPDX SBOM to CycloneDX before uploading to
# Dependency-Track (whose /api/v1/bom endpoint only accepts CycloneDX -- see
# scripts/upload-sbom.sh). Not packaged for apt; a single static binary from
# GitHub releases, checksum-verified. Arch-aware since docs/build-host-setup.md
# documents x86_64 fallback hosts (mbpi5g8no1/no2) alongside this aarch64 one.
if ! command -v cyclonedx-cli > /dev/null 2>&1; then
  CDXCLI_VERSION="0.32.0"
  case "$(uname -m)" in
    aarch64|arm64)
      CDXCLI_ASSET="cyclonedx-linux-arm64"
      CDXCLI_SHA256="abf0b7c5648a5b127791d691cad41f004aceea27c75bb42c9572fdc9694770cf"
      ;;
    x86_64|amd64)
      CDXCLI_ASSET="cyclonedx-linux-x64"
      CDXCLI_SHA256="454879e6a4a405c8a13bff49b8982adcb0596f3019b26b0811c66e4d7f0783e1"
      ;;
    *)
      echo "No known cyclonedx-cli build for $(uname -m) -- skipping, SBOM upload will fail" >&2
      CDXCLI_ASSET=""
      ;;
  esac
  if [ -n "${CDXCLI_ASSET:-}" ]; then
    CDXCLI_TMP="$(mktemp)"
    curl -sSL -o "$CDXCLI_TMP" \
      "https://github.com/CycloneDX/cyclonedx-cli/releases/download/v${CDXCLI_VERSION}/${CDXCLI_ASSET}"
    echo "${CDXCLI_SHA256}  ${CDXCLI_TMP}" | sha256sum -c -
    chmod +x "$CDXCLI_TMP"
    sudo mv "$CDXCLI_TMP" /usr/local/bin/cyclonedx-cli
  fi
fi

echo "Build host packages OK"
