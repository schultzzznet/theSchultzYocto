SUMMARY = "Hardened, immutable variant of schultz-image-minimal (opt-in)"
DESCRIPTION = "schultz-image-minimal with the attack surface locked down: no \
debug-tweaks (so NO empty root password / passwordless SSH), a read-only root \
filesystem, and shipped as squashfs so the running root literally cannot be \
remounted read-write. For a fielded device, NOT the learning sandbox. See the \
'Hardened variant' section of docs/rauc-ab-updates.md for the boot-time caveats \
(raw slot type, per-device SSH host keys, and the login credential you must add)."

require recipes-core/images/schultz-image-minimal.bb

# 1. Drop debug-tweaks -- removes the empty root password + passwordless SSH the
#    learning image ships. IMPORTANT: with debug-tweaks gone and no other
#    credential, root login is LOCKED (secure, but you can't get in). A real
#    deployment MUST add auth -- an SSH authorized_keys (preferred) or a hashed
#    root password. Deliberately not baked in here (committing a key/password
#    would be worse). Example: ship a small recipe that installs
#    /home/root/.ssh/authorized_keys and add it via:
#      # IMAGE_INSTALL:append = " my-authorized-keys"
IMAGE_FEATURES:remove = "debug-tweaks"

# 2. Immutable root. read-only-rootfs mounts / read-only and wires up tmpfs for
#    the few dirs that must be writable at runtime (/var/volatile, etc.).
#    Persistent, must-survive-reboot state belongs on the separate /data (p4)
#    and /home (p5) partitions the A/B layout already provides.
IMAGE_FEATURES += "read-only-rootfs"

# 3. Ship the rootfs as squashfs. Unlike ext4 mounted read-only (which root can
#    `mount -o remount,rw /` to defeat), squashfs is read-only at the FORMAT
#    level -- there is no write path in the on-disk format, so it cannot be
#    remounted rw. RAUC writes it to the A/B slot block-for-block (no mkfs on
#    target -- squashfs sidesteps the mkfs.ext4 gap the ext4 slot works around),
#    and it is compressed, so the slot image is smaller too.
#
#    Restrict to squashfs only: the base build-rauc/local.conf appends
#    ext4/wic.gz/wic.bmap (for the flashable A/B SD image); the bundle only
#    needs the squashfs artifact, so strip the rest here to keep the build lean.
IMAGE_FSTYPES = "squashfs"
IMAGE_FSTYPES:remove = "ext4 wic wic.gz wic.bz2 wic.bmap tar.bz2"

# NOTE (per-device SSH host keys): read-only-rootfs bakes the SSH host keys at
# BUILD time (they can't be generated into a read-only /etc at first boot), so
# every device from this image would share the same host keys. For per-device
# keys, persist /etc/ssh onto /data and regenerate on first boot -- see
# docs/rauc-ab-updates.md.
