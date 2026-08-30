#!/usr/bin/env bash
# Single source of truth for WHICH Yocto release the build pipeline drives.
# Sourced (never executed) by every script that runs bitbake or reads its output.
#
# WHY THIS EXISTS. Before this file, "poky/oe-init-build-env", "build",
# "build-rauc" and the cve-check report path were hardcoded in ~13 places across
# 8 scripts. Migrating meant editing all of them consistently, and a partial edit
# is exactly what broke the nightly cron twice on 2026-08-29 (a script sourcing
# wrynose's bitbake 2.18 against a scarthgap build dir). Now the release is one
# variable, and rolling back is the same one-line edit -- both trees stay on
# disk, so a rollback needs no rebuild.
#
# Override for a single invocation without editing anything:
#   SCHULTZ_RELEASE=scarthgap ./scripts/build-rauc-bundle.sh

SCHULTZ_RELEASE="${SCHULTZ_RELEASE:-wrynose}"

case "$SCHULTZ_RELEASE" in
  scarthgap)
    SCHULTZ_OE_INIT="poky/oe-init-build-env"
    SCHULTZ_BUILD="build"
    SCHULTZ_RAUC_BUILD="build-rauc"
    SCHULTZ_DISTRO_CONF="poky/meta-poky/conf/distro/poky.conf"
    SCHULTZ_HASHSERV_BIN="poky/bitbake/bin/bitbake-hashserv"
    # <dir>:<branch> — a layer is only pulled when it is on exactly this branch,
    # so a pinned or detached layer is never silently moved.
    SCHULTZ_LTS_LAYERS="poky:scarthgap meta-raspberrypi:scarthgap meta-rauc:scarthgap"
    SCHULTZ_PROVENANCE_LAYERS="poky meta-raspberrypi meta-rauc meta-rauc-community theSchultzYocto"
    SCHULTZ_RAUC_COMMUNITY="meta-rauc-community"
    # meta-rauc-community has no scarthgap-compatible branch head: b28c04a is the
    # newest master commit whose meta-rauc-raspberrypi still lists scarthgap in
    # LAYERSERIES_COMPAT. Do NOT move this to upstream's `scarthgap` branch --
    # it hard-depends on lts-u-boot-mixin (u-boot 2025.04), which silently breaks
    # A/B on the Pi 3 B+ (see fetch-rauc-layers.sh).
    SCHULTZ_RAUC_COMMUNITY_REV="b28c04a"    # Where the BSP/RAUC layers for this release live, relative to the work dir.
    SCHULTZ_LAYER_DIR="."
    ;;
  wrynose)
    # Wrynose retired the `poky` bundle: oe-init-build-env now lives in
    # openembedded-core, and bitbake/meta-yocto are separate repos on their own
    # branches (bitbake tracks 2.18, not "wrynose").
    SCHULTZ_OE_INIT="openembedded-core/oe-init-build-env"
    SCHULTZ_BUILD="build-wrynose"
    SCHULTZ_RAUC_BUILD="build-rauc-wrynose"
    SCHULTZ_DISTRO_CONF="meta-yocto/meta-poky/conf/distro/poky.conf"
    SCHULTZ_HASHSERV_BIN="bitbake/bin/bitbake-hashserv"
    SCHULTZ_LTS_LAYERS="openembedded-core:wrynose bitbake:2.18 meta-yocto:wrynose wrynose-layers/meta-raspberrypi:wrynose wrynose-layers/meta-rauc:wrynose"
    SCHULTZ_PROVENANCE_LAYERS="openembedded-core bitbake meta-yocto wrynose-layers/meta-raspberrypi wrynose-layers/meta-rauc wrynose-layers/meta-rauc-community theSchultzYocto"
    SCHULTZ_RAUC_COMMUNITY="wrynose-layers/meta-rauc-community"
    # master is the wrynose-targeting line; it drops the lts-u-boot-mixin
    # dependency and builds against oe-core's stock u-boot 2026.01, which was
    # proven on hardware 2026-08-30 (full A -> B -> A rollback).
    SCHULTZ_RAUC_COMMUNITY_REV="master"    # Kept out of the top-level siblings so a scarthgap tree can coexist:
    # sharing meta-raspberrypi/meta-rauc between two series broke the nightly
    # cron on 2026-08-29 ("Layer raspberrypi is not compatible with the core
    # layer which only supports these series: scarthgap").
    SCHULTZ_LAYER_DIR="wrynose-layers"
    ;;
  *)
    echo "unknown SCHULTZ_RELEASE '$SCHULTZ_RELEASE' (expected: scarthgap|wrynose)" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

# Where the per-package CVE data lands. scarthgap's cve-check writes one fixed
# path under tmp/log; wrynose's sbom-cve-check fragment writes it beside the
# image, named after it. The two files have the same `package[].issue[]` shape,
# so manifest-to-cyclonedx.py / manifest-to-vex.py consume either unchanged.
# Usage: schultz_cve_report <work_dir> <build_subdir> <image_name> [machine]
schultz_cve_report() {
  local work="$1" sub="$2" image="$3" machine="${4:-raspberrypi3-64}"
  case "$SCHULTZ_RELEASE" in
    scarthgap) echo "$work/$sub/tmp/log/cve/cve-summary.json" ;;
    wrynose)   echo "$work/$sub/tmp/deploy/images/$machine/${image}-${machine}.rootfs.sbom-cve-check.yocto.json" ;;
  esac
}

# One lock for every heavy build, independent of release: the host has 4 cores
# and must never run two bitbakes at once, not even one per release.
SCHULTZ_BUILD_LOCK="${SCHULTZ_BUILD_LOCK:-.schultz-build.lock}"

# Caches are shared by EVERY build dir and every release — they are pure caches,
# and DL_DIR/SSTATE_DIR are in BB_BASEHASH_IGNORE_VARS so their location never
# affects a task hash. Four private copies cost ~36 GB of duplicated downloads
# before this was consolidated. Release-independent on purpose: scarthgap and
# wrynose sstate coexist happily, each keyed by its own unihashes.
SCHULTZ_DL_DIR="${SCHULTZ_DL_DIR:-yocto-downloads}"
SCHULTZ_SSTATE_DIR="${SCHULTZ_SSTATE_DIR:-yocto-sstate}"
