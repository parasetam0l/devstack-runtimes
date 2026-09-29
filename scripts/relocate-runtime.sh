#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: relocate-runtime.sh RUNTIME_ROOT [FORBIDDEN_ROOT ...]" >&2
    exit 64
fi

runtime_root="$(cd "$1" && pwd)"
shift
forbidden_roots=("$runtime_root" "$@")
library_directories=()
while IFS= read -r directory; do library_directories+=("$directory"); done < <(/usr/bin/find "$runtime_root" -type f -name '*.dylib' -exec dirname {} \; | /usr/bin/sort -u)

while IFS= read -r -d '' binary; do
    /usr/bin/file "$binary" | /usr/bin/grep -q 'Mach-O' || continue
    if [[ "$binary" == *.dylib ]]; then
        /usr/bin/install_name_tool -id "@rpath/$(basename "$binary")" "$binary"
    fi

    while IFS= read -r dependency; do
        replacement=""
        for root in "${forbidden_roots[@]}"; do
            if [[ "$dependency" == "$root"/* ]]; then replacement="@rpath/$(basename "$dependency")"; break; fi
        done
        if [[ -n "$replacement" ]]; then
            /usr/bin/install_name_tool -change "$dependency" "$replacement" "$binary"
        fi
    done < <(/usr/bin/otool -L "$binary" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')

    while IFS= read -r existing_rpath; do
        for root in "${forbidden_roots[@]}"; do
            if [[ "$existing_rpath" == "$root"/* || "$existing_rpath" == "$root" ]]; then
                /usr/bin/install_name_tool -delete_rpath "$existing_rpath" "$binary"
            fi
        done
    done < <(/usr/bin/otool -l "$binary" | /usr/bin/awk '/LC_RPATH/{getline; getline; print $2}')

    binary_directory="$(dirname "$binary")"
    for library_directory in "${library_directories[@]}"; do
        relative="$(/usr/bin/python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$library_directory" "$binary_directory")"
        rpath="@loader_path/$relative"
        /usr/bin/install_name_tool -add_rpath "$rpath" "$binary" 2>/dev/null || true
    done
    /usr/bin/codesign --force --sign - --timestamp=none "$binary"
done < <(/usr/bin/find "$runtime_root" -type f -print0)

echo "Relocated runtime dependencies under $runtime_root"
