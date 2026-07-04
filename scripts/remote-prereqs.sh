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

echo "Build host packages OK"
