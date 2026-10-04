#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 && $# -ne 3 ]]; then
    echo "usage: fetch-runtime.sh RUNTIME_ID CACHE_DIRECTORY [PATCH_INDEX]" >&2
    exit 64
fi

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime_id="$1"
cache_directory="$2"
query="$repository_root/scripts/runtime-lock.py"
# Cache names are shared with scripts/collect-licenses.py.
if [[ $# -eq 3 ]]; then
    url="$($query patch "$runtime_id" "$3" url)"
    expected_sha256="$($query patch "$runtime_id" "$3" sha256)"
    name_prefix="$runtime_id-patch$3"
else
    url="$($query get "$runtime_id" source.url)"
    expected_sha256="$($query get "$runtime_id" source.sha256)"
    name_prefix="$runtime_id"
fi
filename="${url%%\?*}"
filename="${filename##*/}"
destination="$cache_directory/$name_prefix-$filename"

mkdir -p "$cache_directory"
if [[ -f "$destination" ]]; then
    actual_sha256="$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print $1}')"
    if [[ "$actual_sha256" == "$expected_sha256" ]]; then
        printf '%s\n' "$destination"
        exit 0
    fi
    rm -f "$destination"
fi

# Projects move superseded releases (cdn.mysql.com to /archives, for
# example); the lock may list mirrors, tried in order with the same hash.
candidates=("$url")
if [[ $# -eq 2 ]]; then
    while IFS= read -r mirror; do [[ -n "$mirror" ]] && candidates+=("$mirror"); done \
        < <("$query" get "$runtime_id" source | /usr/bin/python3 -c 'import json, sys; print("\n".join(json.load(sys.stdin).get("mirrors", [])))')
fi
temporary="$destination.partial"
rm -f "$temporary"
downloaded=0
for candidate in "${candidates[@]}"; do
    if /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$temporary" "$candidate"; then
        downloaded=1
        break
    fi
    echo "Not available, trying the next source: $candidate" >&2
done
[[ "$downloaded" == 1 ]] || { echo "No source for $runtime_id is available." >&2; exit 66; }
actual_sha256="$(/usr/bin/shasum -a 256 "$temporary" | /usr/bin/awk '{print $1}')"
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    rm -f "$temporary"
    echo "SHA-256 mismatch for $runtime_id: expected $expected_sha256, got $actual_sha256" >&2
    exit 65
fi
mv "$temporary" "$destination"
printf '%s\n' "$destination"
