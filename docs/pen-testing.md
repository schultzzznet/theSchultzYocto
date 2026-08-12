# Pen-testing &amp; findings aggregation: DefectDojo as the single pane

This document covers the layer the supply-chain pipeline deliberately does
**not** — configuration, network exposure, and binary/kernel hardening — and how
all of it, plus the SBOM/CVE work, lands in one place: **DefectDojo**.

If [security-and-auditing.md](security-and-auditing.md) answers *"are we shipping
a package with a known CVE?"*, this one answers the questions a pen-tester
actually opens a laptop to ask:

1. **What is exposed** on the running device, and is the exposed service
   configured well?
2. **How hardened is what we shipped** — the kernel config, the ELF binaries?
3. **Where do all these findings live together**, so "the whole security
   posture" is one screen and not five tools?

It is, like its sibling, deliberately honest about limits. A scan you
misread is worse than one you never ran.

---

## 1. Two tools, one posture: DefectDojo *and* Dependency-Track

These are complementary, not competitors:

| | Dependency-Track | DefectDojo |
|---|---|---|
| **Owns** | the supply-chain loop | the scanner + pen-test loop |
| **Eats** | one SBOM, continuously | 180+ scanner report formats |
| **Superpower** | re-scans your SBOM against fresh NVD/OSV **every day, no re-upload** | dedupes findings **across tools** and tracks them over time |
| **Hierarchy** | Project → Version → Finding | Product → Engagement → Test → Finding |

So Dependency-Track stays the deep SCA engine (it is genuinely better at the one
thing it does — continuous CVE re-analysis of a living SBOM). DefectDojo is the
**aggregation pane**: it collects the pen-test and hardening findings that have
no home in DT, **and** mirrors DT's own triaged findings, so one Product page
reads as the entire security posture of the image.

> **The single most important sentence here:** DefectDojo is where findings from
> *different tools that each see a different slice of reality* are correlated
> into one list — it does not replace any scanner, it makes the set of them
> legible.

One DefectDojo instance serves every project (this repo, the cluster repo,
future ones); `theSchultzYocto` is simply one **Product** in it.

---

## 2. What runs, what it measures, and where it runs

Six tools, each seeing a different slice. Crucially, **each runs where it can
actually see the thing it measures**:

| Tool | Runs on | Reaches | Measures |
|---|---|---|---|
| **nmap** | build host | → device (network) | open ports, service + version |
| **ssh-audit** | build host | → device:22 | SSH key-exchange / host-key / cipher / MAC posture |
| **testssl.sh** | build host | → any TLS port | TLS protocol + cert + cipher config |
| **Lynis** | on the device (over SSH) | the live system | CIS-style host configuration audit |
| **checksec** | build host | the built rootfs | ELF hardening: RELRO / PIE / NX / stack canary |
| **kernel-hardening-checker** | build host | the kernel `.config` | kernel self-protection gaps vs the KSPP baseline |

The build host is the natural home for all of it: it is always on, on the same
LAN as the device, it holds the SSH key the hardened image trusts, and it has
the build tree the binary/kernel checks read. It's the same box the daily scan
runs on — so this is one more optional stage there (§6).

Nothing here exploits anything. There is no brute force, no fuzzing, no auth
bypass — these are **passive, audit-grade** measurements of attack surface and
configuration. That boundary is a deliberate design choice, not a limitation to
apologise for (see §7).

---

## 3. Native parsers first, glue only the gaps

DefectDojo ships 240+ scanner parsers. The rule this pipeline follows — *don't
reinvent a format DefectDojo already speaks* — splits the six tools cleanly:

- **Native parser, uploaded as-is** (no conversion, no guessing at a schema):
  - nmap → `Nmap Scan` (its XML, `-oX`)
  - ssh-audit → `SSH Audit Importer` (its JSON, `ssh-audit -jj`)
  - testssl.sh → `Testssl Scan` (its CSV, `--csvfile`)
  - the Dependency-Track mirror → `Dependency Track Finding Packaging Format
    (FPF) Export` (§4)
- **No native parser → normalised to Generic Findings Import** by
  [pentest-to-defectdojo.py](../scripts/pentest-to-defectdojo.py):
  - Lynis, checksec, kernel-hardening-checker

The normaliser is the only place this project invents anything, and it is
deliberately small. It also carries the **severity philosophy**: everything it
emits is a *hardening recommendation* or a *static binary property*, not a live
exploit, so it is capped modestly (kernel gaps → Low; most checksec weaknesses →
Medium; NX-disabled → High; Lynis warnings → Medium, suggestions → Low). That
keeps Critical/High meaningful for the things that genuinely are — the CVE
findings coming from Dependency-Track.

One ssh-audit quirk worth knowing: DefectDojo's parser requires a top-level
`target` field that some ssh-audit versions omit, so
[pentest-scan.sh](../scripts/pentest-scan.sh) injects it (and verifies the JSON
is a real scan, not a connection-error object) before upload.

---

## 4. Mirroring Dependency-Track into DefectDojo (the "single pane")

The point of aggregation is undone if the SCA findings — the biggest, most real
bucket — aren't in the pane too. But our SBOM has **no vulnerabilities embedded
in it** (that is by design: DT does the CPE→CVE matching, and it re-does it
daily). So uploading the raw SBOM to DefectDojo would import an empty component
list.

The right mechanism is DefectDojo's purpose-built importer for exactly this:
**"Dependency Track Finding Packaging Format (FPF) Export"**.
[upload-pentest.sh](../scripts/upload-pentest.sh):

1. looks up the DT project UUID (`theSchultzYocto` / the `rolling` version),
2. asks DT to export its **triaged** findings —
   `GET /api/v1/finding/project/{uuid}/export` — which is FPF, *post-VEX*, so
   the suppressed false-positives are already gone,
3. reimports that into DefectDojo as the `Dependency-Track SCA (mirror)` test.

So the CVE findings arrive already triaged by everything the SCA pipeline knows,
sitting next to the nmap/ssh-audit/hardening findings. The mirror is optional and
degrades cleanly: no DT creds, or an unresolvable project, and it simply skips.

---

## 5. Clean history across runs: reimport, not import

Every upload uses `/api/v2/reimport-scan/`, not `import-scan/`. Reimport updates
the matching Test **in place** — it closes findings that disappeared since last
run and reopens ones that came back — instead of stacking a fresh pile of
duplicates each night. Combined with `auto_create_context=true` (which creates
the Product / Engagement / Test on first run, the same self-service model as
DT's `autoCreate`), the daily cadence keeps a clean, trending finding history
rather than a landfill. Each tool is its own Test (distinguished by `test_title`)
under one Engagement, so "which tool said this" is never ambiguous.

---

## 6. How to run it

**One-time, on the build host** — install the toolchain and set creds:

```sh
ssh rpi5g16nvme '~/theSchultzYocto/scripts/setup-pentest-tools.sh'
```

Create a gitignored `keys/defectdojo.env` sibling (same convention as
`keys/dtrack.env`):

```sh
DEFECTDOJO_URL=http://delli7c6g32.local:32438
DEFECTDOJO_TOKEN=<API v2 token: DefectDojo UI → User menu → API v2 Key>
PENTEST_TARGET=192.168.1.226            # the device to scan
```

**Ad hoc:**

```sh
PENTEST_TARGET=192.168.1.226 ./scripts/pentest-scan.sh   # writes build/pentest-reports/current/
./scripts/upload-pentest.sh                              # reimports each report + the DT mirror
```

**Automated:** the [daily security scan](../scripts/daily-security-scan.sh) runs
it as an **opt-in, non-fatal** stage — only when `keys/defectdojo.env`
(`DEFECTDOJO_URL`) and `PENTEST_TARGET` are set. A failure here is logged but
**never masks the SBOM/VEX result**, which is that job's primary purpose. Turn it
off with `SCHULTZ_PENTEST=0`; skip individual tools with e.g.
`PENTEST_SKIP="testssl lynis"`.

Everything **skips cleanly rather than faking** when it can't run: no
`PENTEST_TARGET` → the network tools sit out; no TLS port → testssl sits out; a
busybox image with no bash → Lynis sits out; no build tree → checksec and the
kernel check sit out. Each skip is logged with its reason (a scan log that
silently drops a tool is worse than one that says why).

---

## 7. Threat model &amp; limitations (read this part twice)

This is a **configuration + exposure + hardening** view. It is strong at "what is
reachable and how well is it set up / built", and silent about:

- **Exploitation.** Nothing here proves a finding is *exploitable* — no exploit
  is fired, no auth is bypassed, no payload is delivered. `nmap`/`ssh-audit` tell
  you the door exists and how good the lock is, not whether it can be picked.
- **Authenticated / dynamic app testing (DAST).** A minimal headless image
  exposes essentially only SSH, so there is no web app to ZAP/Burp. When a real
  service is added, that becomes a genuine gap to fill (DefectDojo already speaks
  ZAP/Nuclei/Burp — the pane is ready for it).
- **What legitimately did not run.** On this image, two tools skip *by design*:
  **testssl** (there is no TLS service — SSH only), and **Lynis** (the busybox
  minimal/hardened image has no `bash`, which Lynis needs). Those are honest
  gaps, not silent failures; a device with a fuller userland would light them up.
- **Severity is not exploitability.** The hardening findings are ranked by how
  much mitigation they remove, not by a measured attack. 117 "Low" kernel gaps
  is a *posture-improvement backlog*, not 117 holes.

Known, accepted trade-offs:

- **Network checks see the live device; binary/kernel checks see the build
  tree.** On a day the device runs the *hardened* image but the rolling build is
  the *minimal* one, the two describe slightly different artifacts. Both are
  honest about which; align them by pointing `SCHULTZ_BUILD_SUBDIR=build-rauc`
  when you want the binary checks to match the shipped image.
- **The DT mirror is a snapshot.** It reflects DT's findings at export time; DT
  itself remains the live, continuously-re-scanned source of truth for SCA.

None of these is a reason not to do it. They are the boundary of what "green in
DefectDojo" is allowed to mean — and stating that boundary is itself a control.

---

## 8. Verified on real hardware (2026-07-11)

The full chain was run on the build host against the live Pi 3 B+ at
`192.168.1.226`, and the findings landed in DefectDojo Product `theSchultzYocto`:

| Tool | Result |
|---|---|
| nmap | ✅ `22/tcp open ssh` — OpenSSH 9.6 (the only exposed port) |
| ssh-audit | ✅ scanned 12 kex / 4 host-key / 10 MAC algorithms |
| checksec | ✅ rootfs ELFs — busybox ships full RELRO + canary + NX + PIE |
| kernel-hardening-checker | ✅ 117 KSPP hardening gaps in the stock RPi kernel `.config` |
| testssl | ⏭️ skipped — no TLS port (SSH-only image), *by design* |
| Lynis | ⏭️ skipped — busybox image has no `bash`, *by design* |
| **Dependency-Track SCA (mirror)** | ✅ 231 KB FPF exported from DT and imported |

DefectDojo then showed **one aggregated pane** for the Product: **385 active
findings** — 6 Critical, 50 High, 204 Medium, 124 Low, 1 Info — across the nmap,
ssh-audit, checksec, kernel-hardening-checker and DT-SCA-mirror tests. The
Critical/High end is dominated by the mirrored SCA CVEs (the real signal); the
Medium/Low end is the hardening backlog. That is the "complete product" picture:
supply chain, exposure, and hardening, correlated in one place.

---

*See also:* [security-and-auditing.md](security-and-auditing.md) (the SBOM/CVE/VEX
supply-chain half), [status.md](status.md) (what's verified),
[scripts/pentest-scan.sh](../scripts/pentest-scan.sh) (the runner),
[scripts/pentest-to-defectdojo.py](../scripts/pentest-to-defectdojo.py) (the
generic normaliser), [scripts/upload-pentest.sh](../scripts/upload-pentest.sh)
(uploader + DT mirror), [scripts/setup-pentest-tools.sh](../scripts/setup-pentest-tools.sh)
(toolchain install).
