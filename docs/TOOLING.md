# Tooling — what we use, what we passed on, and why

**Last reviewed:** 25 August 2026
**Scope:** every notable tool, layer, or service that makes this Yocto-based
device-OS project work — the build framework, the OTA update mechanism, the
supply-chain pipeline, the hardware, and the supporting infrastructure.

> For **how Yocto fits together conceptually** — BitBake, OE-Core, recipes,
> layers, the release cadence — see **[yocto-concepts.md](yocto-concepts.md)**.
> That document explains the *vocabulary*. This one explains *the choices*.
>
> For build / flash / OTA **procedures**, see the relevant how-to docs:
> [first-build.md](first-build.md), [rauc-ab-updates.md](rauc-ab-updates.md),
> [security-and-auditing.md](security-and-auditing.md).
>
> **Shared infrastructure** — Nexus, Dependency-Track, and DefectDojo run in the
> k3s cluster managed by the sibling repo
> [the-docker-swarm-ai](https://github.com/schultzzznet/the-docker-swarm-ai).
> Their entries here cover the Yocto-side integration and the *why*; the
> deployment, HA story, and operational gotchas live in
> [the-docker-swarm-ai/docs/TOOLING.md](https://github.com/schultzzznet/the-docker-swarm-ai/blob/master/docs/TOOLING.md).
>
> **How to read each table:** the row labelled **In use** is what's running
> today. **Alternatives** lists serious contenders we either evaluated and
> passed on, or earmarked for a future swap. Every line has a *why*.
>
> **And below each table, the tools we actually run get a profile** — what the
> thing is, which of its parts are wired in, and **which of its parts are
> deliberately left unused**. The unused surface is the real cost of a tool
> and the first thing to collapse when someone "upgrades" without reading this.
>
> **The standing cost constraint:** every tool below is open source or a free
> tier. No paid licences. The one exception in the wider estate is the frontier
> AI used as a development peer (paid subscription, no access to the running
> system).

---

## Build framework

| Status | Tool | Why this / not this |
|---|---|---|
| **In use** | **Yocto Project / OpenEmbedded** (`scarthgap` 5.0 LTS) | The industry standard for reproducible custom embedded Linux: bit-for-bit reproducibility, cross-compilation by default, a 20-year layer ecosystem, mandatory license visibility per recipe, and `inherit cve-check` as a built-in supply-chain gate. Skills and layer investments transfer directly to automotive, networking, and IoT product work. |
| Alternative | **Buildroot** | Simpler (Kconfig/Makefile, no layer concept), genuinely faster to get a first working image, smaller community. Rejected because its layering story is weaker — customisations live in-tree or as patches rather than as clean overlay layers — and Yocto's `sstate` caching and `devtool` tooling are materially better for a project you maintain over years. |
| Alternative | **Debian / Raspberry Pi OS (minimised)** | Fast start, familiar tooling, huge package mirror. Rejected because "strip it down" gives you a diet general-purpose distro rather than a purpose-built minimal image: something always sneaks back in via a dependency, the attack surface is harder to reason about, and the output is not reproducible at the bit level. |
| Alternative | **Alpine Linux / BusyBox direct** | Genuinely tiny and auditable, but entirely hand-rolled — no recipe ecosystem, no BSP layers, no cve-check integration. The effort to match what Yocto gives you for free exceeds the startup cost of learning Yocto. |
| Alternative | **Balena OS** | Designed for fleet management with containers; the update and OTA story is excellent. Rejected because it adds the container runtime as a mandatory layer rather than a choice, and RAUC/A-B already covers the OTA use case at the OS level. |

### Yocto / OpenEmbedded

**What it is** — a build framework, not a distro. BitBake (the engine) reads
layers of metadata (recipes, classes, config) to assemble *your* custom Linux.
The output is a reproducible root-filesystem image for a specific machine, built
from a dependency graph of a few thousand tasks.

**Parts we use** — `inherit cve-check` on every build (cross-references all
installed packages against the NVD and emits `tmp/deploy/cve/` reports);
`DISTRO_FEATURES` to explicitly gate network capabilities; the `sstate-cache`
for incremental rebuilds; the `devtool` loop for iterating on a single recipe
without rebuilding the world; `IMAGE_INSTALL` as the explicit, auditable
package list; a separate `build-rauc/` directory for the A/B RAUC image and
signed bundle (so the nightly security scan and the A/B build never contend
on the same tmp/); and a nightly `git pull --ff-only` on the three LTS layers
(`poky`, `meta-raspberrypi`, `meta-rauc`) to track scarthgap point-releases
automatically.

**Parts we deliberately don't** — `meta-openembedded` (the extended package
catalogue) is not a layer. Every package you add is a package you maintain and
patch forever; `busybox` vi and `top` are enough for a headless embedded image.
`IMAGE_FEATURES += "debug-tweaks"` (empty root password, passwordless SSH) is
on in the ext4 dev image and **off** in the hardened squashfs image — that is
a deliberate split, not an oversight. `read-only-rootfs` is enabled on the
hardened variant only. `DISTRO = "poky"` is the stock reference distro; a
custom `DISTRO` would let us remove poky's own opinionated defaults, but it's
extra maintenance for no current gain.

**The release-pin decision** — we track `scarthgap` (5.0 LTS, supported into
April 2028) rather than the newest release, for a concrete reason: the Yocto
version we can actually build is gated by *all* the layers agreeing on a
codename, and `meta-raspberrypi` only tracks LTS releases. In practice this
means we're always on the newest LTS the Pi BSP supports. The trigger script in
[README.md](../README.md) queries the actual git remotes, not the wiki, so
"wrynose branch present on all three layers" is when we bump.

---

## Hardware (target)

| Status | Tool | Why this / not this |
|---|---|---|
| **In use** | **Raspberry Pi 3 Model B+** (`raspberrypi3-64`, `aarch64`) | Ubiquitous, cheap, a mature `meta-raspberrypi` BSP, and genuinely constrained: 1 GB RAM and a 32-bit-capable `aarch64` core means every efficiency decision is visible rather than hidden by excess headroom. Real hardware beats QEMU for validating boot, OTA, and rollback. |
| Alternative | **Raspberry Pi 4/5** | More capable and supported by the same BSP. The 3 B+ is the constraint, which is the point: a project that works here works anywhere this class of device. Pi 5 would let us test `secure boot` (fused OTP keys) and per-slot kernel OTA, which the Pi 3's shared `/boot` partition can't do. Natural hardware upgrade path. |
| Alternative | **QEMU** (emulated `arm64`) | Used by the Yocto `meta-yocto-bsp` reference. Works for recipe-level development but cannot validate bootloader behaviour, A/B slot switching, RAUC signature verification on-device, or anything involving real storage. |
| Alternative | **BeagleBone / NXP i.MX** | More industrial but less community BSP support for Yocto. The `meta-raspberrypi` layer is mature and actively maintained; a custom BSP would be significant extra work. |

### Raspberry Pi 3 Model B+

**What it is** — a 1 GB, quad-core `aarch64` single-board computer. Boots from
SD card; the Ethernet NIC is a USB-attached `LAN7515` hub+NIC (not a dedicated
Ethernet controller), which has two consequences worth knowing.

**Parts we use** — `raspberrypi3-64` MACHINE target, U-Boot as the bootloader
(required for RAUC A/B), `enable_uart=1` for the serial console (via the
[ESP32 WiFi bridge](../tools/esp32-serial-bridge/)), and `console=ttyS0,115200`.
GPIO pins 6/8/10 for the UART bridge. The shared `/boot` FAT partition
(`mmcblk0p1`) carries U-Boot, the boot script, the kernel, and the DTBs.

**Parts we deliberately don't** — no Wi-Fi or Bluetooth (`DISTRO_FEATURES:remove
= "wifi bluetooth"` in the hardened variant). No USB host in the hardened
image — with one exception: disabling USB host wholesale also kills `eth0`,
because the NIC is the USB hub. Drop USB **mass storage** only.
Hardware secure boot is not possible on this board: the Pi 3 boot ROM loads
firmware from the FAT partition unsigned, and there is no fuse/OTP mechanism to
lock it. That is a hardware ceiling, not a configuration gap.

**The idea worth stealing** — *test on real hardware, especially for boot and
OTA.* The U-Boot 2025.04 experiment (2026-08-19) produced a card that:
built cleanly; passed `rauc status` (both slots "good"); and silently skipped the
A/B boot script entirely, leaving `BOOT_ORDER` changes unconsulted. A QEMU test
would have passed. The only way to catch it was `nc pi-serial-bridge.local 8880`
and watching `/proc/cmdline` lack `rauc.slot=` and `panic=10`.

---

## A/B OTA updates

| Status | Tool | Why this / not this |
|---|---|---|
| **In use** | **RAUC** | The Yocto-native A/B update framework: signed, atomic, slot-based, with RAUC-native U-Boot bootloader integration via `u-boot-fw-utils`. Integrates cleanly via `meta-rauc` + `meta-rauc-community/meta-rauc-raspberrypi`. `verity` bundle format adds dm-verity; `type=raw` slots accept both ext4 and squashfs images with no config change. |
| Alternative | **Mender** | Well-supported, good cloud dashboard, also a `meta-mender` layer. Rejected because it requires a Mender server for the management plane (self-hosted or paid SaaS), while RAUC is a pure client-side mechanism — the artifact store is just Nexus. Less to operate. |
| Alternative | **SWUpdate** | RAUC's closest peer in the Yocto ecosystem. Comparable feature set, slightly less standard U-Boot integration story. No strong reason to prefer it; RAUC was picked first and proved out. |
| Alternative | **OSTree / rpm-ostree** | Content-addressed image deltas, very efficient for large updates. Requires a server (OSTree repo) and its Yocto integration (`meta-updater`) is a larger, harder-to-audit layer than `meta-rauc`. More moving parts for this scale. |
| Alternative | **Balena / container-based OTA** | OTA at the container layer rather than the OS layer. Appropriate if you want application-level update granularity; here the unit of update is the whole image because that's what gives you a verified, reproducible OS state. |

### RAUC

**What it is** — a client-side A/B update framework. It knows about slots
(partitions), bootloaders (U-Boot here), bundle signatures, and rollback, and
nothing else. The infrastructure around it — what serves bundles, what triggers
updates — is entirely up to you.

**Parts we use** — `verity` bundle format (dm-verity integrity on the rootfs
image written into the bundle); x509 signing with our own dev cert
(`scripts/generate-signing-keys.sh`); `type=raw` slots (`mmcblk0p2`/`p3`) so
the same slots accept ext4 and squashfs without a config change; the U-Boot
integration (`fw_printenv`/`fw_setenv` via `u-boot-fw-utils`) for `BOOT_ORDER`,
`BOOT_A_LEFT`, `BOOT_B_LEFT`; `rauc status mark-bad` / `mark-active` for the
A/B lifecycle; and `rauc install http://…` for true HTTP-range streaming from
Nexus straight into the idle slot (nothing touches the device's disk until it
is written to the slot).

**Parts we deliberately don't** — no RAUC Service (the D-Bus daemon) in the
standard image; `rauc` is invoked directly. No hawkBit or RAUC Service client
for server-driven updates; deployments are driven by `ota-deploy.sh` from the
build host. No per-device certificates (all devices share the dev cert); adding
per-device signing requires a PKI.

**Operational gotcha (proven 2026-08-19):** `rauc status mark-good other` is
**not** the right way to restore a slot after `mark-bad`. It resets
`BOOT_x_LEFT` but leaves the slot out of `BOOT_ORDER`. RAUC's U-Boot backend
then reports that slot as `bad` — machine-readable via `rauc status
--output-format=shell`. **Use `rauc status mark-active other`**, which rewrites
`BOOT_ORDER=A B`. The pretty `rauc status` output is full of ANSI escapes and
its slot order is not stable; only `--output-format=shell` is greppable.

**U-Boot version is pinned at 2024.01 — and the reason is hardware-proven.**
The upstream `meta-rauc-community` `scarthgap` branch (80 commits past our pin)
requires `lts-u-boot-mixin` (U-Boot 2025.04, which exists primarily for RPi5).
Tried on the real Pi 3 B+ 2026-08-19: U-Boot 2025.04 boots but our `boot.scr`
never takes effect. `/proc/cmdline` carries only VideoCore firmware args — no
`rauc.slot=`, no `panic=10`, no `BOOT_ORDER` handling — while `rauc status`
reports both slots "good". The root cause inside 2025.04's `rpi_arm64_defconfig`
is unknown; the symptom is silent A/B regression invisible from userspace. Pinned
to `b28c04a` in [scripts/fetch-rauc-layers.sh](../scripts/fetch-rauc-layers.sh)
with the full explanation in the comment.

---

## Artifact & mirror store (Nexus)

> Nexus is deployed and operated in the k3s cluster.
> Full deployment details, HA story, and Nexus-as-a-service gotchas:
> [the-docker-swarm-ai/docs/TOOLING.md § Artifact storage](https://github.com/schultzzznet/the-docker-swarm-ai/blob/master/docs/TOOLING.md).

| Status | Tool | Why this / not this |
|---|---|---|
| **In use** | **Nexus Repository CE** (raw repos: `yocto-sources-raw`, `yocto-sstate-raw`, `schultz-releases-raw`) | Serves three distinct roles: source mirror (`PREMIRRORS`), sstate mirror (`SSTATE_MIRRORS`), and the OTA bundle store (`rauc install http://nexus/…`). One service, one set of credentials. |
| Alternative | **Artifactory CE** | Evaluated first. Rejected: Java-only on the free tier; its Bintray-based install docs pointed at dead infrastructure; and its raw-repository support is behind a paywall for complex hosting. Nexus CE covers all three use cases out of the box. |
| Alternative | **Gitea Packages / GitHub Packages** | Would cover the OTA bundle store, but not the sstate mirror or the source mirror — three different services instead of one. |
| Alternative | **Simple HTTP server** (nginx/caddy) | Would serve files, but has no REST API, no HEAD-check for deduplication, and no path allowlist for scoped write accounts. The `yocto-ci` account's `BROWSE/READ/EDIT/ADD, no DELETE` scope on exactly the mirror repos (verified: `201` in-scope, `403` out-of-scope, `403` admin API) would be impossible to replicate without custom middleware. |

### Nexus (Yocto-side integration)

**What it is** — here, three raw-hosted repos wired into the build via two
BitBake variables and one direct HTTP URL.

**Parts we use** — `SOURCE_MIRROR_URL` + `BB_GENERATE_MIRROR_TARBALLS = "1"`
(the second variable is required; without it, `git://` SRC_URIs produce bare
clones in `downloads/git2/` that nothing can mirror — confirmed missing for the
first five weeks after the mirror was "configured"); `SSTATE_MIRRORS` + a shared
`bitbake-hashserv` on the build host (`BB_HASHSERVE = "localhost:8686"` — the
hash-equivalence server is what makes sstate objects findable by name on the
mirror; without it every consumer computes different unihashes and misses every
cached object); the `schultz-releases-raw` OTA store, served directly to `rauc
install` via HTTP range requests; and [scripts/populate-nexus-mirror.sh](../scripts/populate-nexus-mirror.sh)
as the upload step, wired as step 6 of the nightly scan.

**Parts we deliberately don't** — the `schultz-releases-raw` repo is the
**releases** repo, not the mirror. Wiring `NEXUS_REPO` (the releases variable)
to the sstate or sources repo would land OTA bundles in the wrong place, or
mirror traffic in the releases feed. The three repos are entirely separate;
[scripts/populate-nexus-mirror.sh](../scripts/populate-nexus-mirror.sh) uses
`SOURCES_REPO` and `SSTATE_REPO` explicitly.

**The trap that shaped it (five weeks, 2026-07-03 to 2026-08-12):** `SOURCE_MIRROR_URL` was set and `SSTATE_MIRRORS` was set, but `BB_GENERATE_MIRROR_TARBALLS` was not and nothing had ever uploaded to either repo. Every build silently 404'd on Nexus and fell through to the internet. The mirror *looked* configured. Proving a mirror actually works requires a build with `BB_FETCH_PREMIRRORONLY = "1"` and the local copies moved aside — not just "bytes uploaded."

---

## CVE / supply-chain tracking (Dependency-Track)

> Dependency-Track is deployed in the k3s cluster.
> Deployment, admin API, version upgrade gotchas, and the licence-policy
> limitation: [the-docker-swarm-ai/docs/TOOLING.md § Security scanning](https://github.com/schultzzznet/the-docker-swarm-ai/blob/master/docs/TOOLING.md).

| Status | Tool | Why this / not this |
|---|---|---|
| **In use** | **Dependency-Track v5** (project `theSchultzYocto`, `rolling` version for nightly, pinned CalVer for releases) | Continuous re-analysis: same SBOM, new CVEs — no re-upload needed. CycloneDX-native. CPE matching works well against the NVD for Yocto packages once CPEs are added (generic PURLs alone produce 0 findings). |
| Alternative | **Grype / Trivy** | Excellent CLI scanners, but scan-at-a-point rather than continuously re-analysing a stored SBOM against a rolling NVD feed. Fine for CI gates; DT gives the *living* CVE posture over the lifetime of a release. Both are actually used as *inputs* to DefectDojo. |
| Alternative | **SPDX + GitHub Security tab** | GitHub understands SPDX; it doesn't understand Yocto CPEs, and the Yocto `create-spdx` class outputs SPDX rather than CycloneDX, which DT's `/api/v1/bom` endpoint does not accept (HTTP 400, schema validation). Convert first with `cyclonedx-cli` — or use [scripts/manifest-to-cyclonedx.py](../scripts/manifest-to-cyclonedx.py), which builds the CycloneDX with CPEs from the build host's `cve-summary.json` and `pkgdata/runtime-reverse/`. |
| Alternative | **Yocto `cve-check` class only** | `inherit cve-check` runs at build time and is excellent for "does this build have known CVEs": it uses Yocto's own CPE database and is the most accurate per-recipe signal. It is one-shot (re-run only on rebuild) and not designed for continuous post-ship monitoring. Both are used: `cve-check` is the build gate, DT is the continuous post-ship monitor. |

### Dependency-Track

**What it is** — a server that stores SBOMs and continuously re-analyses them
against fresh NVD/OSV data, so a CVE disclosed today against a version you
shipped six months ago surfaces without a rebuild or re-scan.

**Parts we use** — CycloneDX BOM ingestion via `/api/v1/bom`; CPE-enriched
components (the CPE is required — generic `pkg:generic/name@version` PURLs
produce 0 findings; CPEs from `cve-check`'s `cve-summary.json` unlocked ~100
findings on an 83-component image); VEX files (auto-dismiss CVEs that
Yocto's `cve-check` marks as patched, reducing real signal from ~100 to ~46
findings); a `rolling` project version tracking nightly builds, plus a pinned
CalVer version per release (`2026.07.1`); and the `Automation` team API key
(scoped to `BOM_UPLOAD + PORTFOLIO_MANAGEMENT + PROJECT_CREATION_UPLOAD +
VIEW_PORTFOLIO + VIEW_VULNERABILITY + VULNERABILITY_ANALYSIS`, not
Administrators).

**Parts we deliberately don't** — licence policy evaluation. DT ships licence
group CRDs (`Copyleft`, `Weak Copyleft`) out of the box, but a policy is inert
unless components carry licence data. Verified on this project: 0/83 components
had a resolved licence — `busybox` has `license: null` in the API even though
it is unambiguously GPL-2.0. CVE matching works; licence matching does not,
without additional tooling to inject licence data per component.

**The gotcha worth knowing:** `GET /api/v1/team` returns 403 for a
least-privilege key (it requires `ACCESS_MANAGEMENT`). Do not use it to validate
an API key — it will report a working key as broken. Use `GET /api/v1/project`
(`VIEW_PORTFOLIO`) instead.

---

## Pen-test aggregation (DefectDojo)

> DefectDojo is deployed in the k3s cluster.
> Deployment, fresh-DB token rotation, and the NodePort change:
> [the-docker-swarm-ai/docs/TOOLING.md § Security scanning](https://github.com/schultzzznet/the-docker-swarm-ai/blob/master/docs/TOOLING.md).

| Status | Tool | Why this / not this |
|---|---|---|
| **In use** | **DefectDojo** (Product `theSchultzYocto`: nmap + ssh-audit + checksec + kernel-hardening-checker + DT FPF export) | One pane for both the pen-test findings and the SCA findings (DT exports as a FPF finding file). Deduplication and false-positive tracking in one place. Native parsers for nmap, ssh-audit; a small normaliser for checksec / kernel-hardening-checker / lynis. |
| Alternative | **Raw tool output only** | nmap XML, ssh-audit JSON, etc. are perfectly readable. Rejected because there is no cross-tool deduplication, no severity trending over time, no FP tagging, and when the DT findings are layered in they become a separate spreadsheet. |
| Alternative | **Wazuh** | Excellent SIEM + file-integrity monitoring. The right tool once the Pi 3 is in a fleet of meaningful size. Not needed for a single-device lab. |

### DefectDojo

**What it is** — a vulnerability management platform: aggregates findings from
many scan tools, deduplicates, tracks false positives, and gives one severity
view across tool types.

**Parts we use** — the `theSchultzYocto` Product with one Engagement per scan
run; native nmap, ssh-audit, and Dependency-Track FPF parsers; a generic
normaliser for the three tools (checksec, kernel-hardening-checker, lynis) that
have no native parser; and [scripts/pentest-to-defectdojo.py](../scripts/pentest-to-defectdojo.py) +
[scripts/upload-pentest.sh](../scripts/upload-pentest.sh) for the upload.

**Parts we deliberately don't** — testssl and Lynis are **skipped by design** on
this image, not absent by accident: there is no TLS port to scan, and `bash` is
not in the image. This is logged explicitly rather than silently omitted, because
"0 findings" from a skipped tool is indistinguishable from "0 findings" from a
clean scan in most aggregators.

---

## Signing (GPG + x509)

| Status | Tool | Why this / not this |
|---|---|---|
| **In use** | **GPG** (package feed signing) + **x509** (RAUC bundle signing) | Two different trust requirements, two different key types: GPG for package-feed authenticity (Yocto's native model); x509 for RAUC bundle signing because RAUC's signature verification uses the standard PKCS7/CMS chain and its `[keyring]` stanza takes a PEM cert. |
| Alternative | **Sigstore / cosign** | Used in the sibling repo for container image signing. Not applicable here: RAUC does not consume Sigstore signatures, and Yocto's package feed signing is not cosign-based. |
| Alternative | **Single key for both** | GPG *can* sign X.509 artifacts via cross-certification, but RAUC's C-based signature verifier is not a GPG implementation. Two separate key hierarchies is the right separation. |

### GPG + x509

**What it is** — [scripts/generate-signing-keys.sh](../scripts/generate-signing-keys.sh)
produces both: a GPG keypair (package feed, `PACKAGE_FEED_SIGN = "1"` in
local.conf) and an x509 dev keypair (`development-1.key.pem` /
`development-1.cert.pem`) for RAUC bundle signing. Private halves are gitignored;
the public cert is baked into the image at
`/etc/rauc/development-1.cert.pem` via `rauc-conf.bbappend`.

**Parts we use** — x509 bundle signing and on-device verification; `verity`
bundle format (dm-verity); the `[keyring]` stanza in
[recipes-core/rauc/files/system.conf](../recipes-core/rauc/files/system.conf).

**Parts we deliberately don't** — the `RAUC_KEY_FILE ?=` / `RAUC_CERT_FILE ?=`
defaults in `meta-rauc-community`'s `update-bundle.bb` point at a demo keypair
bundled with the layer. These are explicitly overridden in
[recipes-core/images/schultz-bundle.bb](../recipes-core/images/schultz-bundle.bb)
— not relying on the `?=` default is the right defensive posture.

---

## Serial console bridge (ESP32)

| Status | Tool | Why this / not this |
|---|---|---|
| **In use** | **ESP32 WiFi-to-UART bridge** ([tools/esp32-serial-bridge/](../tools/esp32-serial-bridge/)) running PlatformIO firmware | Gives a wireless serial console (`nc pi-serial-bridge.local 8880`) reachable from anywhere on the LAN, without a USB cable tethering you to one machine. Essential for watching U-Boot and catching silent boot failures. |
| Alternative | **Direct USB-serial adapter** | Fine for a permanently tethered setup. Breaks "watch the reboot from the Mac, over the network, while the Pi 3 is on a shelf." Also requires physically moving the cable to a different machine if the build host or dev machine changes. |
| Alternative | **PiKVM / TinyPilot** | Full HDMI + keyboard KVM-over-IP. Far more than a UART bridge; overkill for a headless device that only needs serial. The Pi 3 B+ has no HDMI output we care about. |

### ESP32 serial bridge

**What it is** — an ESP32 devkit running custom firmware (PlatformIO, Arduino
framework) that bridges GPIO 16/17 (UART2) to a plain TCP socket on port 8880.
The Pi's UART TXD/RXD are wired to ESP32 GPIO16(RX)/GPIO17(TX). mDNS announces
`pi-serial-bridge.local`.

**Parts we use** — `Serial2.begin(115200)` on UART2 (separate from the USB
programming UART); `WiFiServer` on port 8880; mDNS (`pi-serial-bridge.local`);
`nc pi-serial-bridge.local 8880` as the client. The bridge is unauthenticated
plaintext on a home LAN, which is the right posture for a serial console in this
environment.

**Parts we deliberately don't** — the USB port is for flashing only; once
firmware is loaded, USB is unused and the bridge runs purely wireless. It is not
used for bulk data transfer — at 115200 baud (~11 KB/s), pushing a 95 MB image
over it would take hours with no error correction. SD card flashing is
`gzip -dc … | sudo dd of=/dev/rdiskN bs=4m`.

**Gotchas from operating it:**
- The firmware has **no flow control** — it forwards bytes one at a time in
  `loop()`. Long bursts (a full `dmesg`) drop bytes and interleave output with
  the shell prompt. Only trust **short single-value command output** over it
  (`grep -c`, `wc -l`, `fw_printenv ONE_VAR`).
- The board was **not running the bridge firmware** the first time we needed it
  (silent USB port, nothing on 8880 across the full /24 scan). `pio run -t
  upload` is the fix. CH340 VID:PID `1A86:7523`.
- **SSH host key changes on every A/B slot switch.** Verify the key out-of-band
  over serial (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`) and compare
  with `ssh-keyscan … | ssh-keygen -lf -` before updating `known_hosts`. Slot A's
  fingerprint returns when you switch back, which is an independent identity
  check.

---

## Build host

| Status | Tool | Why this / not this |
|---|---|---|
| **In use** | **Raspberry Pi 5 (16 GB, NVMe)** as dedicated build host | A Yocto build needs a real Linux host (or a Linux VM with full kernel exposure). The Pi 5 with NVMe is fast enough for a full Yocto build in a few hours, runs 24/7 for the nightly scan cron, and is already in the home-lab. |
| Alternative | **Mac with Docker / Lima VM** | The macOS build path is officially supported by Yocto but adds a virtualisation layer, slower filesystem access through 9P, and occasional host-kernel-version mismatch in pseudo (the userspace UID/GID emulation layer Yocto uses for rootfs construction). Build times are noticeably slower. Fine for development; not the nightly runner. |
| Alternative | **GitHub Actions / cloud CI** | Would work and is the right answer for a project with a team. Costs money at Yocto image build scale (a full build is 4000+ tasks), requires either a self-hosted runner or a large runner, and adds an external dependency for the signing keys. |
| Alternative | **x86 workstation** | Faster builds. The Pi 5 is used because it was available, it's low-power, and it proves the toolchain works on `aarch64` hosts as well as `x86_64`. |

### Pi 5 build host (`rpi5g16nvme`, Tailscale IP 100.65.202.58)

**What it is** — a Pi 5, 16 GB RAM, NVMe (458 GB, ~44% used at last check),
running the nightly `daily-security-scan.sh` cron at 03:30 local.

**Parts we use** — the build tree lives as siblings outside the git repo
(`~/poky`, `~/meta-raspberrypi`, `~/meta-rauc`, `~/theSchultzYocto`,
`~/build`, `~/build-rauc`); `scripts/sync-to-host.sh` pushes the repo via git
(`receive.denyCurrentBranch=updateInstead`) so nothing is ever scp'd; a flock
on `~/build/.security-scan.lock` serialises the nightly scan and any manual
build so they never run simultaneously; `bitbake-hashserv` as a systemd unit
at `localhost:8686` with its database at `~/hashserv/hashserv.db` (outside
`build/` so a `tmp/` wipe does not strand the hash-equivalence mappings).

**Parts we deliberately don't** — `~/build/conf/local.conf` is **not
git-managed**. It is a copy of the template made once when the build dir was
first created, and it drifts. Changes to
[conf/templates/schultz/local.conf.sample](../conf/templates/schultz/local.conf.sample)
must be applied to both files; `bitbake-getvar` is the only way to verify what
BitBake actually resolved.

**The idea worth stealing** — `pgrep -f <pattern>` over SSH **always** gives a
false positive: the SSH `bash -c '<command>'` process includes the pattern in
its own argv. Use `ps -eo pid,etime,args | grep -E '<pattern>' | grep -v grep`
to see the real argv — the `bash -c` wrapper is obvious and rules out the false
match.
