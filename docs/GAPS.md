# Gap backlog

**Last revised:** 25 August 2026
**What this is:** a single register of every gap and open item scattered across the docs,
ordered by risk. Replaces hunting through five files for "Still open" sections.

Each item cross-references the doc where it's elaborated in full.

**Legend** — Effort: S (≤1 day) · M (a few days) · L (week+).

Priority tiers:
- **Active risk** — the system is live and this gap could cause a silent or irreversible
  failure.
- **Missing proof** — built, wired, or designed, but not confirmed on real hardware.
- **Improvement** — real value, no current exposure.
- **Deliberate ceiling** — hardware or design constraint; not fixable without a bigger change.
  Listed for completeness, not as a to-do.

---

## Active risk

| ID | Gap | Effort | Detail |
|----|-----|:------:|--------|
| **R-1** | **Package-feed signing not proven on hardware** — `PACKAGE_FEED_SIGN = "1"` is templated in `local.conf.sample` (🟢) but has never been verified on the running device; a misconfigured keyring would silently fall back to unsigned packages | S | [status.md](status.md), [TOOLING.md](TOOLING.md#signing-gpg--x509) |
| **R-2** | **U-Boot 2025.04 regression root cause unknown** — the 2026-08-19 experiment showed that U-Boot 2025.04 (from `lts-u-boot-mixin`) silently skips `boot.scr` on the Pi 3 B+, breaking A/B entirely while `rauc status` reports both slots "good". Reverted to 2024.01. The *mechanism* in 2025.04's `rpi_arm64_defconfig` is still unknown — matters for any future U-Boot bump | M | [TOOLING.md § RAUC](TOOLING.md#rauc), [rauc-ab-updates.md § Still open](rauc-ab-updates.md), [scripts/fetch-rauc-layers.sh](../scripts/fetch-rauc-layers.sh) |
| **R-3** | **Licence data absent from SBOM components** — DT's licence policies are enabled but inert: 0/83 components carry a resolved licence (even `busybox = null`). A global Copyleft policy produces 0 violations but evaluates *nothing*. Not a new exposure, but the policy gives false confidence | S | [TOOLING.md § Dependency-Track](TOOLING.md#dependency-track), [yocto-concepts.md](yocto-concepts.md) |

---

## Missing proof

| ID | Gap | Effort | Detail |
|----|-----|:------:|--------|
| **P-1** | **Per-device SSH host keys not isolated** — each A/B slot generates its own key on first boot; every slot switch trips `REMOTE HOST IDENTIFICATION HAS CHANGED`. Fix: persist `/etc/ssh` onto `/data` and regenerate on first boot | S | [rauc-ab-updates.md § Still open](rauc-ab-updates.md), [TOOLING.md § RAUC](TOOLING.md#rauc) |
| **P-2** | **Daily pen-test → DefectDojo is opt-in and never verified end-to-end in the nightly** (🟢) — enabled by having `keys/defectdojo.env` + `PENTEST_TARGET` on the build host; non-fatal if it fails. Whether a real nightly run has ever succeeded through all five stages needs a log review | S | [status.md](status.md), [pen-testing.md](pen-testing.md) |
| **P-3** | **OTA "Install update" button is visualise-first** (🟢) — the fleet dashboard returns the `ota-deploy.sh` command rather than triggering a device self-install. The RAUC/Nexus streaming path is proven; device-self-install is not wired | M | [status.md](status.md), [fleet-app.md](fleet-app.md) |
| **P-4** | **Wrynose (6.0 LTS) RAUC A/B — image + bundle build in progress, hardware unverified.** The base-image migration (§I-1 below, done) proved the new `openembedded-core`+`bitbake`+`meta-yocto` bootstrap and the `sbom-cve-check` pipeline. The A/B/RAUC half is a separate, still-open risk: `meta-rauc-community`'s wrynose-targeting `master` branch drops the `lts-u-boot-mixin` dependency that broke scarthgap's A/B silently, but pulls in U-Boot **2026.01 natively** (oe-core's stock version, not opt-in) — same class of unverified jump. Needs the same on-hardware boot + `mark-bad`/`mark-active` rollback trace that caught the scarthgap regression before this is trusted | M | [yocto-concepts.md § wrynose migration](yocto-concepts.md#the-wrynose-migration-where-poky-went-and-how-this-was-rebuilt), [status.md](status.md) |

---

## Improvement

| ID | Gap | Effort | Detail |
|----|-----|:------:|--------|
| **I-1** | ~~Wrynose (6.0 LTS) bump~~ **base image DONE (2026-08-29)** — `poky` is retired upstream (frozen Nov 2025); wrynose ships as separate `openembedded-core`+`bitbake 2.18`+`meta-yocto` repos, all cloned and proven: clean 5080-task build, `cve-check` → `sbom-cve-check` ported (SBOM/VEX pipeline unchanged, only the file-locating scripts needed updating), `S=${WORKDIR}` and `debug-tweaks` recipe fixes applied. Isolated in `~/wrynose-layers/`+`build-wrynose/` so it can't collide with the still-scarthgap production trees (a real collision broke the nightly cron twice before this was isolated — see the fix in `scripts/fetch-layers.sh`'s header comment). **Remaining scope is P-4 above** (RAUC A/B hardware proof). | L | [yocto-concepts.md § wrynose migration](yocto-concepts.md#the-wrynose-migration-where-poky-went-and-how-this-was-rebuilt), [TOOLING.md § Yocto](TOOLING.md#yocto--openembedded) |
| **I-2** | **OTA-able kernel updates** — currently kernels live on the shared `/boot` FAT partition and can only be updated by SD re-flash. Upstream's newer `boot.cmd.in` loads the kernel from the A/B rootfs (`load ${BOOT_DEV} … boot/Image`); adopting it (with a U-Boot bump that actually works) would make kernel updates bundleable. Blocked on R-2. | L | [rauc-ab-updates.md § Still open](rauc-ab-updates.md), [TOOLING.md § RAUC](TOOLING.md#rauc) |
| **I-3** | **dm-verity on the hardened squashfs** — the ext4 RAUC bundles already use `verity` format (dm-verity on the *bundle*). Adding dm-verity to the *running rootfs* (every block checked at runtime) needs an initramfs + the verity setup; meaningful for a deployed device, over-engineering for the current lab scope | L | [rauc-ab-updates.md § Stronger still](rauc-ab-updates.md) |
| **I-4** | **`kas` manifest for layer pinning** — currently layers are cloned/pinned by hand in `fetch-layers.sh`. `kas` YAML manifests declare all layers, branches, and patches in one file and reproduce the whole build environment in one command. Worth adopting when juggling more than 2–3 layers or adding a second maintainer. | M | [yocto-concepts.md](yocto-concepts.md) |
| **I-5** | **Licence data injection** — add CPE-based licence lookup (e.g. from `cve-check`'s `cve-summary.json` or a `pkg:generic` → SPDX expression map) to `manifest-to-cyclonedx.py` so DT's Copyleft policies evaluate real data | M | [TOOLING.md § Dependency-Track](TOOLING.md#dependency-track), [scripts/manifest-to-cyclonedx.py](../scripts/manifest-to-cyclonedx.py) |

---

## Deliberate ceilings (not to-dos)

| Gap | Why it's a ceiling | Detail |
|-----|--------------------|--------|
| **Hardware secure boot** | Pi 3 boot ROM loads firmware unsigned; no OTP/fuse mechanism exists on this board. Needs Pi 4/5 + fused keys. | [status.md](status.md), [TOOLING.md § Hardware](TOOLING.md#raspberry-pi-3-model-b) |
| **Bootloader in A/B slots** | Pi 3 boot ROM always loads the first FAT partition; there is no alternate-partition mechanism. `RAUC_BUNDLE_SLOTS = "rootfs"` by design — `/boot` is shared and unversioned. | [TOOLING.md § RAUC](TOOLING.md#rauc), [rauc-ab-updates.md](rauc-ab-updates.md) |
| **testssl / Lynis in pen-test** | No TLS port on the image; no `bash` in the rootfs. Both tools are skipped by design and logged explicitly rather than silently omitted. | [pen-testing.md](pen-testing.md), [status.md](status.md) |
| **Yocto wrynose on poky** | poky has no `wrynose` branch yet (checked 2026-08-23). Not a decision to defer — just waiting on upstream. Trigger in README tells us when to act. | [README.md](../README.md) |
