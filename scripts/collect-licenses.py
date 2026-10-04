#!/usr/bin/python3
"""Third-party notices and corresponding sources from the verified source cache.

Every input comes from the archives that scripts/verify-sources.sh downloaded
and checked against the locks, never from build trees, so the notices match
what was built no matter which work directories still exist.

  collect-licenses.py notices OUTPUT_DIRECTORY
      Rebuild the notices tree for every runtime and dependency in the locks.
  collect-licenses.py sources DESTINATION RUNTIME_ID...
      Copy the source archives and patches of the packaged runtimes, their PHP
      extensions, and every dependency.
  collect-licenses.py check NOTICES_DIRECTORY RUNTIME_ID...
      Fail unless every shipped component has notices and a verified archive.

DEVSTACK_SOURCE_CACHE overrides the cache (default .build/runtime-cache).
"""

import hashlib
import json
import os
import pathlib
import re
import shutil
import sys
import tarfile
import tempfile

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
RUNTIME_LOCK = REPOSITORY / "locks/runtime-lock.json"
DEPENDENCY_LOCK = REPOSITORY / "locks/dependency-lock.json"
CACHE = pathlib.Path(os.environ.get("DEVSTACK_SOURCE_CACHE", REPOSITORY / ".build/runtime-cache"))
NOTICE_NAME = re.compile(r"^(licen[cs]e|copying|notice|copyright)([._-].*)?$", re.IGNORECASE)
# Scripts such as copyright.pl match the name pattern but are not notices.
CODE_SUFFIXES = {".c", ".cc", ".cpp", ".h", ".hpp", ".go", ".java", ".js", ".m4", ".php", ".pl", ".pm", ".py", ".rb", ".sh", ".in", ".am", ".ac", ".cmake"}


class Component:
    def __init__(self, identifier, version, license_name, url, sha256, archive):
        self.identifier = identifier
        self.version = version
        self.license = license_name
        self.url = url
        self.sha256 = sha256
        self.archive = archive


def url_filename(url):
    return url.split("?", 1)[0].rsplit("/", 1)[-1]


# Cache names follow scripts/fetch-runtime.sh and scripts/verify-sources.sh.
def runtime_components(runtime_ids=None):
    runtimes = json.loads(RUNTIME_LOCK.read_text(encoding="utf-8"))["runtimes"]
    selected = runtimes if runtime_ids is None else [item for item in runtimes if item["id"] in shipped_runtime_ids(runtimes, runtime_ids)]
    components = []
    for item in selected:
        source = item["source"]
        components.append(Component(item["id"], item["version"], item["license"], source["url"], source["sha256"],
                                    CACHE / f"{item['id']}-{url_filename(source['url'])}"))
        for index, patch in enumerate((item.get("build") or {}).get("patchSources", [])):
            components.append(Component(f"{item['id']}-patch{index}", item["version"], item["license"], patch["url"], patch["sha256"],
                                        CACHE / f"{item['id']}-patch{index}-{url_filename(patch['url'])}"))
    return components


def shipped_runtime_ids(runtimes, packaged):
    """Packaged runtimes plus the PHP extensions built into them."""
    packaged = set(packaged)
    shipped = set(packaged)
    for item in runtimes:
        owners = [owner for owner in (item.get("build") or {}).get("dependencies", []) if owner.startswith("php-")]
        if item["kind"] == "php-extension" and packaged.intersection(owners):
            shipped.add(item["id"])
    unknown = packaged - {item["id"] for item in runtimes}
    if unknown:
        raise SystemExit(f"unknown runtime: {', '.join(sorted(unknown))}")
    return shipped


def dependency_components():
    sources = json.loads(DEPENDENCY_LOCK.read_text(encoding="utf-8"))["sources"]
    return [Component(item["id"], item["version"], item["license"], item["url"], item["sha256"],
                      CACHE / "dependencies" / f"{item['id']}-{url_filename(item['url'])}") for item in sources]


def verified(component):
    if not component.archive.is_file():
        return False
    digest = hashlib.sha256()
    with component.archive.open("rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest() == component.sha256


def is_patch(component):
    return re.search(r"-patch\d+$", component.identifier) is not None


def write_notices(component, destination):
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "SOURCE.txt").write_text(
        f"{component.identifier} {component.version}\n"
        f"License: {component.license}\n"
        f"Source: {component.url}\n"
        f"SHA-256: {component.sha256}\n", encoding="utf-8")
    if not tarfile.is_tarfile(component.archive):
        # Single-file distributions (Adminer, Composer) carry their licence in
        # the file itself, which ships under CorrespondingSources.
        return 0
    copied = 0
    with tarfile.open(component.archive) as archive:
        for member in archive:
            parts = pathlib.PurePosixPath(member.name).parts
            if not member.isfile() or ".." in parts:
                continue
            if not (NOTICE_NAME.match(parts[-1]) or "LICENSES" in parts[:-1]):
                continue
            if pathlib.PurePosixPath(parts[-1]).suffix.lower() in CODE_SUFFIXES:
                continue
            extracted = archive.extractfile(member)
            if extracted is None:
                continue
            # Drop the archive's top-level directory and flatten the rest.
            name = "_".join(parts[1:] if len(parts) > 1 else parts)
            (destination / name).write_bytes(extracted.read())
            copied += 1
    return copied


def command_notices(output):
    output = pathlib.Path(output)
    missing = []
    components = [component for component in runtime_components() + dependency_components() if not is_patch(component)]
    with tempfile.TemporaryDirectory(dir=output.parent if output.parent.exists() else None) as staging_root:
        staging = pathlib.Path(staging_root) / "notices"
        for component in components:
            if not verified(component):
                missing.append(component)
                continue
            if write_notices(component, staging / component.identifier) == 0 and tarfile.is_tarfile(component.archive):
                print(f"warning: no licence files found in {component.archive.name}", file=sys.stderr)
        if missing:
            for component in missing:
                print(f"missing or unverified source: {component.archive}", file=sys.stderr)
            raise SystemExit("Run scripts/verify-sources.sh first; the notices were left unchanged.")
        if output.exists():
            shutil.rmtree(output)
        shutil.move(str(staging), output)
    print(f"Third-party notices: {output}")


def command_sources(destination, runtime_ids):
    destination = pathlib.Path(destination)
    (destination / "dependencies").mkdir(parents=True, exist_ok=True)
    for component in runtime_components(runtime_ids) + dependency_components():
        if not verified(component):
            print(f"warning: source not copied, missing or unverified: {component.archive}", file=sys.stderr)
            continue
        relative = component.archive.relative_to(CACHE)
        shutil.copy2(component.archive, destination / relative)


def command_check(notices, runtime_ids):
    notices = pathlib.Path(notices)
    problems = []
    for component in runtime_components(runtime_ids) + dependency_components():
        if not verified(component):
            problems.append(f"missing or unverified source: {component.archive}")
        if not is_patch(component) and not (notices / component.identifier / "SOURCE.txt").is_file():
            problems.append(f"missing notices: {component.identifier}")
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        raise SystemExit(f"{len(problems)} licence compliance problem(s)")
    print("Licence notices and corresponding sources are complete.")


def main():
    arguments = sys.argv[1:]
    if len(arguments) == 2 and arguments[0] == "notices":
        command_notices(arguments[1])
    elif len(arguments) >= 3 and arguments[0] == "sources":
        command_sources(arguments[1], arguments[2:])
    elif len(arguments) >= 3 and arguments[0] == "check":
        command_check(arguments[1], arguments[2:])
    else:
        raise SystemExit(__doc__.strip())


if __name__ == "__main__":
    main()
