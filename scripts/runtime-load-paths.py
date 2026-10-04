#!/usr/bin/python3
"""Keeps every runtime's library lookups inside that runtime.

Each top-level directory of a runtime payload (openssl-3.5, php-8.5, ...)
ships as its own pack, so a binary may only search its own runtime's
library folders.

  runtime-load-paths.py fix RUNTIME_ROOT BINARY_LIST
      Replace each binary's LC_RPATH entries with @loader_path paths to the
      folders of its own runtime that hold the libraries it links against,
      and nothing else: no absolute paths, no paths into another runtime.
      Unneeded entries go first, so the few that are added fit in binaries
      linked without spare header room. Does not re-sign.
  runtime-load-paths.py check RUNTIME_ROOT BINARY_LIST
      Fail unless every @rpath and @loader_path dependency of every binary
      resolves to a file inside the binary's own runtime.

A library's @rpath dependency on a sibling in its own folder counts as
resolved without a search path of its own: whatever loaded the library found
it through a search path that includes that folder, and dyld keeps the
loader's search paths when it resolves the library's dependencies. Some
libraries (ICU) are linked without header room for a new search path.

BINARY_LIST is the NUL-separated output of mach-o-files.py.
"""

import os
import subprocess
import sys

SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")


def run(arguments):
    return subprocess.run(arguments, check=True, capture_output=True, text=True).stdout


def rpaths(binary):
    lines = run(["/usr/bin/otool", "-l", binary]).splitlines()
    found = []
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            for candidate in lines[index + 1:index + 4]:
                candidate = candidate.strip()
                if candidate.startswith("path "):
                    found.append(candidate[5:].rsplit(" (offset", 1)[0])
                    break
    return found


def dependencies(binary):
    listed = [line.strip().split(" (compatibility", 1)[0].split(" (current", 1)[0]
              for line in run(["/usr/bin/otool", "-L", binary]).splitlines()[1:] if line.strip()]
    identity = run(["/usr/bin/otool", "-D", binary]).splitlines()[1:]
    if identity and listed and listed[0] == identity[0].strip():
        listed = listed[1:]
    return listed


def is_library(binary):
    return " DYLIB " in run(["/usr/bin/otool", "-hv", binary])


def component_of(binary, root):
    relative = os.path.relpath(binary, root)
    return os.path.join(root, relative.split(os.sep, 1)[0])


_library_directories = {}


def library_directories(component):
    """Folders holding dylibs (files or links), shallowest first."""
    if component not in _library_directories:
        directories = set()
        for directory, _, files in os.walk(component):
            if any(name.endswith(".dylib") for name in files):
                directories.add(directory)
        _library_directories[component] = sorted(directories, key=lambda path: (path.count(os.sep), path))
    return _library_directories[component]


def resolve(token_path, binary):
    for token in ("@loader_path", "@executable_path"):
        if token_path == token or token_path.startswith(token + "/"):
            return os.path.normpath(os.path.join(os.path.dirname(binary), token_path[len(token):].lstrip("/")))
    return None


def inside(path, component):
    real, root = os.path.realpath(path), os.path.realpath(component)
    return real == root or real.startswith(root + os.sep)


def wanted_rpaths(binary, component):
    """One search path per folder that holds an @rpath dependency."""
    origin = os.path.dirname(binary)
    wanted = []
    for dependency in dependencies(binary):
        if not dependency.startswith("@rpath/"):
            continue
        leaf = dependency[len("@rpath/"):]
        directory = next((candidate for candidate in library_directories(component)
                          if os.path.exists(os.path.join(candidate, leaf))), None)
        if directory is None:
            continue  # reported by check
        path = "@loader_path/" + os.path.relpath(directory, origin)
        if path not in wanted:
            wanted.append(path)
    return wanted


def fix(binary, root):
    component = component_of(binary, root)
    wanted = wanted_rpaths(binary, component)
    existing = rpaths(binary)
    for path in existing:
        resolved = resolve(path, binary)
        if resolved is None or not inside(resolved, component) or path not in wanted:
            run(["/usr/bin/install_name_tool", "-delete_rpath", path, binary])
    kept = set(path for path in existing if path in wanted)
    for path in wanted:
        if path in kept:
            continue
        try:
            run(["/usr/bin/install_name_tool", "-add_rpath", path, binary])
        except subprocess.CalledProcessError as error:
            # Only a library's own folder may be left to the loader's search
            # paths (see above); anything else must fail the build rather
            # than ship with a missing search path.
            if path == "@loader_path/." and is_library(binary) and "do not fit" in error.stderr:
                continue
            raise SystemExit(f"Cannot add {path} to {binary}: {error.stderr.strip()}")


def check(binary, root):
    component = component_of(binary, root)
    search = [resolve(path, binary) for path in rpaths(binary)]
    if is_library(binary):
        search.append(os.path.dirname(binary))
    problems = []
    for path in search:
        if path is None or not inside(path, component):
            problems.append(f"search path outside {os.path.basename(component)}")
    for dependency in dependencies(binary):
        if dependency.startswith(SYSTEM_PREFIXES):
            continue
        if dependency.startswith("@rpath/"):
            leaf = dependency[len("@rpath/"):]
            found = next((os.path.join(directory, leaf) for directory in search
                          if directory and os.path.exists(os.path.join(directory, leaf))), None)
        else:
            found = resolve(dependency, binary)
            found = found if found and os.path.exists(found) else None
        if found is None:
            problems.append(f"{dependency} is not found in {os.path.basename(component)}")
        elif not inside(found, component):
            problems.append(f"{dependency} resolves outside {os.path.basename(component)}")
    return problems


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("fix", "check"):
        raise SystemExit(__doc__.strip())
    command, root = sys.argv[1], os.path.abspath(sys.argv[2])
    with open(sys.argv[3], "rb") as listing:
        binaries = [os.fsdecode(item) for item in listing.read().split(b"\0") if item]
    if not binaries:
        # phpMyAdmin, Adminer and Composer are PHP code only.
        print(f"No Mach-O files under {root}: no load paths to {command}.")
        return
    failures = 0
    for binary in binaries:
        if not os.path.abspath(binary).startswith(root + os.sep):
            raise SystemExit(f"Outside the runtime root: {binary}")
        if command == "fix":
            fix(binary, root)
        else:
            for problem in check(binary, root):
                print(f"{os.path.relpath(binary, root)}: {problem}", file=sys.stderr)
                failures += 1
    if failures:
        raise SystemExit(f"{failures} load path problem(s)")
    print(("Load paths isolated per runtime under " if command == "fix" else "Every runtime loads only its own libraries: ") + root)


if __name__ == "__main__":
    main()
