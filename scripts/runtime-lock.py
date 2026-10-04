#!/usr/bin/env python3
"""Small build-host-only reader for the signed DevStack runtime lock."""

import json
import pathlib
import sys

LOCK = pathlib.Path(__file__).resolve().parents[1] / "locks/runtime-lock.json"


def main() -> None:
    data = json.loads(LOCK.read_text(encoding="utf-8"))
    if len(sys.argv) < 2:
        raise SystemExit("usage: runtime-lock.py list | packs | patches | minimum-macos | get ID FIELD | "
                         "patch ID INDEX FIELD | manifest ID | pack-name ID | requires ID")
    command = sys.argv[1]
    if command == "list":
        print("\n".join(item["id"] for item in data["runtimes"]))
        return
    packs = [item for item in data["runtimes"] if item["kind"] != "php-extension"]
    pack_ids = {item["id"] for item in packs}
    if command == "packs":
        # PHP extensions ship inside the PHP runtimes they were built for.
        print("\n".join(item["id"] for item in packs))
        return
    if command in ("manifest", "pack-name", "requires") and len(sys.argv) == 3:
        item = next((item for item in packs if item["id"] == sys.argv[2]), None)
        if item is None:
            raise SystemExit(f"unknown runtime pack: {sys.argv[2]}")
        if command == "manifest":
            print(json.dumps(item, indent=2))
        elif command == "pack-name":
            # The release tag and the file name of the pack. Some IDs already
            # carry the full version (phpmyadmin-5.2.3); it is not repeated.
            base = item["id"] if item["id"].endswith("-" + item["version"]) else f"{item['id']}-{item['version']}"
            print(f"{base}-r{item['packRevision']}")
        else:
            # Other packs that must be installed for this one to work.
            print("\n".join(sorted(set((item.get("build") or {}).get("dependencies", [])) & pack_ids)))
        return
    if command == "minimum-macos":
        # The oldest macOS any runtime supports: shared dependency libraries
        # are built for it.
        versions = [item["minimumMacOS"] for item in data["runtimes"]]
        print(min(versions, key=lambda value: tuple(int(part) for part in value.split("."))))
        return
    if command == "patches":
        for item in data["runtimes"]:
            for index, _ in enumerate((item.get("build") or {}).get("patchSources", [])):
                print(f"{item['id']}\t{index}")
        return
    if command == "get" and len(sys.argv) == 4:
        item = next((item for item in data["runtimes"] if item["id"] == sys.argv[2]), None)
        if item is None:
            raise SystemExit(f"unknown runtime: {sys.argv[2]}")
        value = item
        for segment in sys.argv[3].split("."):
            value = value[segment]
        if isinstance(value, (dict, list)):
            print(json.dumps(value, separators=(",", ":")))
        else:
            print(value)
        return
    if command == "patch" and len(sys.argv) == 5:
        item = next((item for item in data["runtimes"] if item["id"] == sys.argv[2]), None)
        if item is None:
            raise SystemExit(f"unknown runtime: {sys.argv[2]}")
        value = item["build"]["patchSources"][int(sys.argv[3])][sys.argv[4]]
        print(value)
        return
    raise SystemExit("invalid runtime-lock.py arguments")


if __name__ == "__main__":
    main()
