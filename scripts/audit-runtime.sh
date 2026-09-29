#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: audit-runtime.sh RUNTIME_DIRECTORY [BUILD_ROOT]" >&2
    exit 64
fi

runtime_directory="$(cd "$1" && pwd)"
build_root="${2:-}"
failures=0

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
done < <(/usr/bin/find "$runtime_directory" -type f -print0)

if [[ $failures -ne 0 ]]; then
    echo "$failures runtime audit failure(s)" >&2
    exit 65
fi
echo "Runtime audit passed: $runtime_directory"
