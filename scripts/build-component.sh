#!/bin/bash
set -euo pipefail
recipe_directory="$(cd "$(dirname "$0")" && pwd)"

: "${DEVSTACK_RUNTIME_ID:?}"
: "${DEVSTACK_SOURCE_DIRECTORY:?}"
: "${DEVSTACK_BUILD_DIRECTORY:?}"
: "${DEVSTACK_RUNTIME_PREFIX:?}"
: "${DEVSTACK_RUNTIME_OUTPUT:?}"
: "${DEVSTACK_DEPENDENCY_ROOT:?}"

runtime_id="$DEVSTACK_RUNTIME_ID"
source_directory="$DEVSTACK_SOURCE_DIRECTORY"
build_directory="$DEVSTACK_BUILD_DIRECTORY"
prefix="$DEVSTACK_RUNTIME_PREFIX"
output_root="$DEVSTACK_RUNTIME_OUTPUT"
dependency_root="$DEVSTACK_DEPENDENCY_ROOT"
jobs="${DEVSTACK_BUILD_JOBS:-2}"
# The oldest macOS the runtime supports comes from the lock; audit-runtime.sh
# rejects anything that ends up requiring a newer one.
MACOSX_DEPLOYMENT_TARGET="$(/usr/bin/python3 "$recipe_directory/runtime-lock.py" get "$runtime_id" minimumMacOS)"
export MACOSX_DEPLOYMENT_TARGET
source "$recipe_directory/build-environment.sh"
export ARCHFLAGS="-arch arm64"

require_tool() {
    command -v "$1" >/dev/null 2>&1 || { echo "Required build tool is missing: $1" >&2; exit 69; }
}

run_check() {
    /usr/bin/python3 "$recipe_directory/run-bounded-check.py" --seconds "${DEVSTACK_TEST_SECONDS:-1200}" --rss-mb "${DEVSTACK_TEST_RSS_MB:-1024}" -- "$@"
}

configure_make_install() {
    mkdir -p "$build_directory" "$prefix"
    cd "$build_directory"
    "$source_directory/configure" "$@"
    make -j "$jobs"
    make install
}

build_php_extension() {
    local php_id="$1"
    local extension_name="$2"
    local php_prefix="$output_root/$php_id"
    [[ -x "$php_prefix/bin/phpize" ]] || return 0
    local extension_work="$build_directory/$php_id"
    rm -rf "$extension_work"
    mkdir -p "$extension_work"
    cp -R "$source_directory/." "$extension_work/"
    cd "$extension_work"
    # PHP 7.4-era extensions use pre-C23 function declarations. Keep their
    # language mode explicit with newer Apple clang versions.
    export CFLAGS="-arch arm64 -O2 -std=gnu11 -Wno-incompatible-function-pointer-types"
    "$php_prefix/bin/phpize"
    extension_options=("--with-php-config=$php_prefix/bin/php-config")
    if [[ "$extension_name" == "imagick" ]]; then
        extension_options+=("--with-imagick=$output_root/imagemagick-7.1")
    fi
    PKG_CONFIG_PATH="$output_root/imagemagick-7.1/lib/pkgconfig" ./configure "${extension_options[@]}"
    make -j "$jobs"
    if [[ "${DEVSTACK_DEFER_TEST_SUITES:-0}" == "1" ]]; then
        echo "DEVSTACK_DEFER_TEST_SUITES=1: deferring the $extension_name test suite for this pass." >&2
    else
        NO_INTERACTION=1 REPORT_EXIT_STATUS=1 TEST_PHP_EXECUTABLE="$php_prefix/bin/php" run_check make test TESTS="-j1 --show-diff"
    fi
    mkdir -p "$php_prefix/lib/php/extensions"
    cp "modules/$extension_name.so" "$php_prefix/lib/php/extensions/$extension_name.so"
    /usr/bin/codesign --force --sign - --timestamp=none "$php_prefix/lib/php/extensions/$extension_name.so"
}

case "$runtime_id" in
    openssl-3.5)
        mkdir -p "$prefix"
        cd "$source_directory"
        ./Configure darwin64-arm64-cc shared --prefix="$prefix" --openssldir="$prefix/ssl" --libdir=lib
        make -j "$jobs"
        run_check make test
        make install_sw install_ssldirs
        ;;
    imagemagick-7.1)
        /usr/bin/python3 "$recipe_directory/prepare-imagemagick.py" "$source_directory"
        dependencies="$dependency_root/php-8.5"
        "${DEVSTACK_REPOSITORY_ROOT:?}/scripts/prepare-build-libraries.sh" "$dependencies"
        export PKG_CONFIG_PATH="$dependencies/lib/pkgconfig"
        export CPPFLAGS="-I$dependencies/include"
        export LDFLAGS="-L$dependencies/lib -Wl,-rpath,$dependencies/lib -Wl,-headerpad_max_install_names"
        configure_make_install \
            --prefix="$prefix" --disable-static --enable-shared --without-x \
            --without-perl --without-opencl --with-modules=no --with-png=yes --with-jpeg=yes --with-zlib=yes \
            --with-webp=yes --with-freetype=yes --disable-dependency-tracking
        mkdir -p "$prefix/lib"
        find "$dependencies/lib" -maxdepth 1 \( -name 'libpng*.dylib' -o -name 'libjpeg*.dylib' -o -name 'libz.*.dylib' \
            -o -name 'libwebp*.dylib' -o -name 'libsharpyuv*.dylib' -o -name 'libfreetype*.dylib' -o -name 'libzip*.dylib' \) \
            -exec cp -R {} "$prefix/lib/" \;
        for php_id in php-7.4 php-8.4 php-8.5; do
            if [[ -d "$output_root/$php_id/lib" ]]; then
                find "$prefix/lib" -maxdepth 1 -name '*.dylib' -exec cp -R {} "$output_root/$php_id/lib/" \;
            fi
        done
        ;;
    apache-2.4)
        openssl_prefix="$output_root/openssl-3.5"
        dependencies="$dependency_root/apache-2.4"
        [[ -x "$dependencies/bin/apr-1-config" && -x "$dependencies/bin/apu-1-config" ]] || {
            echo "Build locked APR, APR-util, and PCRE2 into $dependencies before Apache." >&2
            exit 69
        }
        PKG_CONFIG_PATH="$dependencies/lib/pkgconfig" configure_make_install \
            --prefix="$prefix" --enable-so --enable-ssl --enable-http2 \
            --enable-proxy --enable-proxy-fcgi --enable-proxy-http --enable-rewrite \
            --enable-headers --with-mpm=event --with-ssl="$openssl_prefix" \
            --with-apr="$dependencies/bin/apr-1-config" --with-apr-util="$dependencies/bin/apu-1-config" \
            --with-pcre="$dependencies/bin/pcre2-config"
        mkdir -p "$prefix/lib"
        find "$dependencies/lib" -name '*.dylib' -maxdepth 2 -exec cp -R {} "$prefix/lib/" \;
        find "$openssl_prefix/lib" -name '*.dylib' -maxdepth 2 -exec cp -R {} "$prefix/lib/" \;
        ;;
    php-7.4|php-8.4|php-8.5)
        openssl_prefix="$output_root/openssl-3.5"
        dependencies="$dependency_root/$runtime_id"
        [[ -d "$dependencies/lib/pkgconfig" ]] || {
            echo "The isolated PHP dependency tree is missing: $dependencies" >&2
            exit 69
        }
        "${DEVSTACK_REPOSITORY_ROOT:?}/scripts/prepare-build-libraries.sh" "$dependencies"
        export PKG_CONFIG_PATH="$dependencies/lib/pkgconfig:$openssl_prefix/lib/pkgconfig"
        export CPPFLAGS="-I$dependencies/include -I$openssl_prefix/include"
        export LDFLAGS="-L$dependencies/lib -L$openssl_prefix/lib -lresolv -Wl,-rpath,$dependencies/lib -Wl,-rpath,$openssl_prefix/lib -Wl,-rpath,@loader_path/../lib"
        if [[ "$runtime_id" == "php-7.4" ]]; then
            # Modern clang turns PHP 7.4's UB GD build test into a trap at -O2;
            # build the legacy runtime at -O1 so the configure run test passes.
            # ICU 78 headers need C++17, while intl's config pins -std=c++11;
            # our CXXFLAGS come later on the compile line and override it.
            export CFLAGS="-arch arm64 -O1 -Wno-incompatible-function-pointer-types"
            export CXXFLAGS="-arch arm64 -O1 -Wno-incompatible-function-pointer-types -std=gnu++17"
        fi
        configure_make_install \
            --prefix="$prefix" --disable-cgi --enable-fpm --enable-bcmath --enable-calendar --enable-opcache \
            --enable-exif --enable-ftp --enable-intl --enable-mbstring --enable-pcntl \
            --enable-soap --enable-sockets --with-bz2="$dependencies" --with-curl --with-fpm-user="$USER" \
            --with-fpm-group=staff --enable-gd --with-jpeg --with-freetype --with-webp --with-gettext="$dependencies" --with-gmp \
            --with-iconv="$dependencies" --with-zlib \
            --with-mysqli=mysqlnd --with-openssl="$openssl_prefix" --with-pdo-mysql=mysqlnd \
            --with-pdo-sqlite --with-sodium --with-sqlite3 --with-tidy="$dependencies" --with-xsl --with-zip
        cd "$build_directory"
        # PHP's install can leave a dangling bin/phar symlink when phar.phar was
        # not generated; remove it so the payload is self-consistent.
        if [[ -L "$prefix/bin/phar" && ! -e "$prefix/bin/phar.phar" ]]; then
            rm -f "$prefix/bin/phar"
        fi
        if [[ "${DEVSTACK_DEFER_TEST_SUITES:-0}" == "1" ]]; then
            echo "DEVSTACK_DEFER_TEST_SUITES=1: deferring the PHP test suite for this pass." >&2
        else
            # macOS 27 phpdbg watchpoint tests left runaway debugger children.
            # Keep them out of the automated host run until that issue is resolved.
            NO_INTERACTION=1 REPORT_EXIT_STATUS=1 run_check make test TESTS="-j1 --show-diff ext Zend tests sapi/cli sapi/fpm"
        fi
        mkdir -p "$prefix/lib"
        find "$dependencies/lib" -name '*.dylib' -maxdepth 3 -exec cp -R {} "$prefix/lib/" \;
        find "$openssl_prefix/lib" -name '*.dylib' -maxdepth 2 -exec cp -R {} "$prefix/lib/" \;
        find "$output_root/imagemagick-7.1/lib" -name '*.dylib' -maxdepth 2 -exec cp -R {} "$prefix/lib/" \;
        ;;
    postgresql-18)
        openssl_prefix="$output_root/openssl-3.5"
        dependencies="$dependency_root/php-8.5"
        export PKG_CONFIG_PATH="$dependencies/lib/pkgconfig:$openssl_prefix/lib/pkgconfig"
        export CPPFLAGS="-I$dependencies/include -I$openssl_prefix/include"
        export LDFLAGS="-L$dependencies/lib -L$openssl_prefix/lib -Wl,-rpath,$dependencies/lib -Wl,-rpath,$openssl_prefix/lib -Wl,-headerpad_max_install_names"
        configure_make_install --prefix="$prefix" --with-ssl=openssl --with-libedit-preferred
        mkdir -p "$prefix/lib"
        # Every library PostgreSQL links from the dependency tree ships with
        # it: the runtime may not borrow zlib from another runtime.
        find "$dependencies/lib" -maxdepth 1 \( -name 'libicu*.dylib' -o -name 'libz.*.dylib' \) -exec cp -R {} "$prefix/lib/" \;
        find "$openssl_prefix/lib" -maxdepth 1 -name '*.dylib' -exec cp -R {} "$prefix/lib/" \;
        # Common PostgreSQL extensions, including pgcrypto and citext.
        make -C "$build_directory/contrib" -j "$jobs"
        make -C "$build_directory/contrib" install
        ;;
    mysql-5.7|mysql-8.4)
        require_tool cmake
        cmake_command=cmake
        ctest_command=ctest
        # The bundled libevent finds pipe2 by linking against the SDK, where
        # it exists from macOS 27 on; the X plugin would then call a function
        # older supported macOS versions lack.
        mysql_options=("-DDOWNLOAD_BOOST=OFF" "-DEVENT__HAVE_PIPE2=0")
        if [[ "$runtime_id" == "mysql-5.7" ]]; then
            require_tool cmake-legacy
            cmake_command=cmake-legacy
            ctest_command=ctest-legacy
            # The locked mysql-boost archive contains the exact 1.59 headers
            # required by 5.7. CMake 4 needs an explicit legacy policy floor.
            mysql_options+=("-DWITH_BOOST=$source_directory/boost" "-DCMAKE_POLICY_VERSION_MINIMUM=3.5")
            # zlib 1.2.13 defines an fdopen macro that breaks the modern macOS
            # SDK headers; macOS always has fdopen.
            /usr/bin/sed -i '' 's/^#      ifndef fdopen$/#      if !defined(__APPLE__) \&\& !defined(fdopen)/' \
                "$source_directory/extra/zlib/zlib-1.2.13/zutil.h"
            # Boost 1.59's MPL casts out-of-range integers to enums in eagerly
            # instantiated typedefs; modern clang rejects that in constant
            # expressions. Upstream fix (boostorg/mpl#77): instantiate the
            # casts lazily as static members.
            /usr/bin/sed -i '' 's/^#if BOOST_WORKAROUND(__EDG_VERSION__, <= 243)$/#if BOOST_WORKAROUND(__EDG_VERSION__, <= 243) || __cplusplus >= 201103L/' \
                "$source_directory/boost/boost_1_59_0/boost/mpl/aux_/integral_wrapper.hpp"
        else
            boost_root="$dependency_root/mysql-8.4/boost/boost_1_84_0"
            [[ -d "$boost_root" ]] || { echo "MySQL 8.4 Boost headers are missing: $boost_root" >&2; exit 66; }
            mkdir -p "$source_directory/extra/boost"
            rm -rf "$source_directory/extra/boost/boost_1_84_0"
            ln -s "$boost_root" "$source_directory/extra/boost/boost_1_84_0"
        fi
        mkdir -p "$build_directory" "$prefix"
        cd "$build_directory"
        "$cmake_command" "$source_directory" \
            -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_BUILD_TYPE=Release -DWITH_SSL="$output_root/openssl-3.5" \
            -DWITH_UNIT_TESTS=ON -DWITH_ROUTER=OFF -DWITH_NDB=OFF -DWITH_NDBCLUSTER=OFF \
            -DCMAKE_BUILD_RPATH="$output_root/openssl-3.5/lib" "-DCMAKE_IGNORE_PREFIX_PATH=$ignored_prefixes" \
            "${mysql_options[@]}"
        "$cmake_command" --build . --parallel "$jobs"
        if [[ "${DEVSTACK_DEFER_TEST_SUITES:-0}" == "1" ]]; then
            echo "DEVSTACK_DEFER_TEST_SUITES=1: deferring ctest for this pass." >&2
        else
            run_check "$ctest_command" --output-on-failure --parallel 1
        fi
        "$cmake_command" --install .
        # Keep the upstream fixtures for verification, outside the shipped payload.
        if [[ -d "$prefix/mysql-test" ]]; then
            fixture_parent="$output_root/../runtime-test-fixtures"
            mkdir -p "$fixture_parent"
            mv "$prefix/mysql-test" "$fixture_parent/$runtime_id-$(date +%Y%m%d-%H%M%S)"
        fi
        # Test programs and plugins from the upstream suite: DevStack never
        # runs them and a configured server never loads them.
        for program in mysqltest mysqltest_safe_process mysqltest_embedded mysqlxtest mysql_client_test \
            mysql_client_test_embedded mysql_embedded mysql_keyring_encryption_test mysql_test_event_tracking comp_err; do
            rm -f "$prefix/bin/$program"
        done
        rm -rf "$prefix/lib/plugin/debug"
        find "$prefix/lib/plugin" -maxdepth 1 -type f \( -name 'component_test_*' -o -name 'libtest_*' -o -name 'test_*' \
            -o -name '*example*' -o -name 'qa_*' -o -name 'auth_test*' -o -name 'component_udf_reg_*' -o -name 'component_udf_unreg_*' \
            -o -name 'component_log_sink_test*' -o -name 'conflicting_variables*' -o -name 'ha_mock*' \) -delete
        mkdir -p "$prefix/lib"
        find "$output_root/openssl-3.5/lib" -name '*.dylib' -maxdepth 2 -exec cp -R {} "$prefix/lib/" \;
        ;;
    nginx-1.30)
        mkdir -p "$prefix"
        cd "$source_directory"
        dependencies="$dependency_root/apache-2.4"
        # --with-http_realip_module is required for the PROXY protocol
        # connections the helper sends to the web server.
        ./configure --prefix="$prefix" --with-http_ssl_module --with-http_v2_module --with-http_realip_module \
            --with-cc-opt="-arch arm64 -I$output_root/openssl-3.5/include -I$dependencies/include" \
            --with-ld-opt="-arch arm64 -Wl,-headerpad_max_install_names -L$output_root/openssl-3.5/lib -L$dependencies/lib -Wl,-rpath,$output_root/openssl-3.5/lib -Wl,-rpath,$dependencies/lib"
        make -j "$jobs"
        make install
        # Reinstalling over an earlier build leaves the previous binary as
        # nginx.old; it is not part of the runtime.
        rm -f "$prefix/sbin/nginx.old"
        # Nginx links OpenSSL and PCRE2 only; the rest of the Apache libraries
        # stay out of its runtime.
        mkdir -p "$prefix/lib"
        find "$output_root/openssl-3.5/lib" -maxdepth 1 -name '*.dylib' -exec cp -R {} "$prefix/lib/" \;
        find "$dependencies/lib" -maxdepth 1 -name 'libpcre2-8*.dylib' -exec cp -R {} "$prefix/lib/" \;
        ;;
    adminer-6.1.1)
        mkdir -p "$prefix"
        cp "$source_directory/adminer.php" "$prefix/index.php"
        "$output_root/php-8.5/bin/php" -n -l "$prefix/index.php"
        ;;
    phpmyadmin-5.2.3)
        rm -rf "$prefix"
        mkdir -p "$prefix"
        cp -R "$source_directory/." "$prefix/"
        /usr/bin/python3 "$recipe_directory/configure-phpmyadmin.py" "$prefix"
        ;;
    mailpit-1.31.1)
        rm -rf "$prefix"
        mkdir -p "$prefix"
        mailpit_binary="$(find "$source_directory" -type f -name mailpit -maxdepth 2 -print -quit)"
        [[ -n "$mailpit_binary" ]] || { echo "Mailpit binary missing from archive" >&2; exit 65; }
        cp "$mailpit_binary" "$prefix/mailpit"
        chmod 0755 "$prefix/mailpit"
        ;;
    composer-2.10.3)
        rm -rf "$prefix"
        mkdir -p "$prefix/bin"
        cp "$source_directory/composer.phar" "$prefix/composer.phar"
        chmod 0644 "$prefix/composer.phar"
        wrapper="$prefix/bin/composer"
        /usr/bin/printf '%s\n' \
            '#!/bin/zsh' \
            'if [[ "${1:-}" == "self-update" || "${1:-}" == "selfupdate" ]]; then' \
            '  echo "DevStack Composer is immutable; update it with a signed DevStack release." >&2' \
            '  exit 64' \
            'fi' \
            'runtime_root="$(cd "$(dirname "$0")/../.." && pwd)"' \
            'exec "$runtime_root/php-8.5/bin/php" "$(cd "$(dirname "$0")/.." && pwd)/composer.phar" "$@"' \
            > "$wrapper"
        chmod 0755 "$wrapper"
        ;;
    xdebug-php74) build_php_extension php-7.4 xdebug ;;
    xdebug-php84) build_php_extension php-8.4 xdebug ;;
    xdebug-php85) build_php_extension php-8.5 xdebug ;;
    redis-php)
        build_php_extension php-7.4 redis
        build_php_extension php-8.4 redis
        build_php_extension php-8.5 redis
        ;;
    imagick-php)
        build_php_extension php-7.4 imagick
        build_php_extension php-8.4 imagick
        build_php_extension php-8.5 imagick
        ;;
    *) echo "No build recipe for $runtime_id" >&2; exit 64 ;;
esac

# PHP extension recipes install into the owning PHP runtime instead of creating
# a standalone prefix; those modules are signed at installation above.
if [[ -d "$prefix" ]]; then
find "$prefix" -type f \( -perm -0100 -o -name '*.dylib' -o -name '*.so' \) -print0 | while IFS= read -r -d '' binary; do
    if /usr/bin/file "$binary" | /usr/bin/grep -q 'Mach-O'; then
        /usr/bin/codesign --force --sign - --timestamp=none "$binary"
    fi
done
fi
