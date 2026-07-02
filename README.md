# theSchultzYocto

Learning project: build a custom, minimal, headless Yocto Linux image for a
spare **Raspberry Pi 3 Model B+**, targeting the **64-bit** BSP
(`raspberrypi3-64`).

This repo *is* a Yocto layer (collection name `schultz`) — it doesn't contain
Poky or the Raspberry Pi BSP layer itself; those get cloned alongside it on
the Linux build machine (see [docs/first-build.md](docs/first-build.md)).

## Why this exists

Short version: yes, RPi3 + Yocto is a genuinely good way to actually learn
Yocto (as opposed to just flashing Raspberry Pi OS). `meta-raspberrypi` is a
mature, actively maintained BSP, so the hardware side is a solved problem —
which leaves you free to focus on the parts that matter for learning: layers,
recipes, image customization, `local.conf`/`bblayers.conf`, and `devtool`.

## Build host

BitBake requires a native Linux host — it will **not** run on macOS. This
project builds on **rpi5g16nvme** (Raspberry Pi 5, 16GB RAM, NVMe storage,
Ubuntu 24.04.4 LTS), reachable passwordlessly via `ssh rpi5g16nvme`. Being
aarch64 doesn't speed up cross-compilation itself (BitBake cross-compiles
regardless of host arch), but it does let some rootfs postinstall steps run
natively instead of under QEMU emulation, and the NVMe + 16GB RAM are real
wins. An old 8GB Intel MacBook Pro (`mbpi5g8no1`/`mbpi5g8no2`) is documented
as a fallback in [docs/build-host-setup.md](docs/build-host-setup.md).

## Repo layout

```
theSchultzYocto/                  <- this repo == the "schultz" layer
├── conf/
│   ├── layer.conf                <- layer definition
│   └── templates/schultz/        <- TEMPLATECONF bootstrap files
├── recipes-core/images/
│   └── schultz-image-minimal.bb  <- our custom image recipe
├── scripts/fetch-layers.sh       <- clones poky + meta-raspberrypi as siblings
└── docs/
    ├── build-host-setup.md
    └── first-build.md
```

On the build machine, the full working layout ends up as:

```
<workdir>/
├── poky/               <- git clone of Poky (oe-core + reference distro)
├── meta-raspberrypi/   <- Raspberry Pi BSP layer
├── theSchultzYocto/    <- this repo
└── build/              <- created by oe-init-build-env, not committed
```

## Quick start

```sh
# from this repo, on your Mac: sync it onto the build host
rsync -av --exclude=.git ./ rpi5g16nvme:theSchultzYocto/

ssh rpi5g16nvme
cd theSchultzYocto
./scripts/fetch-layers.sh          # clones poky + meta-raspberrypi as siblings
cd ..
TEMPLATECONF="$PWD/theSchultzYocto/conf/templates/schultz" source poky/oe-init-build-env build
bitbake schultz-image-minimal
```

Full walkthrough, including flashing the SD card, in
[docs/first-build.md](docs/first-build.md).

## A note on `bitbake-setup`

Yocto 6.0 ("Wrynose") introduced a new guided `bitbake-setup` /
`bitbake-config-build` workflow that replaces manual `local.conf`/`bblayers.conf`
editing with composable "fragments". It's worth knowing about, but
`meta-raspberrypi`'s own docs still use the classic manual workflow, and
that's what's scaffolded here — it's also more transparent for actually
learning what each config option does. Worth revisiting once BSP layers catch
up: <https://docs.yoctoproject.org/brief-yoctoprojectqs/index.html>.
