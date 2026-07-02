SUMMARY = "Minimal headless learning image for Raspberry Pi 3 (raspberrypi3-64)"
DESCRIPTION = "core-image-minimal plus SSH access and a couple of basic \
tools. A small sandbox for learning Yocto/BitBake, not a production image."

require recipes-core/images/core-image-minimal.bb

IMAGE_FEATURES += "ssh-server-openssh debug-tweaks"

IMAGE_INSTALL:append = " nano htop"
