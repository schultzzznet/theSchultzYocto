# Security &amp; auditing: the supply-chain posture of this image

This document is the deep dive behind the tooling described in
[yocto-concepts.md](yocto-concepts.md#dependency-track--this-ones-real-now-not-just-described).
It exists to answer three questions a security reviewer (or future-you) will
eventually ask:

1. **What do we actually know** about the vulnerabilities in a shipped image,
   and how confident should we be?
2. **How do we keep that knowledge current** without a human babysitting it?
3. **How would we prove any of it** in an audit — trace a single "this CVE is
   fine" decision all the way back to evidence?

It is deliberately honest about limitations. A security control you
misunderstand is worse than one you don't have, because it buys false calm.

---

## 1. The moving parts, and what each one *vouches for*

| Artifact / tool | Produced by | Vouches for | Does **not** vouch for |
|---|---|---|---|
| `.manifest` | image build (`do_rootfs`) | the exact packages + versions installed in the rootfs | source provenance, build integrity |
| CPE on each SBOM component | `manifest-to-cyclonedx.py` from cve-check | "this component maps to *this* NVD product@version" | that NVD's data is complete/correct |
| SBOM (CycloneDX 1.6) | `manifest-to-cyclonedx.py` | the bill of materials DT scans | runtime behaviour, config hardening |
| cve-check verdicts | Yocto `cve-check` at build time | Yocto's opinion: Patched / Ignored / Unpatched, per CVE per recipe | CVEs newer than the build's CVE-DB snapshot |
| VEX (CycloneDX) | `manifest-to-vex.py` from cve-check | "Yocto already resolved / dismissed these CVEs, here's why" | exploitability in *your* deployment |
| Dependency-Track findings | DT's NVD matching + the VEX | the current, triaged vulnerability list | that a finding is reachable/exploitable |

The single most important sentence in this whole document:

> **A scanner match is not a vulnerability. It is a *hypothesis* that a
> vulnerability might be present.** Everything here is machinery for turning that
> flood of hypotheses into a short list a human can actually act on — without
> silently throwing away anything real.

---

## 2. The trust chain (and where it can break)

```
NVD (CPE ranges, CVSS)
      │  DT matches component CPE → CVE
      ▼
Dependency-Track finding  ──────────────┐
      ▲                                 │ suppressed / annotated by
      │ CPE from                        ▼
cve-check product table            VEX (analysis.state + detail)
      ▲                                 ▲
      │ per-recipe verdict              │ generated from
      └──────────── Yocto cve-check ────┘
                         ▲
                         │ CVE_STATUS[...] annotations (Ignored cases)
                    recipe .bb / .bbappend  (git-pinned)
```

Every link is a place trust is *transferred*, and therefore a place it can be
*misplaced*:

- **NVD → finding:** relies on the CPE being right. We deliberately use an
  **ANY-vendor** CPE (`cpe:2.3:a:*:<product>:<version>:...`) because NVD vendor
  strings are inconsistent (glibc and bash are both vendor `gnu`). The
  trade-off: an ANY-vendor CPE could in principle match a *different* vendor's
  product that happens to share the name. In practice OE product names
  (`busybox`, `openssl`, `dropbear`) are specific enough that this is rare, and
  the failure mode is a *false positive* (extra finding to triage), never a
  false negative — which is the safe direction.
- **cve-check → VEX:** relies on Yocto's verdict being correct. `Patched` means
  Yocto detected a backported/upstream fix; `Ignored` means a human wrote a
  `CVE_STATUS[CVE-x] = "reason: ..."` in the recipe. That human judgement is
  now **security-relevant source code** — it is code-reviewed and git-pinned
  like any other, which is exactly where such decisions belong.
- **VEX → suppression:** relies on DT correlating the VEX correctly. This is the
  part that bit us (see §7 of yocto-concepts) and is why the VEX is CVE-centric
  with a single root ref. The tripwire that this stays correct is in §4 below.

---

## 3. Keeping it current: the daily scan

Dependency-Track **already** re-scans every project against its NVD mirror on
its own schedule — so a CVE disclosed *today* against a version you shipped
*last month* shows up **without anyone re-uploading anything**. That is the
whole point of a living SBOM and it is the strongest single reason this is worth
doing at all.

What DT does **not** do on its own is refresh the **VEX**. The suppressions are
static once applied. So a newly-disclosed CVE that Yocto has *since* patched
would sit in DT as an active finding forever, and — worse — a CVE that gets
re-classified (disputed, not-applicable) would keep nagging. That gap is what
[daily-security-scan.sh](../scripts/daily-security-scan.sh) closes:

1. `git pull --ff-only` — pick up recipe changes pushed from the workstation.
1b. **Track the Yocto LTS branch** — ff-only pull point-releases for whichever
   release `$SCHULTZ_RELEASE` selects (`wrynose` by default, per
   [release-profile.sh](../scripts/release-profile.sh)), so the image actually
   receives LTS CVE backports (otherwise cve-check keeps flagging CVEs that LTS
   already fixed). Only layers already on that release branch are pulled, so the
   pinned `meta-rauc-community` stays frozen. `SCHULTZ_UPDATE_LTS_LAYERS=0`
   freezes all. Note the layer set changed with wrynose: the `poky` convenience
   bundle was retired after scarthgap, so this now tracks `openembedded-core`,
   `bitbake` and `meta-yocto` separately alongside `meta-raspberrypi`/`meta-rauc`.
2. `bitbake schultz-image-minimal` — refresh the CVE database
   (`cve-update-db`), re-run cve-check, and regenerate the `.manifest`,
   `cve-summary.json` and `pkgdata` the SBOM/VEX are built from.
3. [upload-sbom.sh](../scripts/upload-sbom.sh) — push the CPE-enriched SBOM and
   a freshly-scoped VEX, and archive a timestamped copy of both.
4. [build-rauc-bundle.sh](../scripts/build-rauc-bundle.sh) — rebuild the
   deployable A/B image + **signed** update bundle from the same freshly-pulled
   tree (in the separate RAUC build dir), verify the bundle's signature +
   `compatible`, and archive it with `latest.*` symlinks. It runs under the same
   heavy-build lock, and a failure here is logged but never masks the SBOM/VEX
   result. Set `SCHULTZ_BUILD_RAUC=0` to skip it on hosts that only need the
   security refresh.

Install it once on the build host (cron, `03:30` local by default):

```sh
ssh <build-host> '~/theSchultzYocto/scripts/install-daily-scan.sh 03:30'
```

For step 1's `git pull` to refresh recipes hands-off, the host's layer checkout
needs an `origin` remote tracking GitHub (one-time:
`git remote add origin <url> && git fetch origin &&
git branch --set-upstream-to=origin/master master`). Without it the pull simply
skips and the scan rebuilds whatever is currently checked out — so recipe
changes still land, they just have to arrive via `sync-to-host.sh` instead.

**Naming.** The Dependency-Track *project* is named after the repo/layer —
`theSchultzYocto` — so DT groups every build of it under one entry, matching how
you think about the source. The image the SBOM actually describes
(`schultz-image-minimal`) is recorded as the BOM's root component, not the DT
project name, so nothing is lost: the project reads as the repo, the document
still names the real firmware. (Override the project name with
`DTRACK_PROJECT_NAME` if you ever track more than one repo in the same DT.)

**Rolling vs released versions.** The daily scan targets one stable version
(`rolling` by default) that it updates *in place* — a continuously-monitored
"living SBOM" rather than 365 dated projects a year. Named **releases** use
Ubuntu-style CalVer `YYYY.MM.PATCH` (e.g. `2026.07.0`), with a codename that
tracks the Yocto LTS base (`scarthgap`): bump `PATCH` when you re-cut a line with
fresh LTS backports (`2026.07.0` → `2026.07.1`), bump `YYYY.MM` for a new line.
Cut one for anything you actually flash and keep — it becomes an immutable
point-in-time record of "what shipped", pinned by the matching git tag
`vYYYY.MM.PATCH` and its `PROVENANCE.txt` (exact layer commits + sha256). Note
**"LTS" is the maintenance promise** — rebuilding a line with backports — **not**
the version-string format; the board name lives in the DT *project* (add it there
if you ever target a second machine), so versions stay pure release numbers.

What the daily cadence **catches**: newly-disclosed CVEs (via DT's own re-scan),
newly-*fixed* CVEs and re-classifications (via the refreshed VEX), and image
composition drift (via the rebuilt manifest). What it **does not** catch: a
zero-day nobody has a CVE for yet, or a vulnerability in your *configuration*
rather than a package version.

> A systemd user-timer is a reasonable alternative to cron (it adds
> `Persistent=` catch-up if the host was asleep at 03:30). It's not used here
> only to avoid the user-lingering / D-Bus friction of `systemctl --user` on a
> headless box; the scan script itself is scheduler-agnostic.

---

## 4. The recipe-scoping guarantee (why it stays correct "always")

The VEX is scoped to *the recipes that actually produce the image's packages* —
not the whole build closure. This matters for correctness, not just size: a
project-wide-by-CVE suppression must only ever be built from the recipes really
in the image. Three mechanisms keep that scope honest **automatically** as you
add or remove recipes:

1. **It is derived, never hand-maintained.** Every run reads the *current*
   `.manifest`, resolves each package to its recipe via
   `pkgdata/runtime-reverse` (the authoritative `PN:` map), and scopes to
   exactly those recipes. Add a package to the image → it appears in the
   manifest → it's in scope. Remove one → it's gone. There is no list to forget
   to update.
2. **The daily rebuild regenerates the manifest** before every upload, so the
   scope can never lag the image.
3. **A tripwire in the log.** `manifest-to-vex.py` prints an audit line to
   stderr every run, captured in the scan log:

   ```
   [manifest-to-vex] scoped 58 recipes from 83 manifest packages (2 unresolved); 1154 VEX entries {'resolved': 1136, ...}
   [manifest-to-vex] unresolved (no recipe, not scoped -- normally just packagegroups/meta pkgs): packagegroup-core-boot, ...
   ```

   If "recipes scoped" ever collapses or "unresolved" spikes, the `pkgdata`
   path or the manifest path is wrong and the VEX is mis-scoped — visible
   immediately, not months later. `manifest-to-cyclonedx.py` emits the parallel
   CPE-coverage line for the same reason.

Because suppression is project-wide by CVE, the generator also **refuses to
suppress any CVE that cve-check marks `Unpatched` in even one in-scope recipe**.
That is the guard that makes "coarse" safe: the worst case is an *extra* visible
finding, never a hidden real one.

---

## 5. How to audit a single decision

Say DT shows `busybox / CVE-2022-48174` as **suppressed** and someone asks you
to justify it. The trail, end to end:

1. **In Dependency-Track:** open the finding → *Audit* tab. The analysis state
   (`RESOLVED`) and the `detail` string carry the reason verbatim, e.g.
   `Yocto cve-check: Patched`. That is the assertion.
2. **The archived VEX:** `build/sbom-archive/<name>-<version>-<ts>.vex.cdx.json`
   contains the exact `analysis` block uploaded that day — the immutable copy of
   what we told DT. (`grep CVE-2022-48174` it.)
3. **cve-check's own record:** `build/tmp/log/cve/cve-summary.json` for that
   build shows the recipe, status, and (for `Ignored`) the `detail` +
   `description`. This is Yocto's primary evidence.
4. **The source of the verdict:**
   - `Patched` → Yocto detected a fix; the applied patch is in the recipe's
     `SRC_URI` (a `.patch` file) or the pinned `SRCREV`, both git-tracked.
   - `Ignored` → a `CVE_STATUS[CVE-2022-48174] = "reason: ..."` line in the
     recipe `.bb`/`.bbappend`, code-reviewed and attributable via `git blame`.
5. **Reproducibility:** the layer commit + pinned `SRCREV`s mean the whole build
   — and therefore every verdict — can be regenerated. Nothing in the chain is a
   black box.

The same trail run *backwards* answers "why is this still active?": it's
`Unpatched` in cve-check (real work to do), or `in_triage`/`upstream-wontfix`
(acknowledged, deliberately visible), or **not in cve-check at all** — the
"unknown to cve-check" class, where DT's NVD mirror is simply fresher than the
build's CVE-DB snapshot. That last class is a feature: we never assert "fixed"
for something Yocto hasn't vouched for.

---

## 6. The audit trail &amp; retention

| Evidence | Where | Retention |
|---|---|---|
| Uploaded SBOM + VEX (per run) | `build/sbom-archive/*.cdx.json` | kept (audit record; prune deliberately) |
| Scan run logs (incl. scoping tripwire) | `build/security-scan-logs/scan-*.log` | last 30 runs |
| Yocto cve-check verdicts | `build/tmp/log/cve/cve-summary.json` | per build (sstate) |
| Vulnerability audit history | Dependency-Track, per project | per DT retention policy |
| Recipe changes + `CVE_STATUS` decisions | git history of this layer | permanent |

Two properties make this trustworthy: the archived SBOM/VEX are **immutable
copies of exactly what was uploaded** (not a re-derivation that might differ),
and the human judgement calls (`CVE_STATUS`) live in **version control**, so
"who decided this was fine, when, and why" is always answerable.

---

## 7. Threat model &amp; limitations (read this part twice)

This pipeline is a **static, supply-chain** view. It is strong at "are we
shipping a package version with a known CVE?" and says **nothing** about:

- **Exploitability / reachability.** A vulnerable function may never be called.
  CVSS here is NVD's *base* score, not an environmental one. `resolved` asserts
  *a fix is present*, not *it was unexploitable*.
- **Configuration &amp; hardening.** Weak `sshd` settings, `debug-tweaks` left on
  (this learning image ships it!), open ports, default creds — none of that is a
  package CVE, so **none of it shows up in *this* pipeline**. It is covered by a
  separate, complementary one: the pen-test &amp; hardening scans
  (nmap / ssh-audit / testssl / Lynis / checksec / kernel-hardening-checker) that
  feed **DefectDojo** — see [pen-testing.md](pen-testing.md). Locking the
  underlying issues down (drop `debug-tweaks`, remove `bluetooth`/`wifi`, compile
  out USB mass storage) remains a native-Yocto lever — see the attack-surface
  hardening knobs in [yocto-concepts.md](yocto-concepts.md) and
  [local.conf.sample](../conf/templates/schultz/local.conf.sample).
- **Runtime integrity.** Nothing here attests the *built binary* matches the
  source, or that the flashed image wasn't tampered with. That's the job of
  reproducible builds + signing (see the RAUC/signing notes in yocto-concepts).
- **Things without a CVE.** Zero-days, and vulns in first-party code, are
  invisible to a CVE scanner by definition.

Known, accepted trade-offs in *this* implementation:

- **Generic PURLs** (`pkg:generic/...`) mean DT's ecosystem-aware matching is
  off; we lean entirely on the CPE. Correct, but it is one mechanism, not two.
- **ANY-vendor CPE** — see §2. Errs toward false positives (safe direction).
- **VEX is project-wide by CVE**, not per-component — coarser than ideal,
  bounded safe by the `Unpatched` guard (§4). The residual gap: a CVE shared by
  two in-scope recipes with *divergent* status would be kept visible on both
  (conservative), never hidden.
- **cve-check DB lag** is real; the daily rebuild minimises it but there is
  always a window where NVD is ahead of the last build.

None of these are reasons not to do this. They are the boundary of what "green
in Dependency-Track" is allowed to mean, and stating that boundary is itself a
security control.

---

## 8. Incident response: a new CVE drops

1. **It appears in DT** at the next NVD re-scan (DT's own schedule) as an active
   finding — *no rebuild needed* to be alerted.
2. **Triage the assertion, not the number:** is the vulnerable code path present
   and reachable in a headless Pi image? Check severity *and* applicability.
3. **If Yocto has a fix:** the next `bitbake` pulls the updated recipe / CVE-DB;
   cve-check flips it to `Patched`; the daily scan's refreshed VEX suppresses it
   automatically. Nothing manual.
4. **If Yocto has no fix yet but it's not applicable:** encode that judgement as
   a `CVE_STATUS[...]` in the recipe (`.bbappend`), commit it, push. It becomes a
   reviewed, auditable dismissal — never a manual click in a UI that no one can
   later explain.
5. **If it's real and applicable:** that's the signal this entire pipeline
   exists to surface. Patch, rebuild, re-flash.

---

## 9. Operational security of the pipeline itself

- **API key least privilege:** the Dependency-Track key needs only
  `BOM_UPLOAD` + `VIEW_PORTFOLIO` (and project create for auto-create), **not**
  admin. A CI credential that can only upload can't be turned into portfolio
  compromise.
- **Key hygiene:** stored in a gitignored `keys/dtrack.env` sibling (never in
  the repo), whitespace-stripped before use (a trailing `\n` yields a bare HTTP
  400 — see [/memories] and the note in `upload-sbom.sh`), rotated periodically.
- **Transport &amp; access:** the DT instance is on the local network; if it were
  ever exposed, it must be behind TLS + authn — the findings themselves are a
  roadmap of your weaknesses.
- **The scanner is not the product.** Keep the humans on the real signal (§7);
  the automation's job is to make that signal small and honest.
- **Nothing in this pipeline runs here.** Dependency-Track, DefectDojo and the
  Nexus mirror all live on other machines, so a build depends on hosts this repo
  does not control. Which services those are, where each credential lives, and
  what breaks when one disappears is catalogued once for all the projects in the
  [external services registry](../../SynologyIndexer3.0/EXTERNAL_SERVICES.md)
  (sibling `SynologyIndexer3.0` repo) — update it when this pipeline gains or
  drops a dependency.

---

## 10. "Life in general" — the transferable lessons

- **Verify controls empirically.** The VEX uploaded with *HTTP 200 and did
  nothing* for hours. "The API accepted it" is not "it worked." Measure the
  effect, not the status code.
- **Automate the dismissals, not the decisions.** Machines are good at
  re-applying "Yocto already fixed this 1,136 times." Humans are for the 38 that
  are real. Invert that and you get either alert fatigue or hidden risk.
- **Make every dismissal explainable.** A suppression without a reason is
  indistinguishable from a bug. Every one here carries its `cve-check` verdict
  and is traceable to a git-reviewed line.
- **Prefer false positives to false negatives** at every fork (ANY-vendor CPE,
  the `Unpatched` guard). Over-reporting wastes time; under-reporting ships a
  hole.
- **Defense in depth:** build-time (`cve-check`) + continuous (Dependency-Track)
  + triage (VEX) each cover the others' blind spots. No single one is trusted
  alone.

---

*See also:* [yocto-concepts.md](yocto-concepts.md) for the how-it-works walk-through,
[pen-testing.md](pen-testing.md) for the complementary pen-test + hardening pipeline that
feeds DefectDojo (the cross-tool aggregation pane, and a mirror of this pipeline's findings),
[scripts/manifest-to-cyclonedx.py](../scripts/manifest-to-cyclonedx.py) (SBOM + CPEs),
[scripts/manifest-to-vex.py](../scripts/manifest-to-vex.py) (VEX),
[scripts/upload-sbom.sh](../scripts/upload-sbom.sh) (upload + archive),
[scripts/daily-security-scan.sh](../scripts/daily-security-scan.sh) (the daily job).
