# theSchultzYocto — status at a glance

A living snapshot of what's built, what's **verified on real hardware**, and
what's deliberately out of reach. Last updated **2026-07-05** (first real boot
on a Raspberry Pi 3 B+).

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
| A/B dual-slot boot (U-Boot) | 🟢 | rootfs A=`p2` / B=`p3`; U-Boot `BOOT_ORDER` + try-counts with auto-rollback |
| OTA update (`rauc install`) | 🟢 | writes the inactive slot → reboot switches → rollback on failure |
| Signed + integrity-checked bundles | 🟢 | `verity` (dm-verity) + signed; device keyring = our dev cert, so only our bundles install |
| Hardware secure boot | ❌ | the Pi 3 boot ROM loads firmware from the FAT partition **unsigned** — a hardware ceiling, not a config gap (needs Pi 4/5 + fused keys / TPM) |

Deep dive + the on-hardware rollback demo: [rauc-ab-updates.md](rauc-ab-updates.md).

## Signing &amp; keys

| Capability | Status | Notes |
|---|---|---|
| Dev signing keys (GPG + x509) | ✅ | `scripts/generate-signing-keys.sh`; private halves gitignored |
| RAUC bundle signing | 🟢 | `RAUC_KEY_FILE`/`RAUC_CERT_FILE`, verified at build |
| On-device bundle verification | 🟢 | `/etc/rauc/development-1.cert.pem` keyring — proof is the on-hardware `rauc install` |

---

*What "🟢" honestly means:* built, internally consistent, and it compiles — but
the boot/rollback/verify behaviour is confirmed **on the board, over serial**,
which is the last mile and the fun part. See the linked walkthroughs.
