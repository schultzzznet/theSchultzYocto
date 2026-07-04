# theSchultzYocto

Learning project: build a custom, minimal, headless Yocto Linux image for a
spare **Raspberry Pi 3 Model B+**, targeting the **64-bit** BSP
(`raspberrypi3-64`).

This repo *is* a Yocto layer (collection name `schultz`) — it doesn't contain
Poky or the Raspberry Pi BSP layer itself; those get cloned alongside it on
the Linux build machine (see [docs/first-build.md](docs/first-build.md)).

New to Yocto? [docs/yocto-concepts.md](docs/yocto-concepts.md) covers what it
actually is, how a distro comes together, why this approach is worth the
setup cost, and how updates/security work — grounded in this repo's own
recipes and the mistakes we hit building it.

Need to debug a boot that never gets far enough for SSH?
[docs/serial-console.md](docs/serial-console.md) covers getting a serial
console on the Pi (dedicated USB-TTL adapter or a repurposed spare
ESP32/ESP8266), the GPIO pinout, and wiring for both a direct-wired setup
and the WiFi-based [tools/esp32-serial-bridge/](tools/esp32-serial-bridge/).

Build already running and you want to check on it (or it just died)?
[docs/build-operations.md](docs/build-operations.md) covers checking status
on a detached build, what does/doesn't survive a build-host reboot, and
recovering from a corrupted `tmp/`/`sstate-cache` after an unclean shutdown.

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
├── scripts/
│   ├── fetch-layers.sh           <- clones poky + meta-raspberrypi as siblings
│   ├── sync-to-host.sh           <- git-based sync to the build host (no scp/rsync)
│   ├── remote-build.sh           <- runs ON the build host: bootstrap + launch build
│   └── deploy.sh                 <- sync + remote-build in one command, from the Mac
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

From this repo, on your Mac (fully scripted, no scp/rsync -- syncs via git
over ssh):

```sh
./scripts/deploy.sh
```

This pushes the repo to `rpi5g16nvme` via git, then bootstraps and launches
`bitbake schultz-image-minimal` there, fully detached (survives SSH
disconnects). Follow progress with:

```sh
ssh rpi5g16nvme 'tail -f build/schultz-build.log'
```

Full walkthrough, including flashing the SD card, in
[docs/first-build.md](docs/first-build.md).

## Yocto release: why `scarthgap`, and when to move

This project pins **`scarthgap` (Yocto 5.0 LTS)** across poky, `meta-raspberrypi`,
and `meta-rauc` — see [scripts/fetch-layers.sh](scripts/fetch-layers.sh) and
[scripts/fetch-rauc-layers.sh](scripts/fetch-rauc-layers.sh). It's deliberately
*not* the newest Yocto (**`wrynose` / 6.0 LTS** shipped April 2026); it's the
newest release the **Raspberry Pi BSP actually supports**, which is what decides
it here:

- `meta-raspberrypi`'s branches currently stop at `whinlatter` (5.3) — there is
  **no `wrynose` branch yet**, so 6.0 simply isn't an option for this board.
- Every `meta-raspberrypi` branch *newer* than scarthgap (`styhead` 5.1,
  `walnascar` 5.2, `whinlatter` 5.3) is a **non-LTS that is already EOL**.
- So scarthgap is the newest **LTS with a Pi BSP branch** — still actively
  maintained (5.0.18, June 2026) and supported until **April 2028**.

**The move to make later:** once `agherzan/meta-raspberrypi` publishes a
`wrynose` branch, bump the fetch scripts from `scarthgap` to `wrynose` to land
on the 6.0 LTS (supported until 2030). `meta-rauc` is already ahead — it *has* a
`wrynose` branch — so only the Pi BSP gates the jump.

**How you'll know it's time — Renovate won't tell you.** The catch isn't that
the releases lack numbers — they have them (scarthgap = 5.0, wrynose = 6.0, and
6.0 > 5.0 is trivially orderable). It's that the layers are tracked by git
*branch name* (`scarthgap`), and the number↔codename mapping lives on the Yocto
wiki, **not in the git refs Renovate reads**: `meta-raspberrypi`'s branches are
bare codenames (`scarthgap`, `styhead`, `walnascar`, `whinlatter`), none
containing a "5.0"/"6.0" for a version-sorter to compare — and no off-the-shelf
Renovate/Dependabot manager knows the codename→number table. (The move is also
gated on the `wrynose` branch *existing at all*, which is an existence check,
not a version comparison.) So the trigger stays a one-liner — run it now and
then, or drop it in a scheduled CI job:

```sh
git ls-remote --heads https://github.com/agherzan/meta-raspberrypi \
  | grep -q wrynose && echo "meta-raspberrypi has wrynose -- time to bump scarthgap -> wrynose."
```

## A note on caching (the Nexus mirror) — isn't rebuilding from source the point?

Caching build output isn't against Yocto's grain; it *is* Yocto's grain.
BitBake is a hash-based build system: every task's inputs (recipe, config,
dependencies, toolchain) are hashed into a signature, and the **shared state
(sstate)** cache stores each task's *output* keyed by that signature. If the
inputs haven't changed the signature matches, and the cached output is provably
byte-identical to what a rebuild would produce — so re-running the task is pure
waste. Restoring it isn't "trusting a stale binary", it's "this exact input
already produced this exact output". Without sstate, changing one line in one
recipe would rebuild `gcc-cross`, `glibc`, and the whole world every time; the
cache is what makes iterative Yocto usable at all. The Yocto project itself runs
a public sstate mirror (`sstate.yoctoproject.org`) for precisely this reason.

Two things get mirrored here — both activated in
[local.conf.sample](conf/templates/schultz/local.conf.sample), pointed at a
**Nexus** raw repo on the LAN (created by
[scripts/setup-nexus-mirror.sh](scripts/setup-nexus-mirror.sh)):

- **`SOURCE_MIRROR_URL`** — the pinned upstream source tarballs (`DL_DIR`).
  Pure resilience: upstream tags vanish and projects go offline mid-project.
  Every fetch is checksum-verified against the recipe's `SRC_URI[sha256sum]`,
  so a mirror can't smuggle anything in — it either matches the pin or the
  build fails.
- **`SSTATE_MIRRORS`** — the compiled task outputs described above.

The "from source, pinned, reproducible" guarantee is untouched: `downloads/`
still holds checksum-verified upstream sources, and you can always delete
sstate and rebuild to an identical result — the cache is an optimization, never
the source of truth. The one thing that genuinely needs care is that task
**signatures be complete** (an output must not depend on anything not captured
in its hash, e.g. a host path or timestamp); that's where sstate correctness
actually lives, not in the idea of caching itself. (Related known gap here:
BitBake's `BB_HASHSERVE` hash-equivalence isn't fully reconciled with
`SSTATE_MIRRORS` yet — logged, low priority while the mirror is lightly
populated.) Deeper dive in [docs/yocto-concepts.md](docs/yocto-concepts.md).

## A note on `bitbake-setup`

Yocto 6.0 ("Wrynose") introduced a new guided `bitbake-setup` /
`bitbake-config-build` workflow that replaces manual `local.conf`/`bblayers.conf`
editing with composable "fragments". It's worth knowing about, but
`meta-raspberrypi`'s own docs still use the classic manual workflow, and
that's what's scaffolded here — it's also more transparent for actually
learning what each config option does. Worth revisiting once BSP layers catch
up: <https://docs.yoctoproject.org/brief-yoctoprojectqs/index.html>.
