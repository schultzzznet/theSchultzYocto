SUMMARY = "Minimal headless learning image for Raspberry Pi 3 (raspberrypi3-64)"
DESCRIPTION = "core-image-minimal plus SSH access. A small sandbox for \
learning Yocto/BitBake, not a production image."

require recipes-core/images/core-image-minimal.bb

# wrynose: debug-tweaks was split into individual features. All three are
# required for a real passwordless login -- allow-empty-password/
# allow-root-login only let sshd/dropbear ACCEPT an empty password; without
# empty-root-password the rootfs postprocessing FORCES a random (unknown,
# unrecoverable) password into /etc/shadow regardless. Missing this one is
# what makes root login fail everywhere (serial console included) with no
# password that could ever work -- confirmed on real hardware 2026-08-30.
IMAGE_FEATURES += "ssh-server-openssh allow-empty-password allow-root-login empty-root-password"

# --- Name the board after its image, not its SoC -----------------------------
# base-files defaults the hostname to ${MACHINE}, so every board built from this
# layer calls itself "raspberrypi3-64". That is not merely unhelpful, it breaks
# name resolution: the router runs unicast DNS populated from DHCP option 12 --
# the name each client announces -- so two boards running images from this layer
# register TWO A records under the same name and every lookup is a coin flip.
# Measured 2026-09-18:
#     dig @192.168.1.1 raspberrypi3-64  ->  192.168.1.225
#                                           192.168.1.226
# which is exactly as confusing as it sounds, and cost real time twice.
# (Not mDNS -- these images ship no avahi/mdnsd, nothing listens on :5353, and
# the .local form does not resolve. The router's static-lease Hostname labels
# are decorative: they resolve to nothing. Only the announced name is published,
# so the fix has to live in the image.)
#
# Defaults to the image's own name, which keeps sibling images distinct without
# anyone maintaining a list; override per image for something friendlier.
# Still a fixed string: the same image on two boards collides again. A
# serial-derived suffix (/proc/device-tree/serial-number, whose last 6 hex are
# also the MAC tail) is the answer if that ever happens.
SCHULTZ_HOSTNAME ?= "${IMAGE_BASENAME}"
schultz_set_hostname() {
    echo "${SCHULTZ_HOSTNAME}" > ${IMAGE_ROOTFS}${sysconfdir}/hostname
    sed -i "s/${MACHINE}/${SCHULTZ_HOSTNAME}/g" ${IMAGE_ROOTFS}${sysconfdir}/hosts
}
ROOTFS_POSTPROCESS_COMMAND += "schultz_set_hostname;"

# --- Stamp the artefact filename with what it actually is --------------------
# The default is <image>-<machine>.rootfs-<distro>, identical for every build
# ever made. Six images came out of 2026-09-18 and telling them apart meant
# renaming files by hand on the way to the SD card.
#
# Now <hostname>-<machine>-<distro>-<gitrev>.rootfs, so a .wic.gz in a Downloads
# folder or already written to a card can be traced to a commit without booting
# it. "-dirty" is appended when the build tree has uncommitted changes --
# without it the stamp would lie in exactly the case where it matters most.
#
# THISDIR is the dir of the recipe being parsed, so an image defined in another
# layer stamps THAT layer's revision, which is the useful one.
#
# IMAGE_LINK_NAME is deliberately NOT touched. cut-release.sh:158 and
# upload-sbom.sh:50 both look up "${IMAGE}-${MACHINE}.rootfs.<ext>", which is the
# link name -- checked before making this change, and they keep working.
def schultz_git_rev(d):
    import bb.process
    try:
        rev, _ = bb.process.run('git rev-parse --short HEAD', cwd=d.getVar('THISDIR'))
        rev = rev.strip()
        dirty, _ = bb.process.run('git status --porcelain', cwd=d.getVar('THISDIR'))
        return rev + ('-dirty' if dirty.strip() else '')
    except Exception:
        return 'nogit'

SCHULTZ_GIT_REV ?= "${@schultz_git_rev(d)}"
IMAGE_NAME = "${SCHULTZ_HOSTNAME}-${MACHINE}-${DISTRO_VERSION}-${SCHULTZ_GIT_REV}${IMAGE_NAME_SUFFIX}"

# The revision NAMES the artefact; it does not change its contents, so it must
# not take part in task signatures. Without these two lines bitbake computes a
# basehash for do_image_* at first parse, gets a different one when the worker
# reparses after the rev changes, and fails the whole build with 164 copies of
#   "the basehash value changed ... metadata is not deterministic"
# while still producing a correct image -- exit 1 with the artefact sitting
# there, which is the worst of both. Hit 2026-09-19 the first time a build
# spanned a commit (dirty -> clean).
#
# Same treatment oe-core gives DATETIME in its own IMAGE_NAME, and for the same
# reason: a stamp that is allowed to vary per build cannot be allowed to
# invalidate the build.
SCHULTZ_GIT_REV[vardepvalue] = "fixed"
IMAGE_NAME[vardepsexclude] += "SCHULTZ_GIT_REV"

# nano/htop would be nice but live in meta-openembedded (meta-oe), which
# isn't one of our layers -- build failed with "Nothing RPROVIDES 'nano'"
# when this tried IMAGE_INSTALL:append = " nano htop". busybox (already in
# core-image-minimal) provides `vi` and `top` in the meantime. Add
# meta-openembedded as a layer if you want the real things.

# --- ADR-0015: the image is immutable, state lives on /data ------------------
# Four things wrote to the rootfs, found by diffing a booted board against the
# built image rather than by reading recipes:
#
#   /etc/ssh/ssh_host_*              absent from the image, made at first boot
#   /etc/machine-id                  0 bytes in the image, filled by systemd
#   /var/lib/systemd/timesync/clock  rewritten PERIODICALLY -- the risky one
#   /etc/resolv.conf                 symlink into /etc, written on lease
#
# schultz-persistent-state binds the first and third from /data. machine-id is
# deliberately left transient: systemd reads it as PID 1, before any unit could
# bind over it, so fleet identity must come from the SoC serial
# (/proc/device-tree/serial-number) instead -- which also survives a reflash.
IMAGE_INSTALL:append = " schultz-persistent-state"

# The bind mount hides whatever the image shipped in /etc/ssh, so sshd's config
# is stashed where the boot script can copy it back. Done here rather than in
# the recipe because only the image can see another package's files.
schultz_stash_ssh_config() {
    if [ -d ${IMAGE_ROOTFS}${sysconfdir}/ssh ]; then
        mkdir -p ${IMAGE_ROOTFS}${datadir}/schultz-state/ssh
        for f in ${IMAGE_ROOTFS}${sysconfdir}/ssh/*; do
            [ -f "$f" ] || continue
            cp -a "$f" ${IMAGE_ROOTFS}${datadir}/schultz-state/ssh/
        done
    fi
}
ROOTFS_POSTPROCESS_COMMAND += "schultz_stash_ssh_config;"

# squashfs is what makes the image immutable rather than merely asked not to be
# written, and it compresses, which shrinks the RAUC bundle too. Built
# unconditionally: cut-release.sh has looked for this artefact since it was
# written and has never once found it.
IMAGE_FSTYPES += "squashfs"

# Flipping the rootfs read-only is deliberately a separate switch from shipping
# the mechanism above. Turn it on only once a board has been seen to keep its
# ssh host keys across a reflash -- otherwise a failure to persist state and a
# failure to boot read-only are indistinguishable, and you debug both at once.
SCHULTZ_READ_ONLY_ROOTFS ?= "0"
IMAGE_FEATURES += "${@bb.utils.contains('SCHULTZ_READ_ONLY_ROOTFS', '1', 'read-only-rootfs', '', d)}"

