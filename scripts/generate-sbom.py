#!/usr/bin/env python3
"""Generate a deterministic CycloneDX inventory from the runtime lock and payload."""

import hashlib
import json
import pathlib
import sys


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: generate-sbom.py RUNTIME_ROOT OUTPUT_JSON")
    root = pathlib.Path(sys.argv[1]).resolve()
    output = pathlib.Path(sys.argv[2]).resolve()
    repository = pathlib.Path(__file__).resolve().parents[1]
    lock = json.loads((repository / "locks/runtime-lock.json").read_text(encoding="utf-8"))
    dependency_lock = json.loads((repository / "locks/dependency-lock.json").read_text(encoding="utf-8"))
    components = []
    for runtime in sorted(lock["runtimes"], key=lambda item: item["id"]):
        payload = root / runtime["id"]
        files = []
        if payload.is_dir():
            for path in sorted(item for item in payload.rglob("*") if item.is_file()):
                files.append({
                    "path": str(path.relative_to(payload)),
                    "sha256": sha256(path),
                })
        components.append({
            "type": "application" if runtime["kind"] not in ("library", "php-extension") else "library",
            "bom-ref": runtime["id"],
            "name": runtime["id"],
            "version": runtime["version"],
            "licenses": [{"expression": runtime["license"]}],
            "externalReferences": [{"type": "distribution", "url": runtime["source"]["url"]}],
            "properties": [
                {"name": "devstack:source-sha256", "value": runtime["source"]["sha256"]},
                {"name": "devstack:support-state", "value": runtime["supportState"]},
                {"name": "devstack:payload-files", "value": json.dumps(files, separators=(",", ":"))},
            ],
        })
    for dependency in sorted(dependency_lock["sources"], key=lambda item: item["id"]):
        components.append({
            "type": "library",
            "bom-ref": f"dependency:{dependency['id']}@{dependency['version']}",
            "name": dependency["id"],
            "version": dependency["version"],
            "licenses": [{"expression": dependency["license"]}],
            "externalReferences": [{"type": "distribution", "url": dependency["url"]}],
            "properties": [
                {"name": "devstack:source-sha256", "value": dependency["sha256"]},
                {"name": "devstack:build-targets", "value": ",".join(dependency["targets"])},
            ],
        })
    document = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": "urn:uuid:00000000-0000-0000-0000-000000000001",
        "version": 1,
        "metadata": {"component": {"type": "application", "name": "DevStack"}},
        "components": components,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(output)


if __name__ == "__main__":
    main()
