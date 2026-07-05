#!/usr/bin/env python3
"""Generate a CycloneDX 1.6 VEX from Yocto's cve-check data so Dependency-Track
auto-dismisses the CVEs Yocto already knows are fixed or non-applicable.

Why this exists: the CycloneDX SBOM (manifest-to-cyclonedx.py) makes DT *find*
CVEs by CPE. But Yocto routinely backports fixes without bumping the upstream
version, so the CPE still matches NVD's vulnerable range and DT reports a
finding even though the installed binary is already patched. Yocto's cve-check
already knows the true per-CVE status (Patched / Ignored / Unpatched). This
turns that into a VEX so DT stops crying wolf, with an auditable justification
on every dismissal:

  Yocto status      -> CycloneDX analysis.state
  Patched           -> resolved              (backported/upstream fix is present)
  Ignored, by CVE_STATUS detail:
    cpe-incorrect   -> false_positive         (the CPE match itself is wrong)
    disputed        -> false_positive
    not-applicable-config   -> not_affected   (justification: requires_configuration)
    not-applicable-platform -> not_affected   (justification: requires_environment)
    upstream-wontfix        -> in_triage      (real; keep visible for a human)
    (other)         -> not_affected           (justification: requires_configuration)
  Unpatched         -> (omitted on purpose; that IS the real signal DT keeps)

How DT correlates a STANDALONE VEX (verified the hard way on DT 5.0.2):
DT resolves every `vulnerabilities[].affects[].ref` ONLY against the VEX's own
`metadata.component.bom-ref` (the root firmware component). It does NOT match
affects.ref against the per-component purls stored in the project -- a VEX that
references component purls is silently ignored (HTTP 200, zero effect). So this
VEX uses a SINGLE self-consistent root ref: metadata.component.bom-ref == every
affects.ref. DT maps that root ref to the target project via the `project`
field of the upload request, and applies each analysis PROJECT-WIDE by CVE
(suppressing that CVE on every component that carries it). States resolved /
not_affected / false_positive auto-suppress the finding; in_triage annotates
without suppressing.

Because suppression is project-wide by CVE, a CVE that is Unpatched in ANY
of the image's recipes is excluded entirely -- suppressing it would hide a
genuine issue on another component. Only CVEs that are Patched/Ignored and
never Unpatched are emitted.

Scope: the VEX is CVE-centric (every affects.ref is the single root ref), but
it is scoped to the recipes that actually produce the image's packages. Yocto's
image-level cve-summary.json covers the whole build closure (hundreds of
recipes), most of which never ship in the rootfs -- emitting a VEX entry for
every one of their fixed CVEs produces a multi-megabyte, tens-of-thousands-entry
document that DT chews on for minutes for no benefit (there is no finding to
suppress for a component that is not in the SBOM). So we resolve the manifest's
packages to their recipes the same way the SBOM's CPEs do -- pkgdata/runtime-
reverse (authoritative), then exact name, then longest recipe-name prefix -- and
only consider CVEs from those recipes. The Unpatched guard is likewise scoped to
them.

Usage:
  manifest-to-vex.py <manifest> <image-name> <image-version> <cve-summary.json> [pkgdata-runtime-reverse-dir] > vex.json
"""
import json
import os
import sys
import uuid
from datetime import datetime, timezone


# When one CVE has several non-Unpatched statuses across recipes (rare -- a CVE
# usually maps to a single recipe), pick the highest-priority state. in_triage
# wins so an upstream-wontfix flagged anywhere stays visible rather than being
# silently suppressed by a Patched sibling; the suppressing states follow.
_STATE_PRIORITY = {"in_triage": 4, "resolved": 3, "not_affected": 2, "false_positive": 1}


def pn_for_package(pkg_name, pkgdata_dir):
    """Recipe PN that produced a runtime package (pkgdata/runtime-reverse/<pkg>)."""
    if not pkgdata_dir:
        return None
    try:
        with open(os.path.join(pkgdata_dir, pkg_name)) as f:
            for line in f:
                if line.startswith("PN:"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        return None
    return None


def resolve_recipe(pkg_name, issues_by_recipe, recipes_by_len, pkgdata_dir):
    """Map a runtime package to the recipe whose CVE data applies to it."""
    pn = pn_for_package(pkg_name, pkgdata_dir)
    if pn and pn in issues_by_recipe:
        return pn
    if pkg_name in issues_by_recipe:
        return pkg_name
    for recipe in recipes_by_len:
        if pkg_name.startswith(recipe + "-"):
            return recipe
    return None


def cyclonedx_analysis(status, detail):
    """Yocto cve-check status/detail -> (CycloneDX state, justification|None)."""
    if status == "Patched":
        return ("resolved", None)
    # status == "Ignored" -- set in the recipe via CVE_STATUS[CVE-x] = "detail: ..."
    mapping = {
        "cpe-incorrect": ("false_positive", None),
        "disputed": ("false_positive", None),
        "not-applicable-config": ("not_affected", "requires_configuration"),
        "not-applicable-platform": ("not_affected", "requires_environment"),
        "upstream-wontfix": ("in_triage", None),
    }
    return mapping.get((detail or "").lower(), ("not_affected", "requires_configuration"))


def main():
    if not (5 <= len(sys.argv) <= 6):
        print(f"Usage: {sys.argv[0]} <manifest> <image-name> <image-version> "
              f"<cve-summary.json> [pkgdata-runtime-reverse-dir] > vex.json", file=sys.stderr)
        sys.exit(1)
    manifest_path, image_name, image_version = sys.argv[1], sys.argv[2], sys.argv[3]
    cve_summary_path = sys.argv[4]
    pkgdata_dir = sys.argv[5] if len(sys.argv) >= 6 else None

    with open(cve_summary_path) as f:
        data = json.load(f)

    # recipe name -> list of its cve-check issues (cve-summary.json is keyed by PN)
    issues_by_recipe = {}
    for pkg in data.get("package", []):
        name = pkg.get("name")
        if name:
            issues_by_recipe.setdefault(name, []).extend(pkg.get("issue", []))
    recipes_by_len = sorted(issues_by_recipe, key=len, reverse=True)  # longest-prefix wins

    # Scope to the recipes that actually produce the image's packages.
    relevant_recipes = set()
    with open(manifest_path) as f:
        for line in f:
            parts = line.split()
            if len(parts) != 3:
                continue
            recipe = resolve_recipe(parts[0], issues_by_recipe, recipes_by_len, pkgdata_dir)
            if recipe:
                relevant_recipes.add(recipe)

    # cve_id -> {"unpatched": bool, "cands": [(state, justification, note), ...]}
    cves = {}
    for recipe in relevant_recipes:
        for issue in issues_by_recipe[recipe]:
            cid = issue.get("id")
            if not cid:
                continue
            status = issue.get("status")
            rec = cves.setdefault(cid, {"unpatched": False, "cands": []})
            if status == "Unpatched":
                rec["unpatched"] = True
                continue
            if status not in ("Patched", "Ignored"):
                continue
            state, justification = cyclonedx_analysis(status, issue.get("detail"))
            note_bits = [f"Yocto cve-check: {status}"]
            if issue.get("detail"):
                note_bits.append(issue["detail"])
            if issue.get("description"):
                note_bits.append(issue["description"])
            rec["cands"].append((state, justification, " | ".join(note_bits)))

    # DT resolves every affects[].ref against THIS root bom-ref, then maps it to
    # the target project via the upload's `project` field. Value is arbitrary but
    # must be identical in metadata.component.bom-ref and every affects[].ref.
    root_ref = f"urn:yocto-cve-check:{image_name}:{image_version}"

    vulnerabilities = []
    for cid in sorted(cves):
        rec = cves[cid]
        if rec["unpatched"] or not rec["cands"]:
            continue  # Unpatched anywhere -> keep the finding; no candidates -> skip
        state, justification, note = max(
            rec["cands"], key=lambda c: _STATE_PRIORITY.get(c[0], 0))
        analysis = {"state": state, "detail": note}
        if justification:
            analysis["justification"] = justification
        vulnerabilities.append({
            "id": cid,
            "source": {"name": "NVD", "url": f"https://nvd.nist.gov/vuln/detail/{cid}"},
            "analysis": analysis,
            "affects": [{"ref": root_ref}],
        })

    vex = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{uuid.uuid4()}",
        "version": 1,
        "metadata": {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "component": {
                "type": "firmware",
                "bom-ref": root_ref,
                "name": image_name,
                "version": image_version,
            },
        },
        "vulnerabilities": vulnerabilities,
    }
    json.dump(vex, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
