#!/usr/bin/env python3
"""Small build-host-only reader for the signed DevStack runtime lock."""

import json
import pathlib
import sys

LOCK = pathlib.Path(__file__).resolve().parents[1] / "Sources/DevStackApp/Resources/runtime-lock.json"


def main() -> None:
    data = json.loads(LOCK.read_text(encoding="utf-8"))
    if len(sys.argv) < 2:
        raise SystemExit("usage: runtime-lock.py list | get ID FIELD | patch ID INDEX FIELD")
    command = sys.argv[1]
    if command == "list":
        print("\n".join(item["id"] for item in data["runtimes"]))
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
