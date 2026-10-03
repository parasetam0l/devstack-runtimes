#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime_cache="${DEVSTACK_SOURCE_CACHE:-$repository_root/.build/runtime-cache}"
dependency_cache="$runtime_cache/dependencies"
mkdir -p "$runtime_cache" "$dependency_cache"

# Lock listings are captured first: a failing lock reader inside process
# substitution would go unnoticed and "verify" nothing.
runtime_ids="$("$repository_root/scripts/runtime-lock.py" list)"
runtime_patches="$("$repository_root/scripts/runtime-lock.py" patches)"
dependency_sources="$({ "$repository_root/scripts/dependency-lock.py" apache; "$repository_root/scripts/dependency-lock.py" php; "$repository_root/scripts/dependency-lock.py" mysql; } | /usr/bin/sort -u)"
[[ -n "$runtime_ids" && -n "$dependency_sources" ]] || { echo "The source locks list nothing to verify." >&2; exit 65; }

while IFS= read -r runtime_id; do
    "$repository_root/scripts/fetch-runtime.sh" "$runtime_id" "$runtime_cache" >/dev/null
    echo "verified runtime source: $runtime_id"
done <<< "$runtime_ids"

while IFS=$'\t' read -r runtime_id patch_index; do
    [[ -n "$runtime_id" ]] || continue
    "$repository_root/scripts/fetch-runtime.sh" "$runtime_id" "$runtime_cache" "$patch_index" >/dev/null
    echo "verified runtime patch: $runtime_id #$patch_index"
done <<< "$runtime_patches"

while IFS=$'\t' read -r id version url sha256; do
    filename="${url%%\?*}"
    filename="${filename##*/}"
    destination="$dependency_cache/$id-$filename"
    if [[ -f "$destination" ]] && [[ "$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print $1}')" == "$sha256" ]]; then
        echo "verified dependency source: $id $version"
        continue
    fi
    /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$destination.partial" "$url"
    actual="$(/usr/bin/shasum -a 256 "$destination.partial" | /usr/bin/awk '{print $1}')"
    if [[ "$actual" != "$sha256" ]]; then
        rm -f "$destination.partial"
        echo "Checksum mismatch for $id: expected $sha256, got $actual" >&2
        exit 65
    fi
    mv "$destination.partial" "$destination"
    echo "verified dependency source: $id $version"
done <<< "$dependency_sources"

DEVSTACK_BUILD_TOOLS_VERIFY_ONLY=1 "$repository_root/scripts/fetch-build-tools.sh"

echo "All locked sources verified under $runtime_cache"
