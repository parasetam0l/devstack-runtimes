#!/bin/bash
set -euo pipefail

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
jobs="$(sysctl -n hw.logicalcpu)"
export MACOSX_DEPLOYMENT_TARGET=27.0
export ARCHFLAGS="-arch arm64"

require_tool() {
    command -v "$1" >/dev/null 2>&1 || { echo "Required build tool is missing: $1" >&2; exit 69; }
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
    "$php_prefix/bin/phpize"
    PKG_CONFIG_PATH="$output_root/imagemagick-7.1/lib/pkgconfig" ./configure \
        --with-php-config="$php_prefix/bin/php-config"
    make -j "$jobs"
    if [[ "${DEVSTACK_DEFER_TEST_SUITES:-0}" == "1" ]]; then
        echo "DEVSTACK_DEFER_TEST_SUITES=1: deferring the $extension_name test suite for this pass." >&2
    else
        make test TESTS="--show-diff"
    fi
    mkdir -p "$php_prefix/lib/php/extensions"
    cp "modules/$extension_name.so" "$php_prefix/lib/php/extensions/$extension_name.so"
}

case "$runtime_id" in
    openssl-3.5)
        mkdir -p "$prefix"
        cd "$source_directory"
        ./Configure darwin64-arm64-cc shared --prefix="$prefix" --openssldir="$prefix/ssl" --libdir=lib
        make -j "$jobs"
        make test
        make install_sw install_ssldirs
        ;;
    imagemagick-7.1)
        configure_make_install \
            --prefix="$prefix" --disable-static --enable-shared --without-x \
            --without-perl --without-opencl --with-modules=no --disable-dependency-tracking
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
    php-7.4|php-8.5)
        openssl_prefix="$output_root/openssl-3.5"
        dependencies="$dependency_root/$runtime_id"
        [[ -d "$dependencies/lib/pkgconfig" ]] || {
            echo "The isolated PHP dependency tree is missing: $dependencies" >&2
            exit 69
        }
        export PKG_CONFIG_PATH="$dependencies/lib/pkgconfig:$openssl_prefix/lib/pkgconfig"
        export CPPFLAGS="-I$dependencies/include -I$openssl_prefix/include"
        export LDFLAGS="-L$dependencies/lib -L$openssl_prefix/lib -lresolv -Wl,-rpath,@loader_path/../lib"
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
            --with-fpm-group=staff --enable-gd --with-jpeg --with-gettext="$dependencies" --with-gmp \
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
            NO_INTERACTION=1 make test TESTS="--show-diff"
        fi
        mkdir -p "$prefix/lib"
        find "$dependencies/lib" -name '*.dylib' -maxdepth 3 -exec cp -R {} "$prefix/lib/" \;
        find "$openssl_prefix/lib" -name '*.dylib' -maxdepth 2 -exec cp -R {} "$prefix/lib/" \;
        find "$output_root/imagemagick-7.1/lib" -name '*.dylib' -maxdepth 2 -exec cp -R {} "$prefix/lib/" \;
        ;;
    mysql-5.7|mysql-8.4)
        require_tool cmake
        # Build-tree tools link @rpath OpenSSL dylibs but carry no rpath of their
        # own; let the loader fall back to the OpenSSL runtime prefix.
        export DYLD_FALLBACK_LIBRARY_PATH="$output_root/openssl-3.5/lib:$HOME/lib:/usr/local/lib:/usr/lib"
        boost_root="$dependency_root/mysql-8.4/boost/boost_1_84_0"
        if [[ -d "$boost_root" ]]; then
            mkdir -p "$source_directory/extra/boost"
            rm -rf "$source_directory/extra/boost/boost_1_84_0"
            ln -s "$boost_root" "$source_directory/extra/boost/boost_1_84_0"
        fi
        mkdir -p "$build_directory" "$prefix"
        cd "$build_directory"
        cmake "$source_directory" \
            -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_BUILD_TYPE=Release -DWITH_SSL="$output_root/openssl-3.5" \
            -DWITH_UNIT_TESTS=ON -DWITH_ROUTER=OFF -DWITH_NDB=OFF -DWITH_NDBCLUSTER=OFF \
            -DCMAKE_BUILD_RPATH="$output_root/openssl-3.5/lib" \
            -DDOWNLOAD_BOOST=OFF
        cmake --build . --parallel "$jobs"
        if [[ "${DEVSTACK_DEFER_TEST_SUITES:-0}" == "1" ]]; then
            echo "DEVSTACK_DEFER_TEST_SUITES=1: deferring ctest for this pass." >&2
        else
            ctest --output-on-failure
        fi
        cmake --install .
        mkdir -p "$prefix/lib"
        find "$output_root/openssl-3.5/lib" -name '*.dylib' -maxdepth 2 -exec cp -R {} "$prefix/lib/" \;
        ;;
    phpmyadmin-5.2.3)
        rm -rf "$prefix"
        mkdir -p "$prefix"
        cp -R "$source_directory/." "$prefix/"
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
    xdebug-php85) build_php_extension php-8.5 xdebug ;;
    redis-php)
        build_php_extension php-7.4 redis
        build_php_extension php-8.5 redis
        ;;
    imagick-php)
        build_php_extension php-7.4 imagick
        build_php_extension php-8.5 imagick
        ;;
    *) echo "No build recipe for $runtime_id" >&2; exit 64 ;;
esac

find "$prefix" -type f \( -perm -0100 -o -name '*.dylib' -o -name '*.so' \) -print0 | while IFS= read -r -d '' binary; do
    if /usr/bin/file "$binary" | /usr/bin/grep -q 'Mach-O'; then
        /usr/bin/codesign --force --sign - --timestamp=none "$binary"
    fi
done
