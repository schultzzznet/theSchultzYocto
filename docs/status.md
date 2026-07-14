# theSchultzYocto — status at a glance

A living snapshot of what's built, what's **verified on real hardware**, and
what's deliberately out of reach. Last updated **2026-07-11** (pen-test +
hardening scans feeding a DefectDojo aggregation pane, and a Tesla-style fleet
dashboard + device agent — both verified end-to-end, the former against the live
Raspberry Pi 3 B+).

**Latest release:** `2026.07.1` (codename `scarthgap`) — Ubuntu-style CalVer,
built on Yocto 5.0.19 LTS, pinned by git tag `v2026.07.1` and its
`PROVENANCE.txt`. The device **self-reports** it via `/etc/os-release`
(`IMAGE_ID=theschultzyocto`, `IMAGE_VERSION=2026.07.1`), and it was delivered to
the running Pi **over the air** (`2026.07.0` → `2026.07.1`, slot A → B) with no
re-flash. The `rolling` line tracks scarthgap point-releases nightly.

**Legend:** ✅ verified on hardware · 🟢 built &amp; wired (on-hardware proof
pending) · ❌ not possible here (with reason)

## The image

| Capability | Status | Notes |
|---|---|---|
| Custom minimal Yocto image | ✅ | `schultz-image-minimal`, scarthgap (5.0 LTS), `raspberrypi3-64` |
| Boots on a real Pi 3 B+ | ✅ | first boot 2026-07-05 |
| Serial console | ✅ | `enable_uart=1` + `console=ttyS0,115200`, over the [ESP32 WiFi bridge](../tools/esp32-serial-bridge/) |
| Networking (eth0 DHCP + SSH) | ✅ | reachable + `ssh root@…`; note: Pi 3 B+ `lan78xx` inits late, so on the sysvinit image re-run `udhcpc -i eth0` after reboot (the systemd RAUC image handles it) |
| Reproducible remote build | ✅ | `scripts/remote-build.sh` on the Pi 5 build host; sstate/source via a Nexus mirror |

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

## Fleet management (Tesla-style)

| Capability | Status | Notes |
|---|---|---|
| Fleet dashboard app | 🟢 | Spring Boot app in `the-docker-swarm-ai/apps/fleet-app` (templated on `talk-app`); built + container smoke-tested — heartbeat ingest, Nexus release listing, update flow, dashboard render — with simulated devices |
| Device agent (`schultz-agent`) | 🟢 | stdlib-only heartbeat recipe here; the real agent→fleet contract verified off-device (fields map 1:1, graceful degradation) |
| Release awareness (Nexus) | ✅ | live: current vs latest-available computed from `schultz-releases-raw` (`2026.07.1` discovered) |
| OTA from the dashboard | 🟢 | visualize-first: **Install update** returns the `ota-deploy.sh` command (the proven RAUC/Nexus streaming path), not a new self-install |
| On a real Pi + in the cluster | 🟢 | pending: rebuild an image with `IMAGE_INSTALL:append = " schultz-agent"` + `make deploy-fleet-k3s` |

Deep dive: [fleet-app.md](fleet-app.md).

## Updates &amp; boot

| Capability | Status | Notes |
|---|---|---|
| A/B dual-slot boot (U-Boot) | ✅ | verified 2026-07-06: U-Boot booted slot A, then B after an update, then rolled back to A (serial trace `A → B → A`) |
| OTA update (`rauc install`) | ✅ | delivered **over the network** to the *running* Pi (`2026.07.0`→`2026.07.1`) with zero downtime: written to idle slot B, one reboot switched to B, `/etc/os-release` flipped; a marked-bad slot auto-rolled back to A |
| Signed + integrity-checked bundles | ✅ | `verity` (dm-verity) + signed; device keyring = our dev cert — signature verified on-device at install |
| Release artifact store + OTA source | ✅ | each release published to the Nexus raw repo `schultz-releases-raw`; the Pi `rauc install`s **straight from Nexus** (HTTP range → true streaming, no scp) via `ota-deploy.sh <version> <ip> --reboot` |
| Scripted release cut | ✅ | `cut-release.sh`: build → verify `rauc info` == version → SBOM/VEX to DT → archive + `PROVENANCE.txt` → publish to Nexus → git tag |
| Hardened variant (squashfs, immutable) | 🟢 | `schultz-image-hardened`/`schultz-bundle-hardened`: no debug-tweaks + read-only-rootfs + **squashfs** + baked SSH key. **Proven booting on the real Pi 3 B+ (2026-07-07): `/dev/mmcblk0p3 on / type squashfs (ro)`.** Path: flash the published base image (`base-images/schultz-ab-base-squashfs-kernel.wic.gz` — squashfs-capable `/boot` kernel, `panic=10`, `type=raw` slots, `rootfstype` dropped for auto-detect), boot ext4 slot A, then `SCHULTZ_BUNDLE_BASENAME=schultz-bundle-hardened ota-deploy.sh 2026.07.1-hardened <ip> --local --reboot` copies the 35 MB squashfs to slot B and boots it. `panic=10` auto-reboots + rolls back a bad slot with no human (proven live). **Cut as tracked release `2026.07.1-hardened`: SBOM+VEX in Dependency-Track (56 findings), bundle+image+SBOM+VEX+PROVENANCE on Nexus, git tag `v2026.07.1-hardened`, and re-deployed by true HTTP-range streaming straight from Nexus.** See [rauc-ab-updates](rauc-ab-updates.md) |
| Hardware secure boot | ❌ | the Pi 3 boot ROM loads firmware from the FAT partition **unsigned** — a hardware ceiling, not a config gap (needs Pi 4/5 + fused keys / TPM) |

Deep dive + the on-hardware rollback demo: [rauc-ab-updates.md](rauc-ab-updates.md).

## Signing &amp; keys

| Capability | Status | Notes |
|---|---|---|
| Dev signing keys (GPG + x509) | ✅ | `scripts/generate-signing-keys.sh`; private halves gitignored |
| RAUC bundle signing | ✅ | `RAUC_KEY_FILE`/`RAUC_CERT_FILE`; `rauc info` shows the inline signature + version `2026.07.0` |
| On-device bundle verification | ✅ | `/etc/rauc/development-1.cert.pem` keyring — a real `rauc install` verified the signature before writing slot B |

---

*What "🟢" honestly means:* built, internally consistent, and it compiles — but
the boot/rollback/verify behaviour is confirmed **on the board, over serial**,
which is the last mile and the fun part. See the linked walkthroughs.
