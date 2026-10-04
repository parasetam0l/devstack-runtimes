#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: relocate-runtime.sh RUNTIME_ROOT [FORBIDDEN_ROOT ...]" >&2
    exit 64
fi

runtime_root="$(cd "$1" && pwd)"
script_directory="$(cd "$(dirname "$0")" && pwd)"
shift
forbidden_roots=("$runtime_root")
for root in "$@"; do
    forbidden_roots+=("$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$root")")
done
# Install names are rewritten to each dylib's real file basename below, so
# every reference must use that same leaf name: dyld rejects a dylib whose
# install name leaf differs from the requested one. Record symlink leaf
# names (for example libtidy.58.dylib -> libtidy.5.8.0.dylib) so references
# can be normalized.
symlink_names_directory="$(/usr/bin/mktemp -d)"
binary_list="$(/usr/bin/mktemp)"
trap '/bin/rm -rf "$symlink_names_directory" "$binary_list"' EXIT
while IFS= read -r -d '' link; do
    leaf="$(basename "$link")"
    real="$(/usr/bin/python3 -c 'import os,sys; print(os.path.basename(os.path.realpath(sys.argv[1])))' "$link")"
    [[ "$leaf" == "$real" ]] || printf '%s' "$real" > "$symlink_names_directory/$leaf"
done < <(/usr/bin/find "$runtime_root" -type l -name '*.dylib' -print0)

# Listed into a file first so a failing lister stops the relocation.
if [[ -n "${DEVSTACK_RELOCATE_FILE_LIST:-}" ]]; then
    cat "$DEVSTACK_RELOCATE_FILE_LIST" > "$binary_list"
else
    /usr/bin/python3 "$script_directory/mach-o-files.py" "$runtime_root" > "$binary_list"
fi

while IFS= read -r -d '' binary; do
    [[ "$binary" == "$runtime_root"/* ]] || { echo "Relocation target is outside the runtime root: $binary" >&2; exit 65; }
    /usr/bin/file "$binary" | /usr/bin/grep -q 'Mach-O' || continue
    if [[ "$binary" == *.dylib ]]; then
        /usr/bin/install_name_tool -id "@rpath/$(basename "$binary")" "$binary"
    fi

    while IFS= read -r dependency; do
        replacement=""
        if [[ "$dependency" == /* ]]; then
            for root in "${forbidden_roots[@]}"; do
                if [[ "$dependency" == "$root"/* ]]; then replacement="@rpath/$(basename "$dependency")"; break; fi
            done
        else
            case "$dependency" in
                @rpath/*|@loader_path/*|@executable_path/*) replacement="$dependency" ;;
                @*) ;;
                # Some libraries (for example ICU) install a bare library name
                # as the install name; pin it to the runtime's @rpath so it
                # resolves from the payload instead of the loader's defaults.
                *) replacement="@rpath/$(basename "$dependency")" ;;
            esac
        fi
        if [[ -n "$replacement" ]]; then
            directory="${replacement%/*}"
            leaf="${replacement##*/}"
            real=""
            [[ -f "$symlink_names_directory/$leaf" ]] && real="$(<"$symlink_names_directory/$leaf")"
            [[ -n "$real" && "$real" != "$leaf" ]] && replacement="$directory/$real"
            if [[ "$replacement" != "$dependency" ]]; then
                /usr/bin/install_name_tool -change "$dependency" "$replacement" "$binary"
            fi
        fi
    done < <(/usr/bin/otool -L "$binary" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')

done < "$binary_list"

# Each top-level runtime ships as its own pack, so every binary searches only
# the folders of its own runtime that hold the libraries it links against.
# Absolute search paths and paths into other runtimes are removed.
/usr/bin/python3 "$script_directory/runtime-load-paths.py" fix "$runtime_root" "$binary_list"

while IFS= read -r -d '' binary; do
    /usr/bin/codesign --force --sign - --timestamp=none "$binary"
done < "$binary_list"

echo "Relocated runtime dependencies under $runtime_root"
