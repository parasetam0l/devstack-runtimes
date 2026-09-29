#!/bin/bash
set -euo pipefail

# Installs the pinned build-host toolchain into an isolated prefix. These tools
# are inputs to the release machine and are never packaged with DevStack.
#
# Usage: fetch-build-tools.sh
#   DEVSTACK_BUILD_TOOLS_CACHE  archive cache (default .build/build-tools-cache)
#   DEVSTACK_BUILD_TOOLS_ROOT   install prefix (default .build/build-tools)
#   DEVSTACK_BUILD_TOOLS_VERIFY_ONLY=1  download and checksum without installing

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
lock="$repository_root/Dependencies/build-tools-lock.json"
cache_directory="${DEVSTACK_BUILD_TOOLS_CACHE:-$repository_root/.build/build-tools-cache}"
tools_root="${DEVSTACK_BUILD_TOOLS_ROOT:-$repository_root/.build/build-tools}"
work_root="${DEVSTACK_BUILD_TOOLS_WORK:-$repository_root/.build/build-tools-work}"
jobs="$(sysctl -n hw.logicalcpu)"
verify_only="${DEVSTACK_BUILD_TOOLS_VERIFY_ONLY:-0}"
mkdir -p "$cache_directory" "$tools_root/bin" "$work_root"

tool_ids() {
    /usr/bin/python3 - "$lock" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print("\n".join(tool["id"] for tool in data["tools"]))
PY
}

tool_field() {
    /usr/bin/python3 - "$lock" "${1:?}" "${2:?}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
tool = next(item for item in data["tools"] if item["id"] == sys.argv[2])
print(tool[sys.argv[3]])
PY
}

download_tool() {
    local id="$1" url="$2" sha256="$3"
    local filename="${url%%\?*}"
    filename="${filename##*/}"
    local archive="$cache_directory/$id-$filename"
    if [[ ! -f "$archive" ]] || [[ "$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')" != "$sha256" ]]; then
        /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$archive.partial" "$url"
        local actual
        actual="$(/usr/bin/shasum -a 256 "$archive.partial" | /usr/bin/awk '{print $1}')"
        if [[ "$actual" != "$sha256" ]]; then
            rm -f "$archive.partial"
            echo "Checksum mismatch for build tool $id: expected $sha256, got $actual" >&2
            exit 65
        fi
        mv "$archive.partial" "$archive"
    fi
    printf '%s\n' "$archive"
}

install_tool() {
    local id="$1" version="$2" kind="$3" archive="$4"
    local marker="$tools_root/.installed-$id-$version"
    if [[ -f "$marker" ]]; then
        echo "build tool already installed: $id $version"
        return
    fi
    local work="$work_root/$id-$version"
    rm -rf "$work"
    mkdir -p "$work"
    case "$archive" in
        *.tar.gz|*.tgz) /usr/bin/tar -xzf "$archive" -C "$work" ;;
        *.tar.xz) /usr/bin/tar -xJf "$archive" -C "$work" ;;
        *) echo "Unsupported build tool archive: $archive" >&2; exit 65 ;;
    esac
    local directories=() entry
    while IFS= read -r entry; do
        [[ -d "$entry" ]] && directories+=("$entry")
    done < <(/usr/bin/find "$work" -mindepth 1 -maxdepth 1)
    if [[ ${#directories[@]} -eq 1 ]]; then
        /usr/bin/find "${directories[0]}" -mindepth 1 -maxdepth 1 -exec /bin/mv {} "$work/" \;
        /bin/rmdir "${directories[0]}"
    fi

    case "$kind" in
        prebuilt-archive)
            local binary
            binary="$(/usr/bin/find "$work" -type f -name cmake -perm -111 | /usr/bin/head -1)"
            [[ -n "$binary" ]] || { echo "CMake binary missing from $archive" >&2; exit 65; }
            ln -sf "$binary" "$tools_root/bin/cmake"
            ln -sf "$(dirname "$binary")/ctest" "$tools_root/bin/ctest"
            ;;
        autotools-source)
            cd "$work"
            if [[ "$id" == "pkgconf" ]]; then
                PATH="$tools_root/bin:$PATH" ./configure --prefix="$tools_root" --with-system-libdir=/usr/lib --with-system-includedir=/usr/include >/dev/null
            else
                PATH="$tools_root/bin:$PATH" ./configure --prefix="$tools_root" >/dev/null
            fi
            make -j "$jobs" >/dev/null
            make install >/dev/null
            if [[ "$id" == "pkgconf" ]]; then
                ln -sf "$tools_root/bin/pkgconf" "$tools_root/bin/pkg-config"
            fi
            ;;
        cmake-source)
            PATH="$tools_root/bin:$PATH" cmake -S "$work" -B "$work/.cmake-build" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF >/dev/null
            PATH="$tools_root/bin:$PATH" cmake --build "$work/.cmake-build" --parallel "$jobs" >/dev/null
            ln -sf "$work/.cmake-build/ninja" "$tools_root/bin/ninja"
            ;;
        *)
            echo "Unsupported build tool kind: $kind" >&2
            exit 65
            ;;
    esac
    touch "$marker"
    echo "installed build tool: $id $version"
}

while IFS= read -r id; do
    version="$(tool_field "$id" version)"
    kind="$(tool_field "$id" kind)"
    url="$(tool_field "$id" url)"
    sha256="$(tool_field "$id" sha256)"
    archive="$(download_tool "$id" "$url" "$sha256")"
    if [[ "$verify_only" == "1" ]]; then
        echo "verified build tool source: $id $version"
        continue
    fi
    install_tool "$id" "$version" "$kind" "$archive"
done < <(tool_ids)

if [[ "$verify_only" != "1" ]]; then
    echo "Build tools: $tools_root/bin"
fi
