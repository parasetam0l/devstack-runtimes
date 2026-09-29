#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: collect-licenses.sh BUILD_WORK_ROOT OUTPUT_DIRECTORY" >&2
    exit 64
fi

work_root="$(cd "$1" && pwd)"
output="$2"
rm -rf "$output"
mkdir -p "$output"

while IFS= read -r -d '' license; do
    relative="${license#$work_root/}"
    component="${relative%%/*}"
    destination="$output/$component"
    mkdir -p "$destination"
    safe_name="${relative//\//_}"
    cp "$license" "$destination/$safe_name"
done < <(/usr/bin/find "$work_root" -maxdepth 6 -type f \( \
    -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' -o -iname 'COPYRIGHT*' \) -print0)

echo "Third-party notices: $output"
