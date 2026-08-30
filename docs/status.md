# theSchultzYocto — status at a glance

A living snapshot of what's built, what's **verified on real hardware**, and
what's deliberately out of reach. Last updated **2026-08-30** — the day the
wrynose (6.0.3 LTS) migration finished: the RAUC A/B stack was proven on the Pi
3 B+ (a full `A → B → A` rollback under U-Boot 2026.01), and **production was
cut over from scarthgap**. See
[yocto-concepts.md](yocto-concepts.md#the-wrynose-migration-where-poky-went-and-how-this-was-rebuilt)
for the full story.

**Which release the pipeline builds** is now a single variable,
`SCHULTZ_RELEASE` in [scripts/release-profile.sh](../scripts/release-profile.sh)
(`wrynose`). Every script resolves its `oe-init-build-env`, build dirs, layer
paths and CVE-report path from it, so a rollback is one line and needs no
rebuild — the scarthgap tree is still on disk and still buildable with
`SCHULTZ_RELEASE=scarthgap`.

**Latest release:** `2026.07.1` — Ubuntu-style CalVer, pinned by git tag
`v2026.07.1` and its `PROVENANCE.txt`. The device **self-reports** it via
`/etc/os-release` (`IMAGE_ID=theschultzyocto`, `IMAGE_VERSION=2026.07.1`), and it
was delivered to the running Pi **over the air** (`2026.07.0` → `2026.07.1`,
slot A → B) with no re-flash. It was cut on scarthgap (Yocto 5.0.19); the next
cut will be the first on wrynose. The `rolling` line now tracks wrynose
point-releases nightly.

**Legend:** ✅ verified on hardware · 🟢 built &amp; wired (on-hardware proof
pending) · ❌ not possible here (with reason)

## The image

| Capability | Status | Notes |
|---|---|---|
| Custom minimal Yocto image | ✅ | `schultz-image-minimal` on `raspberrypi3-64`; wrynose (6.0.3 LTS) since the 2026-08-30 cutover, originally proven on scarthgap (5.0 LTS) which still builds via `SCHULTZ_RELEASE=scarthgap` |
| Boots on a real Pi 3 B+ | ✅ | first boot 2026-07-05 |
| Serial console | ✅ | `enable_uart=1` + `console=ttyS0,115200`, over the [ESP32 WiFi bridge](../tools/esp32-serial-bridge/) |
| Networking (eth0 DHCP + SSH) | ✅ | reachable + `ssh root@…`; note: Pi 3 B+ `lan78xx` inits late, so on the sysvinit image re-run `udhcpc -i eth0` after reboot (the systemd RAUC image handles it) |
| Reproducible remote build | ✅ | `scripts/remote-build.sh` on the Pi 5 build host |
| Shared source/sstate mirror (Nexus) | ✅ | `SOURCE_MIRROR_URL` + `SSTATE_MIRRORS` were set on 2026-07-03 but pointed at **empty** repos until `populate-nexus-mirror.sh` (2026-08-12) started filling them; needed `BB_GENERATE_MIRROR_TARBALLS` too, or the 38 git clones stay unmirrorable. Both halves proven by restore, not just by upload |
| Shared hash-equivalence server | ✅ | `bitbake-hashserv` systemd unit on the build host, db outside `build/`, seeded from the local one; without it mirrored sstate resolves to different unihashes and never matches |
| Scoped Nexus write account | ✅ | `yocto-ci`: `ADD/EDIT/READ/BROWSE` on the three raw repos only — verified 201 in-scope, 403 out-of-scope, 403 on the admin API |
| Yocto 6.0 (wrynose) migration — base image | ✅ | `openembedded-core`+`bitbake 2.18`+`meta-yocto` replace the retired `poky` bundle; clean 5080-task build, `sbom-cve-check` → SBOM/VEX pipeline verified (81 components, 79 CPE) against the same scarthgap output shape. Isolated in `~/wrynose-layers/` + `build-wrynose/` — does not touch production |
| Yocto 6.0 (wrynose) migration — RAUC A/B | ✅ | **verified on the real Pi 3 B+ 2026-08-30.** Isolated `build-rauc-wrynose/` tree, image + signed bundle, U-Boot **2026.01** (oe-core's native version). Unlike the scarthgap U-Boot 2025.04 regression below, 2026.01 *does* source `boot.scr`: booted slot A with `root=/dev/mmcblk0p2 rauc.slot=A panic=10`, `mark-bad` → `BOOT_ORDER=B` → rebooted to `root=/dev/mmcblk0p3 rauc.slot=B` with A reported `bad`, then `mark-active other` → back to A with both slots `good` and tries restored 3/3. Two real bugs were caught getting here — see *Signing &amp; keys* and the note below |

*Two bugs the wrynose RAUC build surfaced, both fixed before the hardware run:*
(1) **the bundle was signed with upstream's public demo key** — `meta-rauc-community`'s
`layer.conf` sets `RAUC_KEY_FILE ?=` / `RAUC_CERT_FILE ?=`, and every `layer.conf`
parses *before* any recipe, so our recipe's `?=` silently no-opped and the bundle
verified as `CN = Test Org Development-1`. Fixed by making ours unconditional `=`.
(2) **root login was impossible** — `debug-tweaks` is three features, and dropping it
for explicit ones missed `empty-root-password`; without it the rootfs postprocess
forces an unknown random password into `/etc/shadow`, so serial *and* SSH both reject
a login that no password can satisfy.

## Supply-chain security

| Capability | Status | Notes |
|---|---|---|
| SBOM (CycloneDX) → Dependency-Track | ✅ | tracked as project `theSchultzYocto` |
| CPE-enriched CVE matching | ✅ | generic PURLs found 0 → CPEs found ~100 |
| cve-check → VEX auto-dismissal | ✅ | 100 active findings → **46** (the genuine signal); 0 real ones hidden |
| Daily automated re-scan | ✅ | cron 03:30 on the build host, archives every SBOM/VEX |
| Package-feed signing (GPG) | 🟢 | templated in `local.conf` |

Deep dive: [security-and-auditing.md](security-and-auditing.md).

## Pen-testing &amp; findings aggregation

| Capability | Status | Notes |
|---|---|---|
| Pen-test / hardening scan | ✅ | nmap + ssh-audit + checksec + kernel-hardening-checker, run 2026-07-11 against the live Pi (`192.168.1.226`) |
| DefectDojo aggregation pane | ✅ | Product `theSchultzYocto`: **385 active findings** (6 Crit / 50 High / 204 Med / 124 Low / 1 Info) across all tools, one screen |
| Dependency-Track SCA mirror | ✅ | DT's triaged findings exported (FPF, 231 KB) into DefectDojo — SCA + pen-test correlated in one pane |
| Native parsers used where they exist | ✅ | nmap / ssh-audit / testssl / DT-FPF native; a small generic normaliser only for lynis / checksec / kernel-hardening-checker |
| testssl / Lynis | ⏭️ | skip **by design** on this image (no TLS port; busybox has no `bash`) — logged, never faked |
| Daily automated pen-test → DefectDojo | 🟢 | opt-in, non-fatal stage in the daily scan (`keys/defectdojo.env` + `PENTEST_TARGET`); never masks the SBOM result |

Deep dive: [pen-testing.md](pen-testing.md).

## Fleet management (Tesla-style) — LIVE

Verified end-to-end on real hardware **2026-07-14**: the agent-enabled image was
OTA'd to the Pi 3 B+ (slot B) and its card shows live in the cluster-hosted
dashboard at `http://delli7c6g32.local/fleet`.

| Capability | Status | Notes |
|---|---|---|
| Fleet dashboard app | ✅ | Spring Boot app (`the-docker-swarm-ai/apps/fleet-app`, templated on `talk-app`) **deployed to k3s** — cosign-signed image, 2/2 pods, CNPG `fleet-db`, Traefik `/fleet` ingress |
| Device agent (`schultz-agent`) | ✅ | running on the real Pi 3 B+ under systemd, heartbeating real telemetry (version, boot slot B, 57.5 °C, uptime, mem, IP) every 30 s |
| Release awareness (Nexus) | ✅ | live: current vs latest-available from `schultz-releases-raw`; the Pi's card reads "up to date" on `2026.07.1` |
| OTA from the dashboard | 🟢 | visualize-first: **Install update** returns the `ota-deploy.sh` command (the proven RAUC/Nexus streaming path), not a device self-install |
| A/B slot fit | ✅ | full python3 overflowed the 213 MB slot (224 MB) → pinned granular `python3-core/netclient/json/io` → 192 MB |

Deep dive: [fleet-app.md](fleet-app.md).

## Updates &amp; boot

| Capability | Status | Notes |
|---|---|---|
| A/B dual-slot boot (U-Boot) | ✅ | verified 2026-07-06: U-Boot booted slot A, then B after an update, then rolled back to A (serial trace `A → B → A`); **re-proven 2026-08-19** on a freshly flashed card: `mark-bad` → `BOOT_ORDER=B` → serial `Found valid RAUC slot B` (`root=…p3 rauc.slot=B`) → `mark-active other` → `Found valid RAUC slot A`, ending with both slots `good` |
| OTA update (`rauc install`) | ✅ | delivered **over the network** to the *running* Pi (`2026.07.0`→`2026.07.1`) with zero downtime: written to idle slot B, one reboot switched to B, `/etc/os-release` flipped; a marked-bad slot auto-rolled back to A |
| Signed + integrity-checked bundles | ✅ | `verity` (dm-verity) + signed; device keyring = our dev cert — signature verified on-device at install |
| Release artifact store + OTA source | ✅ | each release published to the Nexus raw repo `schultz-releases-raw`; the Pi `rauc install`s **straight from Nexus** (HTTP range → true streaming, no scp) via `ota-deploy.sh <version> <ip> --reboot` |
| Scripted release cut | ✅ | `cut-release.sh`: build → verify `rauc info` == version → SBOM/VEX to DT → archive + `PROVENANCE.txt` → publish to Nexus → git tag |
| Hardened variant (squashfs, immutable) | 🟢 | `schultz-image-hardened`/`schultz-bundle-hardened`: no debug-tweaks + read-only-rootfs + **squashfs** + baked SSH key. **Proven booting on the real Pi 3 B+ (2026-07-07): `/dev/mmcblk0p3 on / type squashfs (ro)`.** Path: flash the published base image (`base-images/schultz-ab-base-squashfs-kernel.wic.gz` — squashfs-capable `/boot` kernel, `panic=10`, `type=raw` slots, `rootfstype` dropped for auto-detect), boot ext4 slot A, then `SCHULTZ_BUNDLE_BASENAME=schultz-bundle-hardened ota-deploy.sh 2026.07.1-hardened <ip> --local --reboot` copies the 35 MB squashfs to slot B and boots it. `panic=10` auto-reboots + rolls back a bad slot with no human (proven live). **Cut as tracked release `2026.07.1-hardened`: SBOM+VEX in Dependency-Track (56 findings), bundle+image+SBOM+VEX+PROVENANCE on Nexus, git tag `v2026.07.1-hardened`, and re-deployed by true HTTP-range streaming straight from Nexus.** See [rauc-ab-updates](rauc-ab-updates.md) |
| Hardware secure boot | ❌ | the Pi 3 boot ROM loads firmware from the FAT partition **unsigned** — a hardware ceiling, not a config gap (needs Pi 4/5 + fused keys / TPM) |
| Bootloader pinned to U-Boot 2024.01 | ✅ | **deliberate, and re-proven on hardware 2026-08-19.** Taking upstream meta-rauc-community's newer `scarthgap` branch drags in `lts-u-boot-mixin` (U-Boot 2025.04, which exists for the RPi5); on the Pi 3 B+ our `boot.scr` then never took effect — `/proc/cmdline` carried the VideoCore firmware's args with **no `rauc.slot=`, no `panic=10`, no `BOOT_ORDER` handling**, so no slot switching and no rollback. It still booted (because `/boot/cmdline.txt` hardcodes `root=/dev/mmcblk0p2`) and `rauc status` still reported both slots "good" — **the failure is invisible from userspace**; only the serial console showed it. Reverted; the good card proves `rauc.slot=A` + `panic=10` are back. Note a bootloader change reaches hardware **only by SD re-flash** — `RAUC_BUNDLE_SLOTS = "rootfs"`, and the Pi 3 boot ROM always loads the first FAT partition, so `/boot` cannot be A/B |

Deep dive + the on-hardware rollback demo: [rauc-ab-updates.md](rauc-ab-updates.md).

## Signing &amp; keys

| Capability | Status | Notes |
|---|---|---|
| Dev signing keys (GPG + x509) | ✅ | `scripts/generate-signing-keys.sh`; private halves gitignored |
| RAUC bundle signing | ✅ | `RAUC_KEY_FILE`/`RAUC_CERT_FILE`; `rauc info` shows the inline signature + version `2026.07.0`. Set with unconditional `=`, **not `?=`** — `meta-rauc-community`'s `layer.conf` also defaults them (to its public example keys) and every `layer.conf` wins over a recipe's `?=` |
| On-device bundle verification | ✅ | `/etc/rauc/development-1.cert.pem` keyring — a real `rauc install` verified the signature before writing slot B |

---

*What "🟢" honestly means:* built, internally consistent, and it compiles — but
the boot/rollback/verify behaviour is confirmed **on the board, over serial**,
which is the last mile and the fun part. See the linked walkthroughs.
