# theSchultzYocto — status at a glance

A living snapshot of what's built, what's **verified on real hardware**, and
what's deliberately out of reach. Last updated **2026-07-06** (signed A/B OTA
with automatic rollback, verified end-to-end on a Raspberry Pi 3 B+).

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

## Updates &amp; boot

| Capability | Status | Notes |
|---|---|---|
| A/B dual-slot boot (U-Boot) | ✅ | verified 2026-07-06: U-Boot booted slot A, then B after an update, then rolled back to A (serial trace `A → B → A`) |
| OTA update (`rauc install`) | ✅ | delivered **over the network** to the *running* Pi (`2026.07.0`→`2026.07.1`) with zero downtime: written to idle slot B, one reboot switched to B, `/etc/os-release` flipped; a marked-bad slot auto-rolled back to A |
| Signed + integrity-checked bundles | ✅ | `verity` (dm-verity) + signed; device keyring = our dev cert — signature verified on-device at install |
| Release artifact store + OTA source | ✅ | each release published to the Nexus raw repo `schultz-releases-raw`; the Pi `rauc install`s **straight from Nexus** (HTTP range → true streaming, no scp) via `ota-deploy.sh <version> <ip> --reboot` |
| Scripted release cut | ✅ | `cut-release.sh`: build → verify `rauc info` == version → SBOM/VEX to DT → archive + `PROVENANCE.txt` → publish to Nexus → git tag |
| Hardened variant (squashfs, immutable) | 🟢 | `schultz-image-hardened`/`schultz-bundle-hardened`: no debug-tweaks + read-only-rootfs + **squashfs** + baked SSH key. Builds, publishes to Nexus, and **installs over the air** into a `type=raw` slot (35 MB vs 164 MB ext4). Boot needs `CONFIG_SQUASHFS=y` in the **shared** `/boot` kernel (added) → it's a **fresh-flash** image, not a rootfs-only OTA; the OTA boot panics + rolls back safely (see [rauc-ab-updates](rauc-ab-updates.md)) |
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
