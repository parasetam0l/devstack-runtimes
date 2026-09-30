#!/usr/bin/env python3
"""List Mach-O payloads using file headers, including executables without suffixes."""
import os
import sys

MAGIC = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe",
    "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
)}
for directory, _, files in os.walk(sys.argv[1]):
    for name in files:
        path = os.path.join(directory, name)
        if os.path.islink(path):
            continue
        with open(path, "rb") as source:
            if source.read(4) in MAGIC:
                sys.stdout.buffer.write(os.fsencode(path) + b"\0")
