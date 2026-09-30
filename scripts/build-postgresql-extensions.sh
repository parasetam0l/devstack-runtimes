#!/bin/bash
set -euo pipefail
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="${DEVSTACK_RUNTIME_OUTPUT:-$repository_root/.build/Runtimes}"
work_root="${DEVSTACK_BUILD_ROOT:-$repository_root/.build/runtime-work}"
pg_prefix="$output_root/postgresql-18"
export PATH="$pg_prefix/bin:$repository_root/.build/build-tools/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=27.0
export CFLAGS="-arch arm64 -O2 -std=gnu11"
export CPPFLAGS="-I$pg_prefix/include"
export LDFLAGS="-L$pg_prefix/lib -Wl,-rpath,$pg_prefix/lib -Wl,-headerpad_max_install_names"
export PKG_CONFIG_PATH="$pg_prefix/lib/pkgconfig"
export PGSQL_CFLAGS="-I$pg_prefix/include"
export PGSQL_LIBS="-L$pg_prefix/lib -lpq"
for php_id in php-8.4 php-8.5; do
    php_prefix="$output_root/$php_id"
    source_directory="$work_root/$php_id/source"
    [[ -d "$source_directory/ext/pgsql" ]] || { echo "Build $php_id before its PostgreSQL drivers" >&2; exit 66; }
    for extension_name in pgsql pdo_pgsql; do
        extension_work="$work_root/postgresql-extensions/$php_id/$extension_name"
        mkdir -p "$extension_work"
        cp -R "$source_directory/ext/$extension_name/." "$extension_work/"
        cd "$extension_work"
        "$php_prefix/bin/phpize"
        if [[ "$extension_name" == "pgsql" ]]; then driver_option="--with-pgsql=$pg_prefix"
        else driver_option="--with-pdo-pgsql=$pg_prefix"; fi
        ./configure "--with-php-config=$php_prefix/bin/php-config" "$driver_option"
        make -j "${DEVSTACK_BUILD_JOBS:-2}"
        cp "modules/$extension_name.so" "$php_prefix/lib/php/extensions/$extension_name.so"
    done
    find "$pg_prefix/lib" -maxdepth 1 -name 'libpq*.dylib' -exec cp -R {} "$php_prefix/lib/" \;
done
"$repository_root/scripts/relocate-runtime.sh" "$output_root" "$work_root" "$repository_root/.build/runtime-dependencies"
"$repository_root/scripts/audit-runtime.sh" "$output_root" "$work_root"
