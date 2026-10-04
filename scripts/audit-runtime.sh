#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: audit-runtime.sh RUNTIME_DIRECTORY [BUILD_ROOT]" >&2
    exit 64
fi

runtime_directory="$(cd "$1" && pwd)"
script_directory="$(cd "$(dirname "$0")" && pwd)"
build_root="${2:-}"
failures=0

# Symlinked dylib leaf names (for example libtidy.58.dylib ->
# libtidy.5.8.0.dylib) must not appear as dependencies: relocation writes the
# real basename as the install name, and dyld rejects a found dylib whose
# install name leaf differs from the requested one.
symlink_names_directory="$(/usr/bin/mktemp -d)"
binary_list="$(/usr/bin/mktemp)"
trap '/bin/rm -rf "$symlink_names_directory" "$binary_list"' EXIT
while IFS= read -r -d '' link; do
    leaf="$(basename "$link")"
    real="$(/usr/bin/python3 -c 'import os,sys; print(os.path.basename(os.path.realpath(sys.argv[1])))' "$link")"
    [[ "$leaf" == "$real" ]] || printf '%s' "$real" > "$symlink_names_directory/$leaf"
done < <(/usr/bin/find "$runtime_directory" -type l -name '*.dylib' -print0)

# Listed into a file first: macOS bash cannot observe a failure inside process
# substitution, so a crashing lister would make the audit pass on nothing.
/usr/bin/python3 "$script_directory/mach-o-files.py" "$runtime_directory" > "$binary_list"
[[ -s "$binary_list" ]] || { echo "No Mach-O files found under $runtime_directory" >&2; exit 65; }

while IFS= read -r -d '' binary; do
    if ! /usr/bin/file "$binary" | /usr/bin/grep -q 'Mach-O'; then
        continue
    fi
    if ! /usr/bin/lipo -archs "$binary" | /usr/bin/grep -Eq '(^| )arm64( |$)'; then
        echo "Non-ARM64 Mach-O: $binary" >&2
        failures=$((failures + 1))
    fi
    if ! /usr/bin/codesign --verify --strict "$binary" >/dev/null 2>&1; then
        echo "Unsigned or invalid Mach-O: $binary" >&2
        failures=$((failures + 1))
    fi
    dependencies="$(/usr/bin/otool -L "$binary")"
    if printf '%s\n' "$dependencies" | /usr/bin/grep -E '/opt/homebrew|/usr/local|/opt/local|Cellar|MacPorts' >/dev/null; then
        echo "Package-manager dependency in $binary" >&2
        failures=$((failures + 1))
    fi
    if [[ -n "$build_root" ]] && printf '%s\n' "$dependencies" | /usr/bin/grep -F "$build_root" >/dev/null; then
        echo "Build-machine dependency in $binary" >&2
        failures=$((failures + 1))
    fi
    while IFS= read -r dependency; do
        case "$dependency" in
            @rpath/*|@loader_path/*|@executable_path/*|/usr/lib/*|/System/Library/*) ;;
            /*) echo "Unrelocated absolute dependency in $binary: $dependency" >&2; failures=$((failures + 1)) ;;
            *) echo "Unrelocated bare dependency in $binary: $dependency" >&2; failures=$((failures + 1)) ;;
        esac
        case "$dependency" in
            @rpath/*|@loader_path/*|@executable_path/*)
                leaf="${dependency##*/}"
                if [[ -f "$symlink_names_directory/$leaf" ]]; then
                    real="$(<"$symlink_names_directory/$leaf")"
                    if [[ -n "$real" && "$real" != "$leaf" ]]; then
                        echo "Symlink-name dependency in $binary: $dependency (install name is $real)" >&2
                        failures=$((failures + 1))
                    fi
                fi
                ;;
        esac
    done < <(printf '%s\n' "$dependencies" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')
    if /usr/bin/otool -l "$binary" | /usr/bin/grep -A2 LC_RPATH | /usr/bin/grep -E '/opt/homebrew|/usr/local|/opt/local|Cellar|MacPorts' >/dev/null; then
        echo "Forbidden RPATH in $binary" >&2
        failures=$((failures + 1))
    fi
    while IFS= read -r rpath; do
        case "$rpath" in
            @loader_path/*|@executable_path/*) ;;
            /*) echo "Absolute RPATH in $binary: $rpath" >&2; failures=$((failures + 1)) ;;
        esac
    done < <(/usr/bin/otool -l "$binary" | /usr/bin/awk '/LC_RPATH/{getline; getline; print $2}')
done < "$binary_list"

# Every library a binary links must be found inside its own runtime.
if ! /usr/bin/python3 "$script_directory/runtime-load-paths.py" check "$runtime_directory" "$binary_list"; then
    failures=$((failures + 1))
fi

if [[ $failures -ne 0 ]]; then
    echo "$failures runtime audit failure(s)" >&2
    exit 65
fi
echo "Runtime audit passed: $runtime_directory"
