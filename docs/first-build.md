# First build: zero to a booted SD card

## Fast path

From this repo, on your Mac:

```sh
./scripts/deploy.sh
```

This runs `sync-to-host.sh` (pushes the repo to `rpi5g16nvme` via git over
ssh -- no scp/rsync) and then `remote-build.sh` on the host, which fetches
poky + meta-raspberrypi if missing, bootstraps the build dir if missing,
sanity-checks the layers, and launches `bitbake schultz-image-minimal` fully
detached (survives SSH disconnects). Follow along with:

```sh
ssh rpi5g16nvme 'tail -f build/schultz-build.log'
```

Safe to re-run after making changes -- it just syncs and re-triggers the
build. The rest of this doc is the manual, step-by-step version of exactly
what those two scripts do, for troubleshooting or actually understanding
what's happening.

Assumes the build host is already set up per
[build-host-setup.md](build-host-setup.md).

## 0. Get this repo onto the build host

From this repo, on your Mac (passwordless SSH already set up as
`rpi5g16nvme`). This uses git, not scp/rsync -- see
[sync-to-host.sh](../scripts/sync-to-host.sh):

```sh
./scripts/sync-to-host.sh
ssh rpi5g16nvme
cd theSchultzYocto
```

Everything from here on runs on `rpi5g16nvme`, not on the Mac.

## 1. Fetch the layers

```sh
./scripts/fetch-layers.sh
```

This clones `poky` and `meta-raspberrypi` (both on the `scarthgap` branch —
Yocto 5.0 LTS; verified 2026-07-02 that neither repo has a `wrynose` branch
yet, despite the official docs' example using one) as siblings of this repo.
Resulting layout:

```
<workdir>/
├── poky/
├── meta-raspberrypi/
└── theSchultzYocto/   <- this repo
```

If you'd rather do it by hand:

```sh
git clone -b scarthgap https://git.yoctoproject.org/poky
git clone -b scarthgap https://git.yoctoproject.org/meta-raspberrypi
```

(Check `git ls-remote --heads <repo-url>` if you want to try `wrynose` later —
it may get its own branch once Yocto 6.0 is a bit more settled.)

## 2. Bootstrap the build directory

From `<workdir>` (the parent of `poky/`, `meta-raspberrypi/` and
`theSchultzYocto/`):

```sh
TEMPLATECONF="$PWD/theSchultzYocto/conf/templates/schultz" \
  source poky/oe-init-build-env build
```

This creates `build/` and populates `build/conf/local.conf` and
`build/conf/bblayers.conf` from this repo's templates. Every new shell after
this, just re-source the environment (no `TEMPLATECONF` needed once
`build/conf` already exists):

```sh
source poky/oe-init-build-env build
```

Sanity check the layers are wired up:

```sh
bitbake-layers show-layers
```

You should see `core`, `yocto`, `raspberrypi`, and `schultz` listed.

## 3. Non-free firmware heads-up

Raspberry Pi boards need closed-source firmware blobs (VideoCore GPU,
Wi-Fi/Bluetooth) that `meta-raspberrypi` pulls in for you, but BitBake refuses
to build them until you explicitly accept their license flags. If you hit an
error like `... has a restricted license 'xxx' which is not listed in your
LICENSE_FLAGS_ACCEPTED`, add the flag(s) it names to `build/conf/local.conf`,
e.g.:

```
LICENSE_FLAGS_ACCEPTED = "synaptics-killswitch"
```

Check `meta-raspberrypi`'s README/docs for the exact value(s) needed for
`raspberrypi3-64` specifically — it varies by machine and release.

## 4. Build

```sh
bitbake schultz-image-minimal
```

This is a full first-time build — it compiles a cross-toolchain and an
entire small Linux distribution from source. Expect it to take a while,
especially on a memory-constrained host (see
[build-host-setup.md](build-host-setup.md)). Subsequent builds reuse
`sstate-cache` and are much faster.

Running this directly like that ties it to your SSH session. `remote-build.sh`
runs the equivalent build wrapped in `setsid nohup ... & disown`, logged to
`build/schultz-build.log`, so it survives disconnects -- worth doing manually
the same way if you're not using the script.

For checking on a build that's already running in the background, and what
to do if the build host reboots or otherwise dies mid-build, see
[build-operations.md](build-operations.md).

## 5. Flash the SD card

```sh
cd tmp/deploy/images/raspberrypi3-64/
bmaptool copy schultz-image-minimal-raspberrypi3-64.rootfs.wic.bz2 /dev/sdX
```

Replace `/dev/sdX` with your SD card's actual device (double, triple check
this — it's a raw overwrite of the whole disk).

## 6. Boot

Insert the card into the Pi 3 B+ and power it on. `debug-tweaks` is enabled,
so you can log in as `root` with no password, either:

- over the serial console (UART pins), or
- over SSH once it's on the network: `ssh root@<ip>` — check your router's
  DHCP leases, or log in over serial first to find the IP.

## Where to go from here

- Add/remove packages in `recipes-core/images/schultz-image-minimal.bb` via
  `IMAGE_INSTALL:append`.
- Write your own recipe under a new `recipes-*` category for something you
  want cross-compiled.
- Try `devtool modify <recipe>` for an iterative edit/rebuild loop instead of
  full `bitbake` runs.
- Look at `meta-raspberrypi`'s `conf/machine/raspberrypi3-64.conf` to see what
  the BSP layer actually configures for you.

## About `bitbake-setup`

Yocto 6.0 added a new guided setup tool (`bitbake-setup init`,
`bitbake-config-build enable-fragment ...`) that replaces hand-edited
`local.conf`/`bblayers.conf` with composable "fragments". `meta-raspberrypi`'s
own docs haven't moved to it yet, and hand-editing these files is arguably
more instructive while you're still learning what each setting does — so
that's what this project uses. Worth a look later:
<https://docs.yoctoproject.org/brief-yoctoprojectqs/index.html>.
