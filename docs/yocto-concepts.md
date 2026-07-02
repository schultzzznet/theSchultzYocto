# Yocto, explained (with this repo as the running example)

## What Yocto actually is

**Yocto Project is not a Linux distro.** It's a build framework — BitBake (the
task-execution engine) plus a big pile of metadata (recipes, classes, config
files) organized into **layers** — whose job is to let you construct *your
own* distro for embedded/custom hardware. When people say "I built a custom
Yocto image," what they mean is: they used this framework to assemble one.

The pieces, concretely:

- **BitBake** — the engine. Reads recipes, resolves a dependency graph,
  executes tasks (fetch, patch, configure, compile, install, package...) in
  the right order, in parallel where possible. Analogous to `make`, but
  distro-scale and cross-compilation-first.
- **OpenEmbedded-Core (OE-Core)** — the foundational layer of metadata:
  toolchain recipes, core Unix userland, base classes almost everything else
  builds on.
- **Poky** — a *reference distribution*: BitBake + OE-Core + a default distro
  policy (`meta-poky`) + reference machines (`meta-yocto-bsp`, mostly QEMU
  targets). It's a sane, working starting point, not "the" Yocto distro.
- **Layers** (`meta-*`) — modular, stackable collections of recipes. Convention
  over configuration: everything is a layer, including your own customizations.
  In this repo, `meta-raspberrypi` is the Raspberry Pi hardware-support layer,
  and this whole repo *is* our own layer (collection name `schultz`, see
  [conf/layer.conf](../conf/layer.conf)).
- **Recipes** (`.bb` files) — build instructions for one piece of software:
  where to fetch it, how to configure/compile/install it, what it depends on,
  what license it's under. [recipes-core/images/schultz-image-minimal.bb](../recipes-core/images/schultz-image-minimal.bb)
  is a recipe — just one whose "output" is a whole root filesystem image
  instead of a single package.
- **Classes** (`.bbclass`) — shared behavior recipes inherit (`inherit
  cve-check`, `inherit systemd`, etc.) instead of repeating logic everywhere.
- **Machine config** — hardware target definition (kernel, bootloader,
  architecture tuning). `raspberrypi3-64` comes from `meta-raspberrypi`.
- **Distro config** — cross-cutting policy: init system, package manager
  format, default features. We use the stock `poky` distro
  (`DISTRO = "poky"` in [local.conf.sample](../conf/templates/schultz/local.conf.sample)).

## How you actually make a distro

Assembling a distro is choosing/writing five things, in practice:

1. **Pick your layers.** Start from OE-Core + a distro policy (Poky is the
   easy default), add a BSP layer for your hardware
   (`meta-raspberrypi`), add feature layers as needed (`meta-openembedded`
   for a much bigger package catalog, `meta-virtualization`,
   `meta-security`, hundreds more exist — browse
   [layers.openembedded.org](https://layers.openembedded.org/)).
2. **Create your own layer.** This is where *your* distro's identity lives —
   your custom recipes, your image definition, any patches/overrides to
   upstream recipes. `bitbake-layers create-layer` scaffolds one; ours was
   built by hand but the shape is the same (`conf/layer.conf` +
   `recipes-*/` directories).
3. **Pick a MACHINE.** Which hardware you're targeting — determines kernel,
   bootloader, architecture. Ours: `raspberrypi3-64`.
4. **Write an image recipe.** An image recipe is just `IMAGE_INSTALL` (what
   packages go in) plus `IMAGE_FEATURES` (feature bundles like
   `ssh-server-openssh`, `debug-tweaks`, `read-only-rootfs`). Ours extends
   `core-image-minimal` and adds SSH — see
   [schultz-image-minimal.bb](../recipes-core/images/schultz-image-minimal.bb).
   This is also where "minimal" stops being a marketing word and becomes a
   real design decision: every package you add is a package you now have to
   maintain, patch, and justify.
5. **Build and iterate.** `bitbake <image>` builds the whole thing; `devtool`
   gives you a fast edit/rebuild loop on one recipe at a time without
   rebuilding the world; `bitbake-layers show-layers`/`show-recipes` tell you
   what's actually in play. Shared state (`sstate-cache`) means rebuilds
   after the first one are fast — only what changed gets rebuilt.

The whole "is this actually available" question matters more than it sounds:
we found out the hard way that `nano`/`htop` aren't in OE-Core or
`meta-raspberrypi` — they're in `meta-openembedded`, a layer we don't have.
Every package you reference has to actually be *provided* by one of your
configured layers, or BitBake fails fast (`Nothing RPROVIDES 'x'`) rather than
silently substituting something.

## Why this is a smart way to do it

Compared to "take a general-purpose distro (Debian/Ubuntu/Raspberry Pi OS)
and strip it down" or "hand-roll a rootfs from scratch":

- **Reproducibility.** Same layers + same config + same recipes = bit-for-bit
  the same image, on any build host. No "works on my machine" for the OS
  itself.
- **Actually minimal, not diet-general-purpose.** You start from nothing and
  add only what you choose (`IMAGE_INSTALL`), rather than starting from
  everything a general distro ships and trying to delete your way to small.
  Smaller image = smaller attack surface, less to patch, less to explain.
- **Cross-compilation is the default, not an afterthought.** Build for
  `arm64`, `armv7`, `riscv64`, whatever, from any host architecture, using
  the same workflow every time.
- **License visibility is built in, not bolted on.** Every recipe declares
  `LICENSE`. Anything with a restrictive/non-free flag (like the RPi
  Wi-Fi/Bluetooth/GPU firmware we hit) requires an explicit
  `LICENSE_FLAGS_ACCEPTED` — you can't accidentally ship something whose
  license you didn't look at.
- **It's what the industry actually runs.** Automotive, networking gear,
  industrial control, most "embedded Linux products" you can name are built
  this way — meaning long-term vendor support, a large layer ecosystem, and
  transferable skills.
- **The tradeoff, honestly:** steeper learning curve than Buildroot (simpler,
  Makefile/Kconfig-based, less flexible layering) and much steeper than
  "just apt-get on Raspberry Pi OS." You're paying setup/learning cost for
  control and reproducibility. For a one-off hobby project that's a real
  cost; for anything you'll maintain for years, or need to trust, it's a
  good trade.

## Keeping it updated

Yocto ships releases on a rhythm (see the [Releases wiki](https://wiki.yoctoproject.org/wiki/Releases)):
non-LTS releases roughly every 6 months, LTS releases roughly every 4 years
with multi-year support tails. We're tracking `scarthgap` (5.0 LTS, supported
into 2028) — see [first-build.md](first-build.md) for why we ended up there
instead of the newer `wrynose` (its poky/meta-raspberrypi branches don't
exist yet, as of this writing — verify with `git ls-remote --heads` before
assuming a branch is cut).

Updating means moving **all your layers together** to matching release
branches — poky, `meta-raspberrypi`, and your own layer's
`LAYERSERIES_COMPAT` all need to agree, or BitBake will refuse to parse.
Practically: read the release's migration notes, bump branches, rebuild, fix
what breaks (recipe renames, removed classes, changed defaults do happen
between releases).

For patching *within* a release rather than jumping releases:

- Recipes pin exact versions (`PV`) and often exact source revisions
  (`SRCREV`) — nothing moves under you silently. Getting a fix means someone
  (upstream layer maintainers, or you) bumps that pin.
- `devtool upgrade <recipe>` automates a lot of the "bump version, refresh
  patches, see what broke" cycle for one recipe at a time.
- The upstream Yocto/OE-Core and `meta-raspberrypi` projects continuously
  backport fixes to their LTS branches — `git pull` on those layers
  periodically, not just at major-version-jump time.

## Safe and secure, concretely

- **`inherit cve-check`** — a standard OE-Core class that cross-references
  every recipe's version against the NVD CVE database and reports known
  vulnerabilities per-package at build time (`tmp/deploy/cve/` reports).
  This is the single most useful "am I shipping something known-bad" check
  and it's not extra tooling to bolt on, it's already in the framework.
- **Minimal `IMAGE_INSTALL` = minimal attack surface**, by construction, not
  by after-the-fact hardening. Nothing is running or installed that you
  didn't explicitly ask for.
- **`LICENSE_FLAGS_ACCEPTED`** forces a conscious decision before anything
  non-free/restrictively-licensed ships — you can't silently end up
  distributing something you haven't reviewed.
- **`IMAGE_FEATURES += "read-only-rootfs"`** is available when you're ready
  for it — a read-only root filesystem meaningfully limits what a runtime
  compromise can persist or tamper with. Not enabled here (this image is a
  debug/learning sandbox, deliberately loose via `debug-tweaks`), but it's a
  one-line feature away for anything closer to production.
- **Reproducible builds** double as a supply-chain check: if you can rebuild
  the same inputs and get the same output, you have a real basis for
  verifying "what's actually in this image" rather than trusting a binary
  blob.
- **Deeper topics that exist but aren't set up here** (worth knowing the
  names for later): secure boot / verified boot chains, `meta-secure-core`,
  dm-verity/IMA integrity measurement, signed package feeds. All real,
  all more involved than this learning project needs yet.

## Fitting into a real toolchain: git, Artifactory, Dependency-Track

### Git — it's already doing more than you think

Beyond hosting our layer, git is also the fetch mechanism for a big chunk of
*upstream* source: most recipes use `SRC_URI = "git://...;branch=..."` with a
pinned `SRCREV`, so a huge amount of what BitBake fetches is a git operation
under the hood, version-pinned per recipe.

Managing many layers (each its own git repo, each needing a matching release
branch) gets painful with raw submodules. The community answer is
**[kas](https://kas.readthedocs.io/)** — a YAML manifest that declares your
layers, branches, and patches, and sets up the whole build environment in one
command. `meta-raspberrypi` ships its own `kas-poky-rpi.yml` for exactly this
reason. Google's `repo` tool (Android-style multi-repo manifests) is the
other common option. Worth adopting once you're juggling more than 2-3
layers — not needed yet here.

What deliberately stays *out* of git either way: `build/`, `downloads/`,
`sstate-cache/`, `tmp/` — huge, host-specific, and fully reproducible from
recipes + config. Already in [.gitignore](../.gitignore).

### Artifactory — shared caches and artifact storage

Two BitBake variables turn Artifactory (or Nexus, or any generic HTTP repo)
into shared build infrastructure instead of a place to dump files:

- **`SSTATE_MIRRORS`** — point it at a generic Artifactory repo and every
  build host/CI runner can fetch pre-built task outputs (compiled
  `gcc-cross`, `glibc`, etc.) instead of rebuilding them. This is the same
  idea as Yocto's own public sstate mirror
  (the `core/yocto/sstate-mirror-cdn` fragment in the new `bitbake-setup`
  tool enables exactly this, pointed at `sstate.yoctoproject.org`) — you'd
  just point at your own Artifactory instance instead.
- **`SOURCE_MIRROR_URL` / `PREMIRRORS`** — mirror upstream source tarballs.
  Protects you when an upstream project deletes a tag or goes offline
  mid-project (it happens), and is faster than re-fetching from the public
  internet every time.

Both are templated (commented out) in
[local.conf.sample](../conf/templates/schultz/local.conf.sample) — fill in
a real Artifactory host + repo names and uncomment.

Beyond mirrors, Artifactory's format-aware repo types (Debian, RPM) can host
an actual package feed if you ever want field updates via `opkg`/`apt`
instead of full image re-flashes — and its generic repos are a normal place
to publish the final `.wic.bz2` images as versioned release artifacts, same
as any other build output.

### Dependency-Track — this one's basically already happening

Good news: recent Yocto releases generate a full **SPDX SBOM by default**,
no configuration needed (the `create-spdx` class is in `INHERIT_DISTRO` out
of the box). Once `schultz-image-minimal` finishes building, there will be an
SBOM sitting at:

```
tmp/deploy/images/raspberrypi3-64/schultz-image-minimal-raspberrypi3-64.spdx.json
```

listing every recipe that went into the image, its version, license, and
source. Dependency-Track's `/api/v1/bom` endpoint accepts SPDX directly (not
just CycloneDX), so the pipeline is exactly the one you already run for
other projects: build → grab that `.spdx.json` → POST it to your
Dependency-Track instance (mind the trailing-newline-in-API-key gotcha —
same class of bug either way).

This is now wired up, not just described: `scripts/upload-sbom.sh` does the
upload (reads `DTRACK_URL`/`DTRACK_API_KEY` from the environment, strips
whitespace from the key first). `remote-build.sh` auto-runs it after a
successful build via `scripts/run-build-and-report.sh`, but only if
`DTRACK_URL` is set — export it (and `DTRACK_API_KEY`) on the build host
before running `deploy.sh`/`remote-build.sh` to opt in; leave it unset and
nothing changes.

This complements `cve-check` rather than duplicating it: `cve-check` is a
one-shot, build-time check against NVD at the moment you build.
Dependency-Track is continuous monitoring of a *living* SBOM — it catches
CVEs disclosed against a package version *after* you already shipped it,
months later, without needing to rebuild anything. Feeding both from the
same build gives you shift-left detection *and* ongoing coverage.

The `SPDX_INCLUDE_*`/PURL-enrichment options mentioned in the SBOM docs
(`cargo_common`, `go-mod`, `pypi`, `npm`, `cpan*` classes populate
ecosystem-specific Package URLs) are worth turning on if/when the image
grows beyond C/C++ components — they make the SBOM's package identities
match up more precisely with what Dependency-Track/OWASP matches against.

## Signing and OTA updates — what's real here vs. what's still a project

This is the one area where it's worth being explicit about the line between
"scaffolded and build-verified" and "a genuine remaining project," because
some of it fundamentally can't be verified without physical hardware access.

**Actually working, verified on rpi5g16nvme:**

- `scripts/generate-signing-keys.sh` generates two independent things: a GPG
  key (`schultz-dev`) for package feed signing, and a self-signed x509
  dev cert/key pair for RAUC bundle signing. Both confirmed to actually run
  successfully (`gpg`/`openssl` are on the build host, keys land in
  `../keys/`, gitignored, script is idempotent).
- Package feed signing (`INHERIT += "sign_package_feed"` +
  `PACKAGE_FEED_GPG_NAME`) is real, standard OE-Core functionality — it
  signs the IPK repository index, not individual `.ipk` files (that's an
  IPK format limitation, not a shortcut we took; RPM has real per-package
  signing instead, via a separate `sign_rpm`/`sequoia` class). Templated,
  commented out, in `local.conf.sample`.
- `recipes-core/images/schultz-bundle.bb` is a real RAUC bundle recipe using
  the documented `inherit bundle` pattern with confirmed variable names
  (`RAUC_BUNDLE_FORMAT`, `RAUC_BUNDLE_SLOTS`, `RAUC_SLOT_rootfs`,
  `RAUC_KEY_FILE`, `RAUC_CERT_FILE`).

**Deliberately not implemented — a real project, not a config tweak:**

- RAUC's actual value (atomic, rollback-safe updates) needs A/B rootfs
  partitions and a bootloader (U-Boot) that tracks which slot to boot —
  Raspberry Pi's native firmware boot process doesn't have that state
  machine built in. This is a genuine architecture change (new `.wks`
  partition layout, U-Boot bring-up on `raspberrypi3-64`, a
  `rauc-conf.bbappend` with a real `system.conf`), not something to
  configure your way into.
- `scripts/fetch-rauc-layers.sh` (opt-in, not run yet) points at
  [meta-rauc](https://github.com/rauc/meta-rauc) and
  [meta-rauc-community](https://github.com/rauc/meta-rauc-community)'s
  `meta-rauc-raspberrypi` reference layer — a real, community-maintained
  example of exactly this integration, worth adapting from rather than
  reinventing.
- Note on branch naming: meta-rauc uses `gh_<release>` (e.g.
  `gh_scarthgap`), not plain `<release>` like poky/meta-raspberrypi —
  confirmed by checking the repo directly, another instance of "verify,
  don't assume, even for release branch names."
- The honest reason this stopped here: whether U-Boot actually boots,
  whether slot-switching actually works, whether a bad update actually
  rolls back — none of that is checkable by inspecting build logs. It
  needs a screen or serial cable on the actual Pi. That's a "you, with the
  hardware in hand" step, not something to fake confidence about. See
  [docs/serial-console.md](serial-console.md) for the actual hardware/wiring
  needed to get that access.


