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

# nano/htop would be nice but live in meta-openembedded (meta-oe), which
# isn't one of our layers -- build failed with "Nothing RPROVIDES 'nano'"
# when this tried IMAGE_INSTALL:append = " nano htop". busybox (already in
# core-image-minimal) provides `vi` and `top` in the meantime. Add
# meta-openembedded as a layer if you want the real things.
