#!/usr/bin/env python3
"""Builds a minimal, valid CycloneDX 1.6 SBOM directly from a Yocto image
.manifest file (one 'name arch version' line per installed package), and --
when a cve-check summary is supplied -- attaches a CPE to each component so
Dependency-Track can actually match NVD/OSV CVEs against it.

Why generate from the .manifest instead of Yocto's own SPDX output:
create-spdx-2.2 produces a *graph* of 300+ linked documents (one per
recipe/package, joined via externalDocumentRefs) rather than one flat file.
Converting just the top-level document (the obvious thing to try) only
captures the image itself as a single "package" -- none of its constituent
packages -- because those live in the other, unreferenced files. The
.manifest already has exactly the installed package list, directly and
reliably.

CPEs -- the part that makes Dependency-Track useful here: a Yocto image's
packages have no ecosystem-specific PURL type, so their `pkg:generic/...`
PURLs are useless for DT's version matching. Without a CPE, DT has nothing
precise to match on and reports zero findings even when CVEs exist. But Yocto
*does* know the right CPE product for each recipe -- it's what `cve-check`
matches on, via each recipe's CVE_PRODUCT. We reuse it: pass the cve-check
summary JSON (build/tmp/log/cve/cve-summary.json) as the optional 4th
argument and each component gets `cpe:2.3:a:*:<product>:<version>:*...`. The
vendor is left as ANY (`*`) on purpose -- exactly as Yocto's own SPDX emits
it -- so matching keys on product+version and doesn't miss packages whose NVD
vendor differs from the product name (e.g. glibc -> vendor `gnu`, bash ->
`gnu`).

Mapping a runtime package to its recipe's CPE product: pass Yocto's
pkgdata/runtime-reverse dir (build/tmp/pkgdata/<machine>/runtime-reverse) as
the optional 5th argument for the authoritative map -- it's the only way to
resolve Debian-style library package names to their OE recipe (libssl3 ->
openssl, libc6 -> glibc, libcurl4 -> curl), which are exactly the packages you
most want CVE coverage on. Without it, the script falls back to exact name and
longest recipe-name-prefix matching (busybox-syslog -> busybox), which covers
the base packages but misses the lib* ones.

Without the optional arguments the script still works (generic PURLs only, no
CPEs) -- backward compatible.

Usage:
  manifest-to-cyclonedx.py <manifest> <name> <version> [cve-summary.json] [pkgdata-runtime-reverse-dir] > bom.json
"""
import json
import os
import sys
import uuid
from datetime import datetime, timezone


def load_cpe_map(cve_summary_path):
    """recipe-name -> (vendor, product, clean-version) from a cve-check summary.

    cve-summary.json is image-scoped: {"package": [{"name", "version",
    "products": [{"product": ...}], ...}]}. `product` is the recipe's
    CVE_PRODUCT (occasionally in "vendor:product" form); `version` is the clean
    upstream PV (no `-rN` package-revision suffix), which is what NVD matches.
    """
    with open(cve_summary_path) as f:
        data = json.load(f)
    cpe_map = {}
    for pkg in data.get("package", []):
        name, version = pkg.get("name"), pkg.get("version")
        products = pkg.get("products") or []
        if not (name and version and products):
            continue
        product = products[0].get("product")
        if not product:
            continue
        if ":" in product:          # "vendor:product" -> keep both, stays well-formed
            vendor, product = product.split(":", 1)
        else:
            vendor = "*"            # unknown vendor -> ANY (matches any NVD vendor)
        cpe_map[name] = (vendor, product, version)
    return cpe_map


def pn_for_package(pkg_name, pkgdata_dir):
    """Recipe PN that produced a runtime package, read from Yocto's
    pkgdata/runtime-reverse/<pkg> -- the authoritative binary-package -> recipe
    map (e.g. libssl3 -> openssl, libc6 -> glibc), which no name heuristic could
    infer."""
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


def resolve_cpe(pkg_name, cpe_map, recipes_by_len, pkgdata_dir):
    """CPE tuple for a runtime package, best source first:
    1. pkgdata pkg -> recipe PN, then PN -> CVE_PRODUCT (authoritative);
    2. exact package name == recipe name (busybox, base-files);
    3. longest recipe-name prefix (busybox-syslog -> busybox)."""
    pn = pn_for_package(pkg_name, pkgdata_dir)
    if pn and pn in cpe_map:
        return cpe_map[pn]
    if pkg_name in cpe_map:
        return cpe_map[pkg_name]
    for recipe in recipes_by_len:
        if pkg_name.startswith(recipe + "-"):
            return cpe_map[recipe]
    return None


def main():
    if not (4 <= len(sys.argv) <= 6):
        print(f"Usage: {sys.argv[0]} <manifest> <image-name> <image-version> "
              f"[cve-summary.json] [pkgdata-runtime-reverse-dir]", file=sys.stderr)
        sys.exit(1)

    manifest_path, image_name, image_version = sys.argv[1], sys.argv[2], sys.argv[3]
    cve_summary = sys.argv[4] if len(sys.argv) >= 5 else None
    pkgdata_dir = sys.argv[5] if len(sys.argv) >= 6 else None

    cpe_map, recipes_by_len = {}, []
    if cve_summary:
        cpe_map = load_cpe_map(cve_summary)
        recipes_by_len = sorted(cpe_map, key=len, reverse=True)  # longest-prefix wins

    components = []
    with open(manifest_path) as f:
        for line in f:
            parts = line.split()
            if len(parts) != 3:
                continue
            name, arch, version = parts
            component = {
                "type": "library",
                "name": name,
                "version": version,
                "purl": f"pkg:generic/{name}@{version}",
                "properties": [{"name": "yocto:arch", "value": arch}],
            }
            cpe = resolve_cpe(name, cpe_map, recipes_by_len, pkgdata_dir) if cpe_map else None
            if cpe:
                vendor, product, cve_version = cpe
                component["cpe"] = f"cpe:2.3:a:{vendor}:{product}:{cve_version}:*:*:*:*:*:*:*"
            components.append(component)

    bom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{uuid.uuid4()}",
        "version": 1,
        "metadata": {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "component": {
                "type": "firmware",
                "name": image_name,
                "version": image_version,
            },
        },
        "components": components,
    }

    json.dump(bom, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
