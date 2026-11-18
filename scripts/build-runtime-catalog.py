#!/usr/bin/python3
"""Writes the runtime catalog DevStack checks for newer runtime packs.

  build-runtime-catalog.py [--repository OWNER/NAME] [--output FILE]
  build-runtime-catalog.py --pack-dir DIR [--output FILE]

The catalog lists, for each runtime ID, the newest published pack (highest
version, then packRevision). Each entry is exactly what DevStack's
scripts/pin-runtime.sh writes for that pack. By default it reads the
repository's published releases with `gh`: drafts, prereleases and releases
that are not packs (such as runtime-catalog itself) are left out, and a pack
counts only when its release has the pack file with the size and SHA-256
that pack.json states. --pack-dir reads pack.json files from a directory
instead, for testing.

The output is the catalog payload; DevStackRuntimePackager sign-catalog signs
its bytes as they are. sequence is the current Unix time, so it grows with
each publish. Contract: docs/RELEASING.md.
"""

import argparse
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys
import time

PACK_NAME = re.compile(r"[a-z0-9][a-z0-9.+-]*-r[0-9]+")
PIN_KEYS = ("id", "version", "packRevision", "name", "sha256", "size", "requires", "minimumMacOS", "contents")
# Optional: the oldest DevStack that can use the pack. Absent means any.
OPTIONAL_KEYS = ("minimumAppVersion",)


def fail(message):
    raise SystemExit(f"build-runtime-catalog: {message}")


def gh(*arguments):
    result = subprocess.run(["gh", *arguments], capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"gh {' '.join(arguments)} failed: {result.stderr.strip()}")
    return result.stdout


def pin(pack, name, repository):
    """The entry pin-runtime.sh writes for pack.json, after its own checks."""
    if pack.get("schemaVersion") != 1 or pack.get("name") != name:
        fail(f"pack.json does not describe {name}")
    if not re.fullmatch(r"[0-9a-f]{64}", str(pack.get("sha256"))) or pack.get("file") != name + ".devstack-runtime":
        fail(f"{name}: pack.json is malformed")
    missing = [key for key in PIN_KEYS if key not in pack]
    if missing:
        fail(f"{name}: pack.json lacks {', '.join(missing)}")
    entry = {key: pack[key] for key in PIN_KEYS}
    entry.update({key: pack[key] for key in OPTIONAL_KEYS if key in pack})
    entry["url"] = f"https://github.com/{repository}/releases/download/{name}/{pack['file']}"
    return entry


def version_key(entry):
    """Orders 8.5.12 after 8.5.9 and 7.1.2-34 after 7.1.2-9."""
    return tuple(int(part) for part in re.findall(r"[0-9]+", entry["version"])), entry["packRevision"]


def published_packs(repository):
    releases = []
    for page in json.loads(gh("api", "--paginate", "--slurp", f"repos/{repository}/releases?per_page=100")):
        releases.extend(page)
    for release in releases:
        name = release["tag_name"]
        if release["draft"] or release["prerelease"] or not release.get("published_at") or not PACK_NAME.fullmatch(name):
            continue
        assets = {asset["name"]: asset for asset in release["assets"]}
        if "pack.json" not in assets:
            print(f"Skipping {name}: its release has no pack.json.", file=sys.stderr)
            continue
        pack = json.loads(gh("release", "download", name, "--repo", repository, "--pattern", "pack.json", "--output", "-"))
        entry = pin(pack, name, repository)
        asset = assets.get(pack["file"])
        if asset is None or asset["size"] != entry["size"]:
            fail(f"{name}: the release's {pack['file']} is missing or has another size than pack.json states")
        digest = asset.get("digest")
        if digest and digest != "sha256:" + entry["sha256"]:
            fail(f"{name}: the release's {pack['file']} does not match the SHA-256 in pack.json")
        yield entry


def directory_packs(directory, repository):
    for path in sorted(pathlib.Path(directory).glob("*.json")):
        pack = json.loads(path.read_text(encoding="utf-8"))
        yield pin(pack, pack.get("name", path.stem), repository)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", "parasetam0l/devstack-runtimes"))
    parser.add_argument("--pack-dir", help="read pack.json files from this directory instead of the releases")
    parser.add_argument("--output", help="write the catalog here instead of standard output")
    arguments = parser.parse_args()

    packs = directory_packs(arguments.pack_dir, arguments.repository) if arguments.pack_dir \
        else published_packs(arguments.repository)
    newest = {}
    for entry in packs:
        current = newest.get(entry["id"])
        if current is None or version_key(entry) > version_key(current):
            newest[entry["id"]] = entry
    if not newest:
        fail("found no published packs")

    now = int(time.time())
    catalog = {
        "schemaVersion": 1,
        "sequence": now,
        "issued": datetime.datetime.fromtimestamp(now, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "packs": [newest[runtime] for runtime in sorted(newest)],
    }
    text = json.dumps(catalog, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        pathlib.Path(arguments.output).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    print(f"Catalog {now}: " + ", ".join(entry["name"] for entry in catalog["packs"]), file=sys.stderr)


if __name__ == "__main__":
    main()
