# Operating a build: status checks, interruptions, recovery

`first-build.md` covers the happy path of a first build. This is the
complementary "day 2" doc: how to check on a build that's already running
in the background, and what to do when it isn't healthy anymore — grounded
in a real incident hit while building this project (2026-07-02).

## Checking on a detached build

`remote-build.sh` launches bitbake via `setsid nohup ... & disown`, logged
to `<build dir>/schultz-build.log` (a sibling of `theSchultzYocto/` — **not**
inside the git repo). The build dir comes from
[scripts/release-profile.sh](../scripts/release-profile.sh): `~/build-wrynose`
for the current release, `~/build` if you run with
`SCHULTZ_RELEASE=scarthgap`. From the Mac:

```sh
ssh rpi5g16nvme 'tail -n 60 ~/build-wrynose/schultz-build.log; echo ---; pgrep -af bitbake-worker | wc -l'
```

A healthy build shows a steady stream of `NOTE: recipe ...: task ...:
Started/Succeeded` lines and at least one `bitbake-worker` process. Task
counts (`Running task N of TOTAL`) only ever go up — if the log hasn't
moved in a while and there are zero `bitbake-worker` processes, it's dead
(see below for why).

## What survives, what doesn't

- SSH disconnecting: fine, that's the entire point of `setsid`/`nohup`.
- The **build host rebooting**: not survivable. A reboot kills every
  process regardless of how detached it was. This isn't specific to our
  setup — nothing short of a systemd service (or similar) restarts a build
  automatically after a reboot, and we don't run one.

To tell these apart, check host uptime, not just the log:

```sh
ssh rpi5g16nvme uptime
```

If uptime is suspiciously short relative to when the log went quiet, the
host rebooted out from under the build.

## Incident: killed by a host reboot (2026-07-02)

What happened, in order:

1. `rpi5g16nvme` rebooted unexpectedly around 21:44 (confirmed via `uptime`
   showing only ~22 minutes; ruled out `unattended-upgrades` — its log showed
   a 404 fetching a package at 15:57 and it aborted before installing
   anything, hours earlier; no OOM-killer entries in `dmesg`/`journalctl`;
   disk had 360G free, RAM had 13Gi free). Likely a plain power interruption
   — this Pi has no onboard RTC, and its boot-time clock looked reset,
   consistent with that rather than a graceful shutdown.
2. Relaunching immediately hit an unrelated problem: a `ParseError` on
   `recipes-core/images/schultz-bundle.bb` (`Could not inherit file
   classes/bundle.bbclass`). This recipe needs the `meta-rauc` layer, which
   is intentionally *not* fetched/added by default (RAUC is opt-in — see
   `scripts/fetch-rauc-layers.sh`). BitBake parses **every** `.bb` file
   matched by `BBFILES` up front regardless of build target, so one
   incomplete recipe sitting in a real `.bb` path broke the *entire* build,
   including the unrelated `schultz-image-minimal` target. Fixed by renaming
   it to `schultz-bundle.bb.example` (matching the convention already used
   for `secrets.h.example`) so BitBake's `recipes-*/*/*.bb` glob skips it.
   **Lesson: any scaffolded-but-not-wired-up recipe belongs in a `.bb.example`
   file, not a real `.bb` file, until its layer dependency actually exists.**
3. After that fix, the build resumed from where it left off (~task
   2463/3524) but `elfutils`'s `do_create_spdx` task failed with
   `json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)`.
   The file it choked on (`.../elfutils/0.191/spdx_work/deps.json`) was
   0 bytes, timestamped the exact minute of the reboot. A search for other
   0-byte files with that same timestamp across the whole build tree found
   **238 of them**, including kernel/compiler intermediate `.o` files —
   consistent with an abrupt power loss losing dirty page-cache writes that
   had been logged as "Succeeded" but not yet physically flushed to disk.
   `sstate-cache/` (the supposedly-safe restore point) had a handful of
   0-byte entries from the same timestamp too.
   **Lesson: Make-based incremental builds (the kernel, gcc, etc.) track
   staleness by mtime, not content — a truncated `.o` file newer than its
   source can be silently treated as "already built." bitbake's per-task
   success/failure tracking doesn't catch this either, since the crash
   happened after the task logged success. Don't try to surgically resume
   after this kind of corruption; it's not fully trustworthy even task by
   task.**

### Recovery

```sh
# 1. Make sure nothing is still running before touching the build dir
ssh rpi5g16nvme 'pgrep -af bitbake'
# kill any PIDs it lists (SIGTERM first, SIGKILL if a bitbake-server lingers)
ssh rpi5g16nvme 'kill <pids...>'

# 2. Wipe the untrustworthy state -- only tmp/. downloads and sstate now live
#    OUTSIDE the build dir (~/yocto-downloads, ~/yocto-sstate, shared by every
#    build dir), so this rebuilds mostly from sstate instead of re-fetching and
#    recompiling the world.
ssh rpi5g16nvme 'rm -rf ~/build-wrynose/tmp'

# 3. Relaunch -- safe to re-run, see remote-build.sh
ssh rpi5g16nvme 'cd theSchultzYocto && ./scripts/remote-build.sh'
```

A wipe means a genuinely fresh build (`Loaded 0 entries from dependency
cache` in the log confirms it), not a fast sstate-restore — expect it to
take as long as the very first build.

Since 2026-08-12 that is less punishing than it sounds: `sstate-cache/` is
mirrored to Nexus by
[populate-nexus-mirror.sh](../scripts/populate-nexus-mirror.sh) after every
nightly build. Wiping the local copy doesn't change any task signature, so a
post-wipe build pulls the same task outputs back over the LAN via
`SSTATE_MIRRORS` instead of recompiling them — as long as the last mirror push
succeeded (`mirror rc=0` in the nightly's log tail).

## Stopping a build on purpose

```sh
ssh rpi5g16nvme 'pgrep -af bitbake'   # note the PIDs
ssh rpi5g16nvme 'kill <pids...>'      # SIGTERM; add -9 if bitbake-server lingers
```

`bitbake-cookerdaemon.log` logging repeated "Server will shut down after all
clients exit. Server refused shutdown." lines is normal chatter while a
client is still attached — not an error.
