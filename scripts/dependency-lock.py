#!/usr/bin/env python3
import json
import pathlib
import sys

lock = json.loads((pathlib.Path(__file__).resolve().parents[1] / "Dependencies/dependency-lock.json").read_text(encoding="utf-8"))
if len(sys.argv) != 2:
    raise SystemExit("usage: dependency-lock.py apache|php")
target = sys.argv[1]
for item in lock["sources"]:
    if target in item["targets"]:
        print("\t".join((item["id"], item["version"], item["url"], item["sha256"])))
