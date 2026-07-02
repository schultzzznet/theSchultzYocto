# First build: zero to a booted SD card

Assumes the build host is already set up per
[build-host-setup.md](build-host-setup.md).

## 0. Get this repo onto the build host

From this repo, on your Mac (passwordless SSH already set up as
`rpi5g16nvme`):

```sh
rsync -av --exclude=.git ./ rpi5g16nvme:theSchultzYocto/
ssh rpi5g16nvme
cd theSchultzYocto
```

Everything from here on runs on `rpi5g16nvme`, not on the Mac.

## 1. Fetch the layers

```sh
./scripts/fetch-layers.sh
```

This clones `poky` and `meta-raspberrypi` (both on the `wrynose` branch —
Yocto 6.0 LTS) as siblings of this repo. Resulting layout:

```
<workdir>/
├── poky/
├── meta-raspberrypi/
└── theSchultzYocto/   <- this repo
```

If you'd rather do it by hand (or `wrynose` isn't available for some reason —
try `scarthgap`, the previous LTS, as a fallback):

```sh
git clone -b wrynose https://git.yoctoproject.org/poky
git clone -b wrynose https://git.yoctoproject.org/meta-raspberrypi
```

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

## 5. Flash the SD card

```sh
cd tmp/deploy/images/raspberrypi3-64/
bmaptool copy schultz-image-minimal-raspberrypi3-64.wic.bz2 /dev/sdX
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
