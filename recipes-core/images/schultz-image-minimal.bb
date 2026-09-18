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

# nano/htop would be nice but live in meta-openembedded (meta-oe), which
# isn't one of our layers -- build failed with "Nothing RPROVIDES 'nano'"
# when this tried IMAGE_INSTALL:append = " nano htop". busybox (already in
# core-image-minimal) provides `vi` and `top` in the meantime. Add
# meta-openembedded as a layer if you want the real things.
