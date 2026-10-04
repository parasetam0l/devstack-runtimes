#!/usr/bin/python3
"""Builds one runtime pack from a built, relocated and signed runtime.

  pack-runtime.py RUNTIME_ID OUTPUT_DIRECTORY

Environment:
  DEVSTACK_PACKAGER        DevStackRuntimePackager, built from the DevStack app
                           repository, which defines the pack format
  DEVSTACK_PACK_KEY_ID     ID of the signing key the app trusts
  DEVSTACK_PACK_KEY_FILE   the raw 32-byte Ed25519 private key
  DEVSTACK_RUNTIME_OUTPUT  built runtimes (default .build/Runtimes)
  DEVSTACK_SOURCE_CACHE    verified source archives (default .build/runtime-cache)

Writes OUTPUT_DIRECTORY/<pack name>/:
  <pack name>.devstack-runtime  the signed pack: payload, SBOM, licence notices
  <pack name>.sbom.cdx.json     the same SBOM, readable without unpacking
  pack.json                     what DevStack pins: file, SHA-256, size, requirements
  sources/                      the exact source archives and patches it was built from

Sign the runtime's Mach-O files before packing: the SBOM and the pack hash the
files as they ship.
"""

import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
RUNTIME_LOCK = json.loads((REPOSITORY / "locks/runtime-lock.json").read_text(encoding="utf-8"))["runtimes"]

# The shared libraries a pack can carry, by the component that provides them.
# A component is part of a pack exactly when its libraries are in the
# payload, so the SBOM, the notices and the sources follow what ships.
LIBRARY_PREFIXES = {
    "openssl-3.5": ("libssl.", "libcrypto."),
    "imagemagick-7.1": ("libMagickCore-", "libMagickWand-", "libMagick++-"),
    "postgresql-18": ("libpq.",),
    "apr": ("libapr-1.",),
    "apr-util": ("libaprutil-1.",),
    "pcre2": ("libpcre2-",),
    "nghttp2": ("libnghttp2.",),
    "zlib": ("libz.",),
    "libpng": ("libpng",),
    "icu": ("libicu",),
    "oniguruma": ("libonig.",),
    "libzip": ("libzip.",),
    "libsodium": ("libsodium.",),
    "gmp": ("libgmp.", "libgmpxx."),
    "tidy": ("libtidy.",),
    "gettext": ("libintl.", "libasprintf."),
    "libjpeg-turbo": ("libjpeg.",),
    "freetype": ("libfreetype.",),
    "libwebp": ("libwebp", "libsharpyuv."),
}
# Compiled in rather than carried as a library.
BUILT_IN = {"mysql-8.4": {"boost"}}


def load_collector():
    spec = importlib.util.spec_from_file_location("collect_licenses", REPOSITORY / "scripts/collect-licenses.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def pack_name(item):
    base = item["id"] if item["id"].endswith("-" + item["version"]) else f"{item['id']}-{item['version']}"
    return f"{base}-r{item['packRevision']}"


def contents(item, collector, payload):
    """The runtime, its PHP extensions, and every runtime and shared library
    whose files it carries."""
    shipped = {path.name for path in payload.rglob("*.dylib")}
    unknown = set(LIBRARY_PREFIXES) - {entry["id"] for entry in RUNTIME_LOCK} - {component.identifier for component in collector.dependency_components()}
    if unknown:
        raise SystemExit(f"LIBRARY_PREFIXES names components the locks don't have: {', '.join(sorted(unknown))}")

    def carried(identifier):
        return identifier in BUILT_IN.get(item["id"], set()) or any(
            name.startswith(prefix) for name in shipped for prefix in LIBRARY_PREFIXES.get(identifier, ()))

    runtimes = [item]
    # Extensions ship inside the PHP they were built for (imagick-php depends
    # on ImageMagick but is not part of its pack).
    runtimes += [entry for entry in RUNTIME_LOCK if item["kind"] == "php" and entry["kind"] == "php-extension"
                 and item["id"] in (entry.get("build") or {}).get("dependencies", [])]
    runtimes += [entry for entry in RUNTIME_LOCK if entry is not item and entry["kind"] != "php-extension" and carried(entry["id"])]
    dependencies = [component for component in collector.dependency_components() if carried(component.identifier)]
    return runtimes, dependencies


def sbom(item, payload, runtimes, dependencies):
    components = []
    for entry in runtimes:
        component = {
            "type": "application" if entry is item and entry["kind"] not in ("library", "php-extension") else "library",
            "bom-ref": entry["id"],
            "name": entry["id"],
            "version": entry["version"],
            "licenses": [{"expression": entry["license"]}],
            "externalReferences": [{"type": "distribution", "url": entry["source"]["url"]}],
            "properties": [{"name": "devstack:source-sha256", "value": entry["source"]["sha256"]}],
        }
        if entry is item:
            files = [{"path": str(path.relative_to(payload)), "sha256": sha256(path)}
                     for path in sorted(p for p in payload.rglob("*") if p.is_file() and not p.is_symlink())]
            component["properties"].append({"name": "devstack:payload-files", "value": json.dumps(files, separators=(",", ":"))})
        components.append(component)
    for dependency in dependencies:
        components.append({
            "type": "library",
            "bom-ref": f"dependency:{dependency.identifier}@{dependency.version}",
            "name": dependency.identifier,
            "version": dependency.version,
            "licenses": [{"expression": dependency.license}],
            "externalReferences": [{"type": "distribution", "url": dependency.url}],
            "properties": [{"name": "devstack:source-sha256", "value": dependency.sha256}],
        })
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "version": 1,
        "metadata": {"component": {"type": "application", "name": item["id"], "version": item["version"]}},
        "components": components,
    }


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__.strip())
    identifier, output = sys.argv[1], pathlib.Path(sys.argv[2]).resolve()
    item = next((entry for entry in RUNTIME_LOCK if entry["id"] == identifier and entry["kind"] != "php-extension"), None)
    if item is None:
        raise SystemExit(f"unknown runtime pack: {identifier}")
    environment = os.environ
    packager = environment.get("DEVSTACK_PACKAGER")
    key_id = environment.get("DEVSTACK_PACK_KEY_ID")
    key_file = environment.get("DEVSTACK_PACK_KEY_FILE")
    if not (packager and key_id and key_file):
        raise SystemExit("Set DEVSTACK_PACKAGER, DEVSTACK_PACK_KEY_ID and DEVSTACK_PACK_KEY_FILE.")
    payload = pathlib.Path(environment.get("DEVSTACK_RUNTIME_OUTPUT", REPOSITORY / ".build/Runtimes")) / identifier
    if not payload.is_dir():
        raise SystemExit(f"Runtime is not built: {payload}")

    collector = load_collector()
    runtimes, dependencies = contents(item, collector, payload)
    by_id = {component.identifier: component for component in collector.runtime_components()}
    source_components = [component for component in collector.runtime_components(None)
                         if any(component.identifier == entry["id"] or component.identifier.startswith(entry["id"] + "-patch")
                                for entry in runtimes)] + dependencies
    missing = [component.archive for component in source_components if not collector.verified(component)]
    if missing:
        raise SystemExit("Missing or unverified sources (run scripts/verify-sources.sh):\n" + "\n".join(map(str, missing)))

    name = pack_name(item)
    destination = output / name
    if destination.exists():
        shutil.rmtree(destination)
    (destination / "sources").mkdir(parents=True)
    with tempfile.TemporaryDirectory() as work_root:
        work = pathlib.Path(work_root)
        notices = work / "licenses"
        for component in source_components:
            if not collector.is_patch(component):
                collector.write_notices(component, notices / component.identifier)
            shutil.copy2(component.archive, destination / "sources" / component.archive.name)
        document = sbom(item, payload, runtimes, dependencies)
        sbom_file = destination / f"{name}.sbom.cdx.json"
        sbom_file.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        manifest_file = work / "runtime-manifest.json"
        manifest_file.write_text(json.dumps(item, indent=2) + "\n", encoding="utf-8")
        pack_file = destination / f"{name}.devstack-runtime"
        subprocess.run([packager, str(payload), str(manifest_file), str(sbom_file), str(notices),
                        key_id, key_file, str(pack_file)], check=True, stdout=subprocess.DEVNULL)

    requires = sorted(set((item.get("build") or {}).get("dependencies", []))
                      & {entry["id"] for entry in RUNTIME_LOCK if entry["kind"] != "php-extension"})
    pack = {
        "schemaVersion": 1,
        "id": item["id"],
        "version": item["version"],
        "packRevision": item["packRevision"],
        "name": name,
        "file": pack_file.name,
        "sha256": sha256(pack_file),
        "size": pack_file.stat().st_size,
        "requires": requires,
        "minimumMacOS": item["minimumMacOS"],
        "signingKeyID": key_id,
        "contents": [entry["id"] for entry in runtimes[1:]],
    }
    (destination / "pack.json").write_text(json.dumps(pack, indent=2) + "\n", encoding="utf-8")
    print(f"{name}: {pack['size'] / 1048576:.1f} MB, {len(source_components)} source archive(s) -> {destination}")


if __name__ == "__main__":
    main()
