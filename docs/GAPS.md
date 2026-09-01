# Gap backlog

**Last revised:** 30 August 2026
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
| **R-2** | **U-Boot 2025.04 regression root cause unknown** — the 2026-08-19 experiment showed that U-Boot 2025.04 (from `lts-u-boot-mixin`) silently skips `boot.scr` on the Pi 3 B+, breaking A/B entirely while `rauc status` reports both slots "good". Reverted to 2024.01. **Narrowed 2026-08-30:** U-Boot **2026.01** on wrynose sources `boot.scr` correctly and passes the full `A → B → A` rollback, so the fault is specific to 2025.04/`lts-u-boot-mixin`, not to "newer U-Boot". The *mechanism* is still unknown — lower risk now, but keep it in mind for any scarthgap-side bump | M | [TOOLING.md § RAUC](TOOLING.md#rauc), [rauc-ab-updates.md § Still open](rauc-ab-updates.md), [scripts/fetch-rauc-layers.sh](../scripts/fetch-rauc-layers.sh) |
| **R-3** | **Licence data absent from SBOM components** — DT's licence policies are enabled but inert: 0/83 components carry a resolved licence (even `busybox = null`). A global Copyleft policy produces 0 violations but evaluates *nothing*. Not a new exposure, but the policy gives false confidence | S | [TOOLING.md § Dependency-Track](TOOLING.md#dependency-track), [yocto-concepts.md](yocto-concepts.md) |
| **R-4** | ~~RAUC keyring path broke OTA on wrynose~~ **FIXED 2026-09-01**, kept as the cautionary entry. Newer meta-rauc installs `system.conf` + keyring to `/usr/lib/rauc/`, but our `system.conf` hardcoded `path=/etc/rauc/development-1.cert.pem` — a directory that does not exist on 6.0. Every `rauc install` failed with *"failed to load CA file"*. **`rauc status` never reads the keyring**, so the full 2026-08-30 A/B verification (slot switching, `mark-bad`, `mark-active`, `A → B → A`) passed while the install path was dead — boot behaviour and install behaviour are different code. Now a *relative* path, resolved against the config dir, so it survives the next relocation. **Lesson: an A/B proof is not an OTA proof; test an actual install after any meta-rauc bump** | — | [rauc-ab-updates.md](rauc-ab-updates.md) |

---

## Missing proof

| ID | Gap | Effort | Detail |
|----|-----|:------:|--------|
| **P-1** | **Per-device SSH host keys not isolated** — each A/B slot generates its own key on first boot; every slot switch trips `REMOTE HOST IDENTIFICATION HAS CHANGED`. Fix: persist `/etc/ssh` onto `/data` and regenerate on first boot | S | [rauc-ab-updates.md § Still open](rauc-ab-updates.md), [TOOLING.md § RAUC](TOOLING.md#rauc) |
| **P-2** | **Daily pen-test → DefectDojo is opt-in and never verified end-to-end in the nightly** (🟢) — enabled by having `keys/defectdojo.env` + `PENTEST_TARGET` on the build host; non-fatal if it fails. Whether a real nightly run has ever succeeded through all five stages needs a log review | S | [status.md](status.md), [pen-testing.md](pen-testing.md) |
| **P-3** | **OTA "Install update" button is visualise-first** (🟢) — the fleet dashboard returns the `ota-deploy.sh` command rather than triggering a device self-install. The RAUC/Nexus streaming path is proven; device-self-install is not wired | M | [status.md](status.md), [fleet-app.md](fleet-app.md) |
| **P-4** | ~~Wrynose (6.0 LTS) RAUC A/B hardware proof~~ **DONE (2026-08-30)** — verified on the real Pi 3 B+: U-Boot **2026.01** sources `boot.scr` (`rauc.slot=A panic=10` present), `mark-bad` → `BOOT_ORDER=B` → boots `p3`/slot B, `mark-active other` → back to A, both slots `good`, tries 3/3. Two bugs were caught en route — the bundle signing with upstream's demo key (`layer.conf` `?=` beats a recipe `?=`) and a missing `empty-root-password` making login impossible. Production was cut over the same day. | — | [status.md](status.md), [yocto-concepts.md § wrynose migration](yocto-concepts.md#the-wrynose-migration-where-poky-went-and-how-this-was-rebuilt) |
| **P-5** | ~~First wrynose *release* not yet cut~~ **DONE (2026-09-01)** — `2026.09.1` cut, signed, verified, snapshotted to DT (123 components, 19735 VEX entries), published to Nexus and **OTA'd to the Pi 3 end-to-end**: streamed from Nexus into slot B, rebooted, device reports `IMAGE_VERSION=2026.09.1` on `mmcblk0p3`, both slots `good`. The exercise paid for itself — it found that **OTA had been broken since the wrynose cutover** (see R-4) and that `cut-release.sh` was using a stale DT key. There is now also a wrynose release master on the build host, which there wasn't before | — | [rauc-ab-updates.md](rauc-ab-updates.md), [status.md](status.md) |

---

## Improvement

| ID | Gap | Effort | Detail |
|----|-----|:------:|--------|
| **I-1** | ~~Wrynose (6.0 LTS) bump~~ **DONE — base image 2026-08-29, RAUC A/B 2026-08-30, production cut over 2026-08-30.** `poky` is retired upstream (frozen Nov 2025); wrynose ships as separate `openembedded-core`+`bitbake 2.18`+`meta-yocto` repos. Clean 5080-task build, `cve-check` → `sbom-cve-check` ported (SBOM/VEX pipeline unchanged — only the file-locating code moved), `S=${UNPACKDIR}` and `IMAGE_FEATURES` recipe fixes applied. Production now builds `build-wrynose/` + `build-rauc-wrynose/`; the scarthgap tree is retained as a one-variable rollback (`SCHULTZ_RELEASE=scarthgap`, see [scripts/release-profile.sh](../scripts/release-profile.sh)) and stays supported upstream to April 2028. | L | [yocto-concepts.md § wrynose migration](yocto-concepts.md#the-wrynose-migration-where-poky-went-and-how-this-was-rebuilt), [TOOLING.md § Yocto](TOOLING.md#yocto--openembedded) |
| **I-2** | **OTA-able kernel updates** — currently kernels live on the shared `/boot` FAT partition and can only be updated by SD re-flash. Upstream's newer `boot.cmd.in` loads the kernel from the A/B rootfs (`load ${BOOT_DEV} … boot/Image`); adopting it would make kernel updates bundleable. **Unblocked on wrynose** now that U-Boot 2026.01 is proven (R-2 narrowed); still blocked on scarthgap. | L | [rauc-ab-updates.md § Still open](rauc-ab-updates.md), [TOOLING.md § RAUC](TOOLING.md#rauc) |
| **I-3** | **dm-verity on the hardened squashfs** — the ext4 RAUC bundles already use `verity` format (dm-verity on the *bundle*). Adding dm-verity to the *running rootfs* (every block checked at runtime) needs an initramfs + the verity setup; meaningful for a deployed device, over-engineering for the current lab scope | L | [rauc-ab-updates.md § Stronger still](rauc-ab-updates.md) |
| **I-4** | **`kas` manifest for layer pinning** — currently layers are cloned/pinned by hand in `fetch-layers.sh`. `kas` YAML manifests declare all layers, branches, and patches in one file and reproduce the whole build environment in one command. Worth adopting when juggling more than 2–3 layers or adding a second maintainer. | M | [yocto-concepts.md](yocto-concepts.md) |
| **I-5** | **Licence data injection** — add CPE-based licence lookup (e.g. from the CVE report or a `pkg:generic` → SPDX expression map) to `manifest-to-cyclonedx.py` so DT's Copyleft policies evaluate real data | M | [TOOLING.md § Dependency-Track](TOOLING.md#dependency-track), [scripts/manifest-to-cyclonedx.py](../scripts/manifest-to-cyclonedx.py) |
| **I-6** | **SBOM/pen-test archives still live under `~/build/`** — `SBOM_ARCHIVE_DIR` is pinned in the host's `keys/dtrack.env` to `~/build/sbom-archive`, which is *scarthgap's* build dir. Deliberate for now (one unbroken audit trail across the cutover), but retiring the scarthgap tree would delete the archive with it. Move to a release-independent path before ever `rm -rf`-ing `~/build` | S | [security-and-auditing.md](security-and-auditing.md) |
| **I-7** | ~~Nexus has no cleanup policy~~ **mitigated 2026-08-30** — the blob store filled completely (`FileBlobStore ... Usable space: 0`), which surfaced as HTTP 401/500 on every mirror PUT and looked like a credentials problem. Root cause: mirroring *two* Yocto series' sources **and** sstate (42.6 GB) into a 40.2 GB blob store. Disk grown to 48 GB and the nightly now mirrors **sources only** (18.0 GB, leaving ~22 GB free) — sstate is derived data the local `SSTATE_DIR` already serves. Still no *cleanup policy*, so the sources repo grows unbounded over time; and `Docker.raw` is sparse (48 GB apparent, never shrinks), so the Mac's data volume is the real ceiling | M | [TOOLING.md § Nexus](TOOLING.md#nexus-yocto-side-integration) |
| **I-8** | **Nexus has no backup** — a Docker Desktop disk *shrink* on 2026-08-30 destroyed every volume on that host, taking the Nexus blob store with it (and SonarQube's Postgres, whose analysis history was unrecoverable). Nexus was rebuilt and all four releases re-published from `~/build-rauc/releases/` on the build host, so nothing was permanently lost *this time* — but that only worked because the build host happened to hold the masters. The releases repo is real data, not cache | M | [TOOLING.md § Nexus](TOOLING.md#nexus-yocto-side-integration) |
| **I-9** | **hashserv systemd unit still runs scarthgap's binary** — `~/poky/bitbake/bin/bitbake-hashserv`, even though production is wrynose. It works (the DB lives outside every build dir), but it quietly makes `~/poky` load-bearing for production builds rather than just for the rollback. `setup-hashserv.sh` already resolves the binary from the release profile; the running unit was never restarted onto it | S | [scripts/setup-hashserv.sh](../scripts/setup-hashserv.sh) |

---

## Deliberate ceilings (not to-dos)

| Gap | Why it's a ceiling | Detail |
|-----|--------------------|--------|
| **Hardware secure boot** | Pi 3 boot ROM loads firmware unsigned; no OTP/fuse mechanism exists on this board. Needs Pi 4/5 + fused keys. | [status.md](status.md), [TOOLING.md § Hardware](TOOLING.md#raspberry-pi-3-model-b) |
| **Bootloader in A/B slots** | Pi 3 boot ROM always loads the first FAT partition; there is no alternate-partition mechanism. `RAUC_BUNDLE_SLOTS = "rootfs"` by design — `/boot` is shared and unversioned. | [TOOLING.md § RAUC](TOOLING.md#rauc), [rauc-ab-updates.md](rauc-ab-updates.md) |
| **testssl / Lynis in pen-test** | No TLS port on the image; no `bash` in the rootfs. Both tools are skipped by design and logged explicitly rather than silently omitted. | [pen-testing.md](pen-testing.md), [status.md](status.md) |
| **Yocto wrynose on poky** | poky has no `wrynose` branch yet (checked 2026-08-23). Not a decision to defer — just waiting on upstream. Trigger in README tells us when to act. | [README.md](../README.md) |
