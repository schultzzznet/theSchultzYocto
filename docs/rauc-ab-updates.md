# RAUC A/B updates on the Raspberry Pi 3 B+

This is the real thing: **atomic, rollback-safe OTA updates** for
`schultz-image-minimal` on `raspberrypi3-64`, built on U-Boot + RAUC, adapted
from meta-rauc-community's `meta-rauc-raspberrypi` reference. It's the follow-on
to the plain single-partition image in [first-build.md](first-build.md).

> **Status (2026-07-05):** fully *wired and built*; the final "does it actually
> boot and roll back on the board" proof is a hands-on step with a serial
> console (which is exactly what this doc walks through). Everything up to
> flashing is verified; the on-hardware behaviour is yours to confirm.

---

## The idea in one picture

Two complete copies of the rootfs (**slot A** and **slot B**). You're always
running one; updates are written to the *other*; a reboot switches over; if the
new one fails to boot, U-Boot automatically falls back. Nothing is ever patched
in place, so a bad update can't brick the device.

```
SD card (mmcblk0)
├─ p1  /boot   FAT   RPi firmware + u-boot.bin + kernel + dtbs   (shared)
├─ p2  rootfs_A  ext4   slot A  ← booted now
├─ p3  rootfs_B  ext4   slot B  ← next update lands here
├─ p4  /data     ext4   RAUC state + shared data        (survives updates)
└─ p5  /home     ext4   grows to fill the card

Boot flow:  RPi firmware → u-boot.bin → boot.scr
  reads env BOOT_ORDER="A B", BOOT_A_LEFT/BOOT_B_LEFT (tries, default 3)
  → picks the first slot with tries left, decrements it, boots that rootfs
  → boots with root=/dev/mmcblk0pN rauc.slot=X; the kernel is SHARED, loaded
    from the FAT /boot partition (only the rootfs is A/B in this reference)
  a successful boot resets the tries; running out of tries falls back to the other slot
```

`rauc` on the target flips `BOOT_ORDER` / resets the tries via `u-boot-fw-utils`
(`fw_setenv`), so the whole A/B decision lives in the U-Boot environment.

---

## 1. Build it

On the build host (this uses a **separate `build-rauc/`** dir so it never
disturbs the normal `build/` the daily scan uses):

```sh
./theSchultzYocto/scripts/setup-rauc-build.sh   # adds the rauc layers + U-Boot/systemd/dual-wic config
cd build-rauc
bitbake schultz-image-minimal   # → tmp/deploy/images/raspberrypi3-64/schultz-image-minimal-*.wic.bz2
bitbake schultz-bundle          # → schultz-bundle-raspberrypi3-64.raucb (signed update)
```

What the setup script layered on top of the normal config:
`RPI_USE_U_BOOT=1`, `ENABLE_UART=1`, `INIT_MANAGER=systemd`,
`WKS_FILE=sdimage-dual-raspberrypi.wks.in`, and `IMAGE_FSTYPES += ext4`. (This
scarthgap-era reference boots a shared kernel from `/boot`; only the rootfs is
A/B.) The A/B slots + our signing keyring come
from [recipes-core/rauc/](../recipes-core/rauc/); the bundle's `compatible`
string is pinned in [schultz-bundle.bb](../recipes-core/images/schultz-bundle.bb)
to match `system.conf` (a mismatch is the #1 reason `rauc install` refuses a
bundle).

**…or let it build itself.** You don't have to run those `bitbake` lines by
hand. [build-rauc-bundle.sh](../scripts/build-rauc-bundle.sh) runs the whole
image → bundle → **verify** → archive cycle, and the nightly
[daily-security-scan.sh](../scripts/daily-security-scan.sh) chains it as its
final stage (under the same one-build-at-a-time lock). So every recipe or CVE
change that refreshes `build/` also refreshes the flashable A/B image **and** the
signed bundle in `build-rauc/`, automatically. Each run verifies the bundle's
signature + `compatible` string *before* archiving it under a UTC timestamp in
`build-rauc/rauc-archive/` and repointing the stable `latest.*` symlinks — so
grabbing the freshest card never means chasing a timestamp:

```sh
scp <build-host>:build-rauc/rauc-archive/latest.wic.gz .   # newest A/B image
scp <build-host>:build-rauc/rauc-archive/latest.raucb  .   # newest signed bundle
```

Run it standalone any time with `./theSchultzYocto/scripts/build-rauc-bundle.sh`.
Skip it inside a scan with `SCHULTZ_BUILD_RAUC=0`; keep more/fewer archived sets
with `RAUC_ARCHIVE_KEEP=N` (default 5).

## 2. Flash it

Same as the plain image, but note it's now a **5-partition** card. Both A and B
are written with the same rootfs at flash time, so either can boot from the
start.

The build emits a **gzip**-compressed `.wic.gz` (not bzip2 — balenaEtcher
decompresses gzip *many* times faster than bz2, which is what made flashing feel
like it hung) alongside a `.wic.bmap`. Fastest option first:

```sh
# FASTEST — bmaptool writes only the used blocks and verifies as it goes; it
# auto-picks up the sibling .wic.bmap. (macOS: pipx install bmaptool;
# Debian/Ubuntu: sudo apt install bmap-tools.)
bmaptool copy schultz-ab-image.wic.gz /dev/rdiskN

# balenaEtcher: just point it at the .wic.gz — gzip unpacks quickly.

# Plain dd, decompressing on the fly (no bmap):
zcat schultz-ab-image.wic.gz | sudo dd of=/dev/rdiskN bs=4m

# Still holding the older .wic.bz2 and don't want to wait on Etcher? Unpack it
# once and flash the raw .wic (then Etcher/dd has nothing to decompress):
#   bunzip2 -k schultz-ab-image.wic.bz2   # -> schultz-ab-image.wic
```

> **Why a `.wic` and not an `.iso`?** An `.iso` (ISO 9660) is a read-only
> *optical-disc* filesystem; PC install ISOs boot through BIOS/UEFI El Torito. A
> Raspberry Pi doesn't boot that way — its GPU firmware reads a **FAT partition
> off a partitioned SD card**, so it needs a *raw disk image with a partition
> table*. That is exactly what a `.wic` is (here: 5 partitions — boot + rootfs
> A/B + data + home); an `.iso` simply wouldn't boot on a Pi. So the only real
> choice is the *compression wrapper* around the `.wic`, and we switched it from
> bzip2 to **gzip** to keep flashing quick. The `.bz2` you flashed earlier was
> perfectly valid — just slow to decompress.

## 3. First boot — with the serial console attached

This is where the serial console earns its keep (see
[serial-console.md](serial-console.md)). Power on and watch U-Boot:

```
...
Found valid RAUC slot A
...
schultz-image-minimal login:
```

Log in (`root`, empty password on a debug-tweaks build) and confirm RAUC sees
the bootloader and both slots:

```sh
rauc status
# Expect: booted slot 'A' (rootfs.0), the other slot 'B' (rootfs.1),
#         boot status good, and no keyring errors.
```

If `rauc status` shows the slots and a booted slot, the hard part works.

## 4. Do an update (A → B)

Build a fresh bundle (bump something first so you can tell the versions apart —
e.g. edit the image, or just rebuild), copy it to the Pi, and install:

```sh
# on the workstation / build host
scp schultz-bundle-raspberrypi3-64.raucb root@<pi-ip>:/tmp/

# on the Pi
rauc install /tmp/schultz-bundle-raspberrypi3-64.raucb   # writes to the INACTIVE slot (B)
reboot
```

After reboot, `rauc status` should show **booted slot 'B'**. You just did an
atomic OTA update — the running system was never touched, only the spare slot.

## 5. Prove the rollback

The safety net: if a freshly-installed slot can't boot, U-Boot exhausts its 3
tries and falls back to the known-good slot. To see it deliberately, mark the
current slot bad and reboot:

```sh
rauc status mark-bad          # marks the running slot as bad
reboot                        # U-Boot should boot the OTHER slot instead
```

`rauc status mark-good` (or a clean successful boot) restores confidence in a
slot. This is the whole point of A/B: **a bad update degrades to the previous
one instead of bricking.**

---

## Why the bundle is trusted (and only ours)

- The bundle is signed with `development-1.key.pem`
  (`scripts/generate-signing-keys.sh`, private half kept out of the repo).
- The device's keyring is `development-1.cert.pem`, installed to `/etc/rauc/`
  and referenced by `system.conf`'s `[keyring]`. `rauc install` verifies the
  signature against it, so **only bundles we signed are accepted**.
- The bundle and the system must share the same `compatible`
  (`theSchultzYocto-raspberrypi3-64`) — RAUC's guard against flashing a bundle
  built for a different device.

## Secure boot vs. signed updates — where the line honestly is

These sound similar and get conflated constantly. They are not the same thing,
and one of them the Pi 3 simply cannot do:

- **Signed, integrity-checked updates — yes, we have this.** `rauc install`
  verifies the bundle's signature against the on-device keyring and refuses
  anything we didn't sign, and the `verity` bundle format gives dm-verity
  block-level integrity of the slot's contents. That is real *update*
  authenticity + integrity: an attacker can't push you a tampered or
  third-party update.
- **Hardware secure boot — no, and not on this board.** "Secure boot" proper is
  a *verified chain* from the SoC boot ROM → bootloader → kernel, rooted in keys
  fused into the chip. The Raspberry Pi 3's boot ROM loads `bootcode.bin` /
  firmware / `u-boot.bin` from the FAT partition **unsigned** — there is no key
  fusing and no signature check anywhere in its boot path. Anyone with physical
  access to the SD card can alter `/boot` (or the rootfs) and the Pi will boot
  it. This is a **hardware ceiling, not a configuration gap**: only Pi 4/5 have
  even a limited signed-boot (bootloader EEPROM + a fused key), and full
  measured/attested boot wants a TPM the Pi 3 doesn't have.

The accurate one-liner: **RAUC here gives you update security (only your signed,
integrity-checked bundles install onto verified A/B slots), not boot-chain
attestation.** If this ever moves to a Pi 4/5, signed-boot becomes a real thing
to layer underneath; on a Pi 3 it's out of reach and worth stating plainly
rather than implying otherwise.

## Troubleshooting (serial console is your friend)

| Symptom | Likely cause / fix |
|---|---|
| Black screen, nothing on serial | RPi firmware not finding `u-boot.bin` / bad flash → re-flash; check the FAT partition has `u-boot.bin` + `config.txt` |
| U-Boot loops "No valid RAUC slot found" | both slots out of tries → it resets tries to 3 and retries; if persistent, the kernel/rootfs in the slot isn't booting (watch the kernel log) |
| `rauc install` → "compatible mismatch" | bundle `RAUC_BUNDLE_COMPATIBLE` ≠ system `compatible` — both must be `theSchultzYocto-raspberrypi3-64` |
| `rauc install` → signature/keyring error | device keyring isn't the cert that signed the bundle — rebuild the image so `/etc/rauc/development-1.cert.pem` matches your signing key |
| Update installs but won't boot | that's the rollback case — let it fall back to the good slot, then debug the new slot over serial |

## Honest caveats

- This follows a *demo* reference layer; it's a great learning setup, not a
  hardened production update system (no bootloader-env redundancy, dev keys,
  single SD card).
- A/B doubles rootfs space — fine on any reasonable SD card for this minimal
  image, but worth knowing.
- Everything here is built and internally consistent; the boot/rollback
  behaviour is confirmed *by you, on the board, over serial*. There is genuinely
  no substitute for that last step — which is the fun part.
