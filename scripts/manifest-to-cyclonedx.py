#!/usr/bin/env python3
"""Builds a minimal, valid CycloneDX 1.6 SBOM directly from a Yocto image
.manifest file (one 'name arch version' line per installed package).

Why this exists instead of converting Yocto's own SPDX output: create-spdx-2.2
produces a *graph* of ~166+ linked documents (one per recipe/package, joined
via externalDocumentRefs) rather than one flat file. Converting just the
top-level document (the obvious thing to try) only captures the image itself
as a single "package" -- none of its actual constituent packages -- because
those all live in the other, unreferenced files. Properly resolving that
whole document graph is a much bigger undertaking than this project needs
just to get a per-package vulnerability-scannable list into Dependency-Track.
The .manifest file already has exactly that list, directly, reliably.

Real limitation, stated plainly: components get `pkg:generic/name@version`
PURLs, not ecosystem-specific ones (there's no standard PURL type for
Yocto/OE packages). Dependency-Track's ecosystem-aware version matching
(Alpine/Debian/Go/Maven/NPM/PyPI/RPM) won't apply -- matching falls back to
plain name+version comparison. Good enough to know what's on the image and
get NVD/OSV keyword-based hits; not as precise as a real distro's packages.

Usage: manifest-to-cyclonedx.py <manifest-file> <image-name> <image-version> > bom.json
"""
import json
import sys
import uuid
from datetime import datetime, timezone


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <manifest-file> <image-name> <image-version>", file=sys.stderr)
        sys.exit(1)

    manifest_path, image_name, image_version = sys.argv[1], sys.argv[2], sys.argv[3]

    components = []
    with open(manifest_path) as f:
        for line in f:
            parts = line.split()
            if len(parts) != 3:
                continue
            name, arch, version = parts
            components.append({
                "type": "library",
                "name": name,
                "version": version,
                "purl": f"pkg:generic/{name}@{version}",
                "properties": [{"name": "yocto:arch", "value": arch}],
            })

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
