# theSchultzYocto

Learning project: build a custom, minimal, headless Yocto Linux image for a
spare **Raspberry Pi 3 Model B+**, targeting the **64-bit** BSP
(`raspberrypi3-64`).

> **Where this fits.** This repo is the *platform* tier of a larger estate: the device OS that
> `theMowerRetrofit` builds on and that reports into a k3s control plane. There is no single
> "parent" repo, but the closest thing to a map is
> [`docs/ECOSYSTEM.md`](https://github.com/schultzzznet/the-docker-swarm-ai/blob/master/docs/ECOSYSTEM.md)
> in [`the-docker-swarm-ai`](https://github.com/schultzzznet/the-docker-swarm-ai) — it explains
> how the tiers stack, where the seams are, and what is live vs. roadmap. Concretely, this
> repo's **CycloneDX SBOM, CPE-matched CVEs and VEX** are uploaded to that cluster's
> Dependency-Track, and its `schultz-agent` heartbeats into `fleet-app` there.

### The estate

| Repo | Tier | What it is |
|---|---|---|
| **theSchultzYocto** *(this one)* | platform | minimal hardened Yocto device OS, RAUC A/B OTA, SBOM/CVE/VEX |
| [the-docker-swarm-ai](https://github.com/schultzzznet/the-docker-swarm-ai) | control plane | k3s: fleet management, OTA distribution, security aggregation, observability, AI ops |
| [theMowerRetrofit](https://github.com/schultzzznet/theMowerRetrofit) | product | RTK pattern-mowing brain retrofitted into old robotic mowers — builds on this image |
| [theDroneSwarm](https://github.com/schultzzznet/theDroneSwarm) | satellite | drone swarm; its `swad` app deploys into the cluster |

Navigate the set via the topic
[`schultzzznet-estate`](https://github.com/search?q=topic%3Aschultzzznet-estate), the
[profile index](https://github.com/schultzzznet), or the full map in
[`ECOSYSTEM.md`](https://github.com/schultzzznet/the-docker-swarm-ai/blob/master/docs/ECOSYSTEM.md).

This repo *is* a Yocto layer (collection name `schultz`) — it doesn't contain
Poky or the Raspberry Pi BSP layer itself; those get cloned alongside it on
the Linux build machine (see [docs/first-build.md](docs/first-build.md)).

Want the quick "what actually works" view? [docs/status.md](docs/status.md) is
the status‑at‑a‑glance: what's verified on real hardware, what's built and
wiring‑complete, and what's a hardware ceiling (like secure boot on a Pi 3).

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

Care about the supply-chain security angle?
[docs/security-and-auditing.md](docs/security-and-auditing.md) is the deep
dive: how the image's SBOM, CPE-matched CVEs, and cve-check-driven VEX fit
together in Dependency-Track (tracked as a project named after this repo,
`theSchultzYocto`), what the once-a-day auto-scan keeps current, the trust and
threat models (with their honest limits), and how to trace any single "this CVE
is fine" decision all the way back to evidence.

The other half of the security story — configuration, network exposure, and
binary/kernel hardening — plus one place all of it lives:
[docs/pen-testing.md](docs/pen-testing.md) covers the pen-test + hardening scans
(nmap, ssh-audit, testssl, Lynis, checksec, kernel-hardening-checker) that feed
**DefectDojo**, the cross-tool aggregation pane. DefectDojo also mirrors
Dependency-Track's own triaged findings, so supply chain, exposure, and hardening
read as a single screen — verified end-to-end against the live Pi.

Want to *see* the fleet — Tesla-style? [docs/fleet-app.md](docs/fleet-app.md)
covers the companion **fleet dashboard** (a cluster app in `the-docker-swarm-ai`)
and the on-device `schultz-agent` that reports version, A/B slot, temperature and
undervoltage, and surfaces "update available" with a one-click OTA — reusing the
proven `ota-deploy.sh`/Nexus/RAUC path. One screen for the whole fleet.

Ready to put it on real hardware with rollback-safe OTA?
[docs/rauc-ab-updates.md](docs/rauc-ab-updates.md) walks through building an A/B
RAUC image (U-Boot + dual rootfs slots), flashing it, and doing a live update
and rollback on the Pi over a serial console — the real payoff of rolling your
own distro.

Wondering why we chose Yocto over Buildroot, RAUC over Mender, or Nexus over
Artifactory — or which things are still open?
[docs/TOOLING.md](docs/TOOLING.md) is the choices-and-alternatives register,
in the same format as the sibling repo's. [docs/GAPS.md](docs/GAPS.md) is the
single consolidated list of open items, missing proofs, and deliberate ceilings
— replaces hunting through five docs for "Still open" sections.

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
├── recipes-support/
│   └── schultz-agent/            <- opt-in device agent for the fleet dashboard
├── scripts/
│   ├── fetch-layers.sh           <- clones poky + meta-raspberrypi as siblings
│   ├── sync-to-host.sh           <- git-based sync to the build host (no scp/rsync)
│   ├── remote-build.sh           <- runs ON the build host: bootstrap + launch build
│   ├── upload-sbom.sh            <- push CycloneDX SBOM + VEX to Dependency-Track
│   ├── daily-security-scan.sh    <- cron: rebuild + refresh SBOM/VEX daily
│   ├── pentest-scan.sh           <- run nmap/ssh-audit/testssl/lynis/checksec/kernel checks
│   ├── upload-pentest.sh         <- push pen-test findings + a DT mirror to DefectDojo
│   ├── setup-pentest-tools.sh    <- install the pen-test toolchain on the build host
│   ├── setup-nexus-mirror.sh     <- create the Nexus raw repos (sstate/source mirror + releases)
│   ├── populate-nexus-mirror.sh  <- runs ON the build host: fill those mirrors from downloads/ + sstate-cache/
│   ├── setup-hashserv.sh         <- runs ON the build host: shared hash-equivalence server for the sstate mirror
│   ├── bootstrap-credentials.sh  <- mint every keys/*.env token from scratch (none are in git, by design)
│   ├── cut-release.sh            <- one command: build + verify + SBOM + archive + publish to Nexus + tag
│   ├── ota-deploy.sh             <- ship a release to a running Pi over the air (streams from Nexus)
│   └── deploy.sh                 <- sync + remote-build in one command, from the Mac
└── docs/
    ├── build-host-setup.md
    ├── security-and-auditing.md
    ├── pen-testing.md
    ├── fleet-app.md
    ├── rauc-ab-updates.md
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
*not* the newest Yocto LTS (**`wrynose` / 6.0**); the bump is ready to happen but
is no longer a one-line branch swap — it's a porting project:

- **`poky` is discontinued as a convenience bundle.** The `git.yoctoproject.org/poky`
  repo's `master` branch was frozen in November 2025 ("no longer being updated");
  wrynose shipped April 2026 as separate `oe-core` + `bitbake` repos. There will be
  no `poky/wrynose` branch; our `fetch-layers.sh` approach needs rethinking.
- **`inherit cve-check` is removed in 6.0**, replaced by `sbom-cve-check`. Our CVE
  pipeline — `local.conf`, the nightly scan, `manifest-to-cyclonedx.py`, and the
  audit docs — all depend on it. This needs a real porting effort.
- SPDX 2.2 removed (use SPDX 3); `.wks` files must move to `files/wic/`.

So scarthgap (5.0.19, LTS until April 2028) remains the right pin for now.
The wrynose migration is tracked in [docs/GAPS.md](docs/GAPS.md).

**The move to make later:** understand the new `oe-core` + `bitbake` direct setup
(replacing poky), port the CVE pipeline from `cve-check` to `sbom-cve-check`, then
bump. The BSP (`meta-raspberrypi`) and RAUC layers already have `wrynose` branches.

**How you'll know it's time — Renovate won't tell you.** The catch isn't that
the releases lack numbers — they have them (scarthgap = 5.0, wrynose = 6.0, and
6.0 > 5.0 is trivially orderable). It's that the layers are tracked by git
*branch name* (`scarthgap`), and the number↔codename mapping lives on the Yocto
wiki, **not in the git refs Renovate reads**: `meta-raspberrypi`'s branches are
bare codenames (`scarthgap`, `styhead`, `walnascar`, `whinlatter`), none
containing a "5.0"/"6.0" for a version-sorter to compare. Subscribe to
[yocto-announce](https://lists.yoctoproject.org/g/yocto-announce) for release
announcements (send a blank email to
`yocto-announce+subscribe@lists.yoctoproject.org`).

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

Two things get mirrored here — both pointed at a **Nexus** raw repo on the LAN
in [local.conf.sample](conf/templates/schultz/local.conf.sample), with the repos
created by [scripts/setup-nexus-mirror.sh](scripts/setup-nexus-mirror.sh):

- **`SOURCE_MIRROR_URL`** — the pinned upstream source tarballs (`DL_DIR`).
  Pure resilience: upstream tags vanish and projects go offline mid-project.
  Every fetch is checksum-verified against the recipe's `SRC_URI[sha256sum]`,
  so a mirror can't smuggle anything in — it either matches the pin or the
  build fails.
- **`SSTATE_MIRRORS`** — the compiled task outputs described above.

Setting those two variables is necessary but *not sufficient*, which is worth
saying plainly because it went unnoticed here from 2026-07-03 to 2026-08-12:
creating the repos does not fill them, and a mirror nobody uploads to is just a
404 on the way to the internet. Two things close that gap:

- **`BB_GENERATE_MIRROR_TARBALLS = "1"`** — without it, `git://` recipes leave
  bare clones in `downloads/git2/` that are never packed into a mirrorable
  file. Only the flat files in `downloads/` were mirrorable; the kernel and 37
  other git clones (6.1 GB) were not.
- **[scripts/populate-nexus-mirror.sh](scripts/populate-nexus-mirror.sh)** —
  uploads `downloads/` and `sstate-cache/` into the two raw repos, skipping
  what is already there. The nightly runs it after each successful build, so
  the mirror tracks whatever the current image actually needs.
- **[scripts/setup-hashserv.sh](scripts/setup-hashserv.sh)** — a shared
  hash-equivalence server. sstate objects are named by *unihash*, and BitBake's
  default server keeps those mappings in a socket-local database inside
  `build/`, so a consumer computes different names and misses the whole mirror.
  BitBake warns about exactly this combination.

The same Nexus instance also hosts a third raw repo, **`schultz-releases-raw`**,
where [scripts/cut-release.sh](scripts/cut-release.sh) publishes each signed RAUC
release bundle + A/B image. The Pi then updates by **streaming straight from
Nexus** — `rauc install http://nexus/…` — with no `scp`/`rsync` (Nexus honours
HTTP range requests, so RAUC pulls the bundle into the spare slot without ever
landing it on disk). One service is thus both the build cache *and* the OTA
artifact server: the binary lives in Nexus, the SBOM in Dependency-Track, the
source in git. Full flow in [docs/rauc-ab-updates.md](docs/rauc-ab-updates.md).

The "from source, pinned, reproducible" guarantee is untouched: `downloads/`
still holds checksum-verified upstream sources, and you can always delete
sstate and rebuild to an identical result — the cache is an optimization, never
the source of truth. The one thing that genuinely needs care is that task
**signatures be complete** (an output must not depend on anything not captured
in its hash, e.g. a host path or timestamp); that's where sstate correctness
actually lives, not in the idea of caching itself. The other is *who can write
to the mirror*: source tarballs are checksum-pinned and therefore
self-defending, but sstate entries are executable build output that gets
unpacked into later builds, so the sstate repo's write credential is a
supply-chain credential — reads stay anonymous, writes use a `yocto-ci` account
scoped to the three raw repos with no delete and no admin. Deeper dive in
[docs/yocto-concepts.md](docs/yocto-concepts.md).

## A note on `bitbake-setup`

Yocto 6.0 ("Wrynose") introduced a new guided `bitbake-setup` /
`bitbake-config-build` workflow that replaces manual `local.conf`/`bblayers.conf`
editing with composable "fragments". It's worth knowing about, but
`meta-raspberrypi`'s own docs still use the classic manual workflow, and
that's what's scaffolded here — it's also more transparent for actually
learning what each config option does. Worth revisiting once BSP layers catch
up: <https://docs.yoctoproject.org/brief-yoctoprojectqs/index.html>.
