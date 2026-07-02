# Build host setup

BitBake needs a real Linux system — no macOS, no native Windows.

## Primary build host: rpi5g16nvme

Verified 2026-07-02 over SSH (`ssh rpi5g16nvme`, passwordless/key-based):

| | |
|---|---|
| OS | Ubuntu 24.04.4 LTS — officially supported by Yocto |
| CPU | 4 cores (Raspberry Pi 5, Cortex-A76, aarch64) |
| RAM | 16GB total, ~13GB free at idle |
| Disk | NVMe, 458GB total, 397GB free |
| Idle temp | ~47°C (worth keeping an eye on under sustained build load) |

This clears every requirement below comfortably — no swap/parallelism tuning
needed. The sections further down (disk space, RAM) are kept as a documented
fallback for the alternative build host: an old 8GB Intel MacBook Pro
(`mbpi5g8no1` / `mbpi5g8no2`).

### Ubuntu 24.04-specific: unprivileged user namespaces

Ubuntu 24.04 restricts unprivileged user namespaces by default (AppArmor
hardening, new in 24.04). BitBake's pseudo/fakeroot mechanism needs them and
fails with `User namespaces are not usable by BitBake, possibly due to
AppArmor.` `scripts/remote-prereqs.sh` relaxes this via
`/etc/sysctl.d/60-apparmor-namespace.conf`
(`kernel.apparmor_restrict_unprivileged_userns=0`) — a real, documented
security trade-off, only reasonable because this is a dedicated, non-shared
build box. See [Ubuntu's release notes](https://discourse.ubuntu.com/t/ubuntu-24-04-lts-noble-numbat-release-notes/39890#unprivileged-user-namespace-restrictions)
for the details and other mitigation options (e.g. a scoped AppArmor profile
instead of a blanket system-wide disable).

## Supported distros

Officially tested (per the [Yocto Reference Manual](https://docs.yoctoproject.org/ref-manual/system-requirements.html#supported-linux-distributions)
for the current 6.0 "Wrynose" release): Ubuntu 22.04/24.04/25.x, Debian
11/12/13, Fedora 42/43, OpenSUSE Leap 15.6/16.0, CentOS Stream 9/10, Rocky/Alma
Linux 8/9. Other distros generally work but aren't validated — if your
distro's Git/tar/Python/make/gcc are too old, see the buildtools note below.

(Note: we actually build against the `scarthgap` branch of poky/meta-raspberrypi,
not `wrynose` — confirmed via `git ls-remote --heads` that neither repo has cut
a wrynose branch yet, even though it's the current named release. See
[first-build.md](first-build.md).)

## Packages (Ubuntu / Debian)

```sh
sudo apt-get install build-essential chrpath cpio debianutils diffstat file \
  gawk gcc git iputils-ping libacl1 libcrypt-dev locales python3 python3-git \
  python3-jinja2 python3-pexpect python3-pip python3-subunit socat texinfo \
  unzip wget xz-utils zstd
```

Make sure the `en_US.UTF-8` locale is enabled:

```sh
locale --all-locales | grep en_US.utf8   # if this prints nothing, do:
sudo dpkg-reconfigure locales             # (needs an interactive shell), or:
echo "en_US.UTF-8 UTF-8" | sudo tee -a /etc/locale.gen
sudo locale-gen
```

On Debian 11 / Ubuntu 22.04 specifically, the distro's `python3-websockets` is
too old for the optional shared-state/hash-equivalence mirror feature. Not
required for a normal build — safe to skip on a first pass. On Debian
12+/Ubuntu 24.04+ it's fine to just install:

```sh
sudo apt-get install python3-websockets
```

## Minimum tool versions

Git 1.8.3.1+, tar 1.28+, Python 3.9+, GNU make 4.0+, gcc 10.1+.

If your distro is older than this (unlikely on anything in the supported list
above), Yocto ships a `buildtools` tarball with working versions of these
tools instead of requiring a distro upgrade — see `scripts/install-buildtools`
in Poky, or the
[System Requirements doc](https://docs.yoctoproject.org/ref-manual/system-requirements.html#required-git-tar-python-make-and-gcc-versions).

## Disk space

Not a concern on rpi5g16nvme (397GB free). For reference / the MacBook Pro
fallback: official guidance is blunt — **140GB free** minimum for a typical
build (that figure is calibrated for a fuller image like `core-image-sato` on
`qemux86-64`). Our target (`schultz-image-minimal`, cross-compiled for arm)
is much lighter, but downloads + sstate-cache + tmp/work still add up fast.
Budget 80-100GB+ if you can, more if you'll iterate a lot or keep several
build trees around.

## RAM — only relevant on the 8GB MacBook Pro fallback

Not relevant on rpi5g16nvme's 16GB (currently ~13GB free at idle). Current
official guidance says **32GB RAM** as a baseline, calibrated for building
heavier images. A minimal headless arm image is lighter, but 8GB (the
MacBook Pro fallback) is still genuinely tight for a modern Yocto build —
some native/toolchain components are memory-hungry to compile regardless of
the target. If you end up on that fallback, expect it to be slow, and take
these precautions so a heavy compile phase doesn't get OOM-killed:

1. **Add generous swap** (16GB+) as a safety net, not a performance feature:

   ```sh
   sudo fallocate -l 16G /swapfile
   sudo chmod 600 /swapfile
   sudo mkswap /swapfile
   sudo swapon /swapfile
   echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
   ```

   (If the root filesystem is Btrfs, a plain swapfile needs extra setup — a
   NOCOW attribute, or use a dedicated swap partition instead.)

2. **Cap parallelism** if you see tasks getting killed (`dmesg` will show
   `Out of memory: Killed process ...`). Add to `build/conf/local.conf`:

   ```
   BB_NUMBER_THREADS = "2"
   PARALLEL_MAKE = "-j 2"
   ```

   Slower, but much less likely to run out of memory. Scale up once you've
   confirmed it's stable.

3. Close everything else on the machine during the first few builds so you
   can see how much headroom you actually have.
