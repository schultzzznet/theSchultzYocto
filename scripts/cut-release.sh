#!/usr/bin/env bash
# Cut an immutable, versioned theSchultzYocto release -- the whole flow in ONE
# command, ON THE BUILD HOST, so all source arrives via git (never scp/rsync).
#
# Typical use (after pushing your version bump from the workstation):
#   ssh rpi5g16nvme '~/theSchultzYocto/scripts/cut-release.sh'
#
# Steps:
#   1. git pull --ff-only        -- pick up the version bump you pushed to origin
#   2. read the version          -- RAUC_BUNDLE_VERSION is the single source of
#                                   truth; warn if IMAGE_VERSION (os-release) differs
#   3. bitbake image + bundle    -- the A/B .wic.gz + signed .raucb (build-rauc)
#   4. verify                    -- rauc info Version == release + valid signature
#   5. Dependency-Track snapshot -- upload-sbom.sh on the build-rauc A/B image,
#                                   as an immutable DT project version <version>
#   6. archive                   -- bundle + image + SBOM + VEX + PROVENANCE.txt
#                                   under build-rauc/releases/<version>/
#   7. git tag v<version>        -- annotated; pushed to origin (best-effort)
#
# Options:  --no-build  --no-tag  --no-pull  [VERSION-override]
# Idempotent: re-running a version re-snapshots DT + re-archives and skips an
# already-existing tag.

set -uo pipefail
export HOME="${HOME:-/home/$(id -un)}"
export LC_ALL="${LC_ALL:-C.UTF-8}" LANG="${LANG:-C.UTF-8}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(dirname "$REPO_DIR")"
MACHINE="raspberrypi3-64"
IMAGE="schultz-image-minimal"
BUNDLE="schultz-bundle"
IMAGES_DIR="$WORK_DIR/build-rauc/tmp/deploy/images/$MACHINE"

DO_BUILD=1 DO_TAG=1 DO_PULL=1 VERSION_OVERRIDE=""
for a in "$@"; do
  case "$a" in
    --no-build) DO_BUILD=0 ;;
    --no-tag)   DO_TAG=0 ;;
    --no-pull)  DO_PULL=0 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *)  VERSION_OVERRIDE="$a" ;;
  esac
done

read_var() { # read_var <file> <VAR>  -> the "quoted value"
  sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\1/p" "$1" 2>/dev/null | head -1
}

# 1. Pick up the version bump pushed from the workstation.
if [ "$DO_PULL" = 1 ] && [ -d "$REPO_DIR/.git" ]; then
  echo "-- git pull --ff-only --"
  git -C "$REPO_DIR" pull --ff-only || echo "git pull skipped/failed; using current tree"
fi

# 2. Version = RAUC_BUNDLE_VERSION (single source of truth) unless overridden.
BUNDLE_VER="$(read_var "$REPO_DIR/recipes-core/images/schultz-bundle.bb" RAUC_BUNDLE_VERSION)"
IMAGE_VER="$(read_var "$REPO_DIR/recipes-core/os-release/os-release.bbappend" IMAGE_VERSION)"
VERSION="${VERSION_OVERRIDE:-$BUNDLE_VER}"
[ -n "$VERSION" ] || { echo "could not read a release version from schultz-bundle.bb" >&2; exit 1; }
if [ -n "$IMAGE_VER" ] && [ "$IMAGE_VER" != "$VERSION" ]; then
  echo "WARNING: os-release IMAGE_VERSION ($IMAGE_VER) != release ($VERSION); bump both to match." >&2
fi
echo "==== cutting release $VERSION ===="

# oe-init-build-env is not set -u safe.
set +u
# shellcheck disable=SC1091
source "$WORK_DIR/poky/oe-init-build-env" "$WORK_DIR/build-rauc" >/dev/null 2>&1
set -u

# 3. Build the A/B image + signed bundle.
if [ "$DO_BUILD" = 1 ]; then
  echo "-- bitbake $BUNDLE --"
  bitbake "$BUNDLE" || { echo "build FAILED" >&2; exit 1; }
fi
RAUCB="$IMAGES_DIR/${BUNDLE}-${MACHINE}.raucb"
[ -f "$RAUCB" ] || { echo "no bundle at $RAUCB -- build first (drop --no-build)" >&2; exit 1; }

# 4. Verify: signature valid + bundle Version equals the release version.
RN="$(find "$WORK_DIR/build-rauc/tmp" -path '*rauc-native*/usr/bin/rauc' -type f 2>/dev/null | head -1)"
CT="$(find "$REPO_DIR" -name 'development-1.cert.pem' 2>/dev/null | head -1)"
if [ -x "$RN" ] && [ -n "$CT" ]; then
  INFO_VER="$("$RN" info --keyring="$CT" "$RAUCB" 2>/dev/null | sed -nE "s/^Version:[[:space:]]*'([^']+)'.*/\1/p" | head -1)"
  [ "$INFO_VER" = "$VERSION" ] || { echo "bundle Version '$INFO_VER' != '$VERSION' -- bump RAUC_BUNDLE_VERSION and rebuild" >&2; exit 1; }
  echo "verified: signed bundle, Version $INFO_VER"
fi

# 5 + 6. Dependency-Track snapshot + archive of the build-rauc A/B image.
R="$WORK_DIR/build-rauc/releases/$VERSION"
mkdir -p "$R"
[ -f "$WORK_DIR/keys/dtrack.env" ] && { set -a; . "$WORK_DIR/keys/dtrack.env"; set +a; }
if [ -n "${DTRACK_URL:-}" ] && [ -f "$WORK_DIR/keys/dtrack-api-key" ]; then
  export DTRACK_API_KEY="$(cat "$WORK_DIR/keys/dtrack-api-key")"
  export SCHULTZ_BUILD_SUBDIR="build-rauc"
  export DTRACK_PROJECT_VERSION="$VERSION"
  export SBOM_ARCHIVE_DIR="$R"
  echo "-- Dependency-Track snapshot as $VERSION --"
  "$REPO_DIR/scripts/upload-sbom.sh" || echo "DT snapshot failed (continuing archive)"
else
  echo "no DT creds (keys/dtrack.env + keys/dtrack-api-key) -- skipping DT snapshot"
fi

cp -Lf "$RAUCB" "$R/${BUNDLE}-${VERSION}.raucb"
for ext in wic.gz wic.bz2; do
  SRC="$IMAGES_DIR/${IMAGE}-${MACHINE}.rootfs.$ext"
  [ -f "$SRC" ] && { cp -Lf "$SRC" "$R/schultz-ab-image-${VERSION}.$ext"; break; }
done
{
  echo "theSchultzYocto -- release $VERSION (scarthgap) -- $MACHINE"
  echo "Ubuntu-style CalVer; built on Yocto $(read_var "$WORK_DIR/poky/meta-poky/conf/distro/poky.conf" DISTRO_VERSION) scarthgap (LTS)."
  echo
  echo "Layer commits (reproducible pin):"
  for l in poky meta-raspberrypi meta-rauc meta-rauc-community theSchultzYocto; do
    [ -d "$WORK_DIR/$l/.git" ] && printf "  %-20s : %s\n" "$l" "$(git -C "$WORK_DIR/$l" rev-parse HEAD)"
  done
  echo
  echo "rauc bundle Version: $VERSION"
  echo "Artifacts (sha256):"
  (cd "$R" && sha256sum ./*.raucb ./*.wic.* 2>/dev/null)
} > "$R/PROVENANCE.txt"
echo "archived -> $R"

# 6b. Publish to Nexus (raw hosted repo) so devices pull the release from a
#     stable URL: rauc install http://nexus/.../schultz-bundle-<v>.raucb. Nexus
#     honours HTTP range requests, so RAUC *streams* into the slot (unlike a
#     plain python http.server). Best-effort: needs keys/nexus.env; the repo is
#     immutable (ALLOW_ONCE), so already-published files are skipped.
[ -f "$WORK_DIR/keys/nexus.env" ] && { set -a; . "$WORK_DIR/keys/nexus.env"; set +a; }
if [ -n "${NEXUS_URL:-}" ] && [ -n "${NEXUS_WRITE_USER:-}" ] && [ -n "${NEXUS_WRITE_PASS:-}" ]; then
  NREPO="${NEXUS_REPO:-schultz-releases-raw}"
  NBASE="$NEXUS_URL/repository/$NREPO/theSchultzYocto/$VERSION"
  echo "-- publishing to Nexus: $NBASE --"
  for f in "$R"/*; do
    n="$(basename "$f")"
    if curl -sfI -o /dev/null "$NBASE/$n"; then
      echo "   = $n already published (immutable) -- skip"
    elif curl -sf -u "$NEXUS_WRITE_USER:$NEXUS_WRITE_PASS" --upload-file "$f" "$NBASE/$n" -o /dev/null; then
      echo "   + $n"
    else
      echo "   ! failed to publish $n (continuing)"
    fi
  done
  echo "Nexus release URL: $NBASE/${BUNDLE}-${VERSION}.raucb"
else
  echo "no Nexus creds (keys/nexus.env) -- skipping publish (OTA can still use --local)"
fi

# 7. Tag the exact source state (best-effort push to origin).
if [ "$DO_TAG" = 1 ] && [ -d "$REPO_DIR/.git" ]; then
  TAG="v$VERSION"
  if git -C "$REPO_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "tag $TAG already exists -- not re-tagging"
  else
    git -C "$REPO_DIR" tag -a "$TAG" \
      -m "theSchultzYocto $VERSION (scarthgap)" \
      -m "Signed RAUC A/B release on Yocto LTS. See build-rauc/releases/$VERSION/PROVENANCE.txt."
    if git -C "$REPO_DIR" push origin "$TAG" 2>/dev/null; then
      echo "tagged + pushed $TAG"
    else
      echo "tag $TAG created locally; run 'git push origin $TAG' from a machine with write access"
    fi
  fi
fi

echo "==== release $VERSION ready: $R ===="
echo "Deploy it OTA with:  scripts/ota-deploy.sh $VERSION <device-ip> --reboot"
