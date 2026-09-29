#!/bin/bash
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: prepare-build-libraries.sh DEPENDENCY_PREFIX" >&2; exit 64; }
dependency_prefix="$(cd "$1" && pwd)"

# Give copied dependency trees consistent @rpath install names. Build clients
# provide their own prefix as an RPATH, and release payloads are relocated
# separately. Short names also fit older libraries' limited Mach-O headers.
while IFS= read -r -d '' library; do
    /usr/bin/install_name_tool -id "@rpath/$(basename "$library")" "$library"
    while IFS= read -r dependency; do
        case "$dependency" in /usr/lib/*|/System/Library/*) continue ;; esac
        local_dependency="$dependency_prefix/lib/$(basename "$dependency")"
        replacement="@rpath/$(basename "$dependency")"
        if [[ -f "$local_dependency" && "$dependency" != "$replacement" ]]; then
            /usr/bin/install_name_tool -change "$dependency" "$replacement" "$library"
        fi
    done < <(/usr/bin/otool -L "$library" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')
    /usr/bin/codesign --force --sign - --timestamp=none "$library"
done < <(/usr/bin/find "$dependency_prefix/lib" -type f -name '*.dylib' -print0)
