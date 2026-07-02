SUMMARY = "Minimal headless learning image for Raspberry Pi 3 (raspberrypi3-64)"
DESCRIPTION = "core-image-minimal plus SSH access. A small sandbox for \
learning Yocto/BitBake, not a production image."

require recipes-core/images/core-image-minimal.bb

IMAGE_FEATURES += "ssh-server-openssh debug-tweaks"

# nano/htop would be nice but live in meta-openembedded (meta-oe), which
# isn't one of our layers -- build failed with "Nothing RPROVIDES 'nano'"
# when this tried IMAGE_INSTALL:append = " nano htop". busybox (already in
# core-image-minimal) provides `vi` and `top` in the meantime. Add
# meta-openembedded as a layer if you want the real things.
