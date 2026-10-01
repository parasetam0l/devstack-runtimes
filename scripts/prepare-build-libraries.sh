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

# Generated system-library .pc files can carry the build host's SDK include
# directory. A bare SDK include is redundant because clang searches the active
# SDK on its own, and hard-coding one machine's Xcode path breaks
# reproducibility. Strip it while keeping subdirectory includes such as
# -I.../usr/include/libxml2, which headers do need.
if [[ -d "$dependency_prefix/lib/pkgconfig" ]]; then
    while IFS= read -r -d '' pc_file; do
        /usr/bin/sed -i '' -E 's~ -I[^ ]*\.sdk/usr/include([[:space:]]|$)~\1~g' "$pc_file"
    done < <(/usr/bin/find "$dependency_prefix/lib/pkgconfig" -type f -name '*.pc' -print0)
fi
