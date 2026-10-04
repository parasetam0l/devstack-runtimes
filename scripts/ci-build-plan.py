#!/usr/bin/python3
"""Prints what CI needs to build one runtime pack, as GitHub Actions outputs.

  ci-build-plan.py RUNTIME_ID

  name=php-8.5-8.5.11-r1           the pack and release name
  dependencies=php                 shared library trees for build-dependencies.sh
  inputs=openssl-3.5 imagemagick-7.1 postgresql-18
                                   published packs installed before building
  build=php-8.5 xdebug-php85 redis-php imagick-php
                                   runtime IDs for build-runtimes.sh, in order
  postgresql_drivers=php-8.5       PHP runtimes that get pgsql and pdo_pgsql
"""

import json
import pathlib
import sys

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
RUNTIMES = json.loads((REPOSITORY / "locks/runtime-lock.json").read_text(encoding="utf-8"))["runtimes"]

# Shared library trees each recipe builds against (build-dependencies.sh targets).
DEPENDENCY_TREES = {
    "apache-2.4": ["apache"],
    "nginx-1.30": ["apache"],
    "imagemagick-7.1": ["php"],
    "postgresql-18": ["php"],
    "php-7.4": ["php"],
    "php-8.4": ["php"],
    "php-8.5": ["php"],
    "mysql-8.4": ["mysql"],
}
# Inputs beyond the packs a runtime requires at run time: PHP 8.4 and 8.5
# link libpq for their PostgreSQL drivers, and Adminer is syntax-checked
# with PHP 8.5 while it is built.
BUILD_ONLY_INPUTS = {
    "php-8.4": ["postgresql-18"],
    "php-8.5": ["postgresql-18"],
    "adminer-6.1.1": ["php-8.5"],
}
POSTGRESQL_DRIVERS = {"php-8.4", "php-8.5"}


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__.strip())
    packs = {item["id"]: item for item in RUNTIMES if item["kind"] != "php-extension"}
    item = packs.get(sys.argv[1])
    if item is None:
        raise SystemExit(f"unknown runtime pack: {sys.argv[1]}")
    base = item["id"] if item["id"].endswith("-" + item["version"]) else f"{item['id']}-{item['version']}"
    required = sorted(set((item.get("build") or {}).get("dependencies", [])) & set(packs))
    # Compiled runtimes link the packs they require; the others (copied
    # tools and PHP applications) need them only at run time.
    compiled = item["kind"] not in ("phpmyadmin", "adminer", "composer", "mailpit")
    inputs = sorted(set(required if compiled else []) | set(BUILD_ONLY_INPUTS.get(item["id"], [])))
    # Extensions ship inside the PHP they were built for, never elsewhere
    # (imagick-php depends on ImageMagick but belongs to the PHP packs).
    extensions = [entry["id"] for entry in RUNTIMES if item["kind"] == "php" and entry["kind"] == "php-extension"
                  and item["id"] in (entry.get("build") or {}).get("dependencies", [])]
    lines = {
        "name": f"{base}-r{item['packRevision']}",
        "dependencies": " ".join(DEPENDENCY_TREES.get(item["id"], [])),
        "inputs": " ".join(inputs),
        "build": " ".join([item["id"]] + extensions),
        "postgresql_drivers": item["id"] if item["id"] in POSTGRESQL_DRIVERS else "",
    }
    for key, value in lines.items():
        print(f"{key}={value}")


if __name__ == "__main__":
    main()
