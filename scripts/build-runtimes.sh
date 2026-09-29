#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cache_directory="${DEVSTACK_SOURCE_CACHE:-$repository_root/.build/runtime-cache}"
work_root="${DEVSTACK_BUILD_ROOT:-$repository_root/.build/runtime-work}"
output_root="${DEVSTACK_RUNTIME_OUTPUT:-$repository_root/.build/Runtimes}"
dependency_root="${DEVSTACK_DEPENDENCY_ROOT:-$repository_root/.build/runtime-dependencies}"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "DevStack runtimes must be built natively on Apple Silicon macOS." >&2
    exit 69
fi
if ! xcrun --show-sdk-path >/dev/null 2>&1; then
    echo "Xcode command-line tools are required on the build machine." >&2
    exit 69
fi

requested=("$@")
if [[ ${#requested[@]} -eq 0 || "${requested[0]}" == "all" ]]; then
    requested=(openssl-3.5 imagemagick-7.1 apache-2.4 php-8.5 mysql-8.4 phpmyadmin-5.2.3 mailpit-1.31.1 composer-2.10.3 php-7.4 xdebug-php85 redis-php imagick-php xdebug-php74 mysql-5.7)
fi

mkdir -p "$cache_directory" "$work_root" "$output_root" "$dependency_root"
for runtime_id in "${requested[@]}"; do
    echo "==> Building $runtime_id"
    archive="$($repository_root/scripts/fetch-runtime.sh "$runtime_id" "$cache_directory")"
    component_work="$work_root/$runtime_id"
    rm -rf "$component_work"
    mkdir -p "$component_work/source"

    case "$archive" in
        *.phar) cp "$archive" "$component_work/source/composer.phar" ;;
        *.tar.gz|*.tgz) /usr/bin/tar -xzf "$archive" -C "$component_work/source" --strip-components=1 ;;
        *.tar.bz2) /usr/bin/tar -xjf "$archive" -C "$component_work/source" --strip-components=1 ;;
        *.tar.xz) /usr/bin/tar -xJf "$archive" -C "$component_work/source" --strip-components=1 ;;
        *) echo "Unsupported source archive: $archive" >&2; exit 65 ;;
    esac

    if [[ "$runtime_id" == "php-7.4" ]]; then
        patch_url="$($repository_root/scripts/runtime-lock.py patch php-7.4 0 url)"
        patch_sha="$($repository_root/scripts/runtime-lock.py patch php-7.4 0 sha256)"
        patch_file="$cache_directory/php-7.4-openssl3.patch"
        /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --output "$patch_file.partial" "$patch_url"
        actual_patch_sha="$(/usr/bin/shasum -a 256 "$patch_file.partial" | /usr/bin/awk '{print $1}')"
        [[ "$actual_patch_sha" == "$patch_sha" ]] || { rm -f "$patch_file.partial"; echo "PHP 7.4 patch checksum mismatch" >&2; exit 65; }
        mv "$patch_file.partial" "$patch_file"
        /usr/bin/patch -d "$component_work/source" -p1 < "$patch_file"
    fi

    DEVSTACK_REPOSITORY_ROOT="$repository_root" \
    DEVSTACK_RUNTIME_ID="$runtime_id" \
    DEVSTACK_SOURCE_DIRECTORY="$component_work/source" \
    DEVSTACK_BUILD_DIRECTORY="$component_work/build" \
    DEVSTACK_RUNTIME_PREFIX="$output_root/$runtime_id" \
    DEVSTACK_RUNTIME_OUTPUT="$output_root" \
    DEVSTACK_DEPENDENCY_ROOT="$dependency_root" \
    "$repository_root/scripts/build-component.sh"
done

"$repository_root/scripts/relocate-runtime.sh" "$output_root" "$work_root" "$dependency_root"
"$repository_root/scripts/audit-runtime.sh" "$output_root" "$work_root"
"$repository_root/scripts/generate-sbom.py" "$output_root" "$repository_root/SBOM/runtime-sbom.cdx.json"
"$repository_root/scripts/collect-licenses.sh" "$work_root" "$repository_root/ThirdPartyNotices"
echo "Runtime output: $output_root"
