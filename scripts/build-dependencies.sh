#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cache_root="${DEVSTACK_SOURCE_CACHE:-$repository_root/.build/runtime-cache}/dependencies"
work_root="${DEVSTACK_BUILD_ROOT:-$repository_root/.build/runtime-work}/dependencies"
dependency_root="${DEVSTACK_DEPENDENCY_ROOT:-$repository_root/.build/runtime-dependencies}"
# Build with the pinned tools and the system only. A package manager's tools
# earlier on PATH leak in otherwise; Homebrew's GNU ar, for example, writes
# archives that Apple's linker rejects.
export PATH="${DEVSTACK_BUILD_TOOLS_ROOT:-$repository_root/.build/build-tools}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
jobs="${DEVSTACK_BUILD_JOBS:-$(sysctl -n hw.logicalcpu)}"
sdk="$(xcrun --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=27.0
export CFLAGS="-arch arm64 -O2 -Wno-incompatible-function-pointer-types"
export CXXFLAGS="-arch arm64 -O2 -Wno-incompatible-function-pointer-types"
export LDFLAGS="-Wl,-headerpad_max_install_names"

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || { echo "Dependencies require Apple Silicon macOS." >&2; exit 69; }
command -v cmake >/dev/null || { echo "CMake is required on the build host." >&2; exit 69; }
command -v pkg-config >/dev/null || { echo "pkg-config is required on the build host." >&2; exit 69; }
mkdir -p "$cache_root" "$work_root" "$dependency_root"

dependency_test_failures=""

run_check_suite() {
    local component="$1"
    shift
    if /usr/bin/python3 "$repository_root/scripts/run-bounded-check.py" --seconds "${DEVSTACK_TEST_SECONDS:-1200}" -- "$@"; then
        return
    fi
    if [[ "${DEVSTACK_STRICT_TEST_SUITES:-0}" == "1" ]]; then
        echo "$component test suite failed" >&2
        exit 70
    fi
    echo "warning: $component test suite reported failures; continuing. Set DEVSTACK_STRICT_TEST_SUITES=1 to fail closed." >&2
    dependency_test_failures="$dependency_test_failures $component"
}

fetch_and_extract() {
    local id="$1" version="$2" url="$3" expected="$4" destination="$5"
    local filename="${url##*/}"
    local archive="$cache_root/$id-$filename"
    if [[ ! -f "$archive" || "$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')" != "$expected" ]]; then
        rm -f "$archive" "$archive.partial"
        /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$archive.partial" "$url"
        [[ "$(/usr/bin/shasum -a 256 "$archive.partial" | /usr/bin/awk '{print $1}')" == "$expected" ]] || { rm -f "$archive.partial"; echo "Checksum mismatch for $id" >&2; exit 65; }
        mv "$archive.partial" "$archive"
    fi
    rm -rf "$destination"
    mkdir -p "$destination"
    case "$archive" in
        *.tar.gz|*.tgz) /usr/bin/tar -xzf "$archive" -C "$destination" --strip-components=1 ;;
        *.tar.xz) /usr/bin/tar -xJf "$archive" -C "$destination" --strip-components=1 ;;
        *) echo "Unsupported dependency archive: $archive" >&2; exit 65 ;;
    esac
}

build_autotools() {
    local source="$1" prefix="$2"
    shift 2
    mkdir -p "$source/.devstack-build"
    cd "$source/.devstack-build"
    PKG_CONFIG_PATH="$prefix/lib/pkgconfig" "$source/configure" --prefix="$prefix" --enable-shared --disable-static "$@"
    make -j "$jobs"
    make install
    # Run the suite after install: some DSO-based tests resolve their driver
    # directory from the install prefix, which does not exist before this point.
    run_check_suite "${source##*/}" make check
}

build_cmake() {
    local source="$1" prefix="$2"
    shift 2
    # Older projects pin a pre-3.5 cmake_minimum_required, which CMake 4 refuses
    # unless the policy floor is set explicitly.
    cmake -S "$source" -B "$source/.devstack-build" -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_SHARED_LIBS=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@"
    cmake --build "$source/.devstack-build" --parallel "$jobs"
    cmake --install "$source/.devstack-build"
    run_check_suite "${source##*/}" ctest --test-dir "$source/.devstack-build" --output-on-failure
}

build_zlib() {
    local source="$1" prefix="$2"
    cd "$source"
    ./configure --prefix="$prefix" --shared
    make -j "$jobs"
    make install
    run_check_suite zlib make test
}

create_system_pc_files() {
    local prefix="$1"
    mkdir -p "$prefix/lib/pkgconfig"
    /usr/bin/python3 - "$prefix" "$sdk" <<'PY'
import pathlib, sys

prefix, sdk = map(pathlib.Path, sys.argv[1:])
pc = prefix / "lib/pkgconfig"


def header_version(header: pathlib.Path, macro: str, fallback: str) -> str:
    try:
        for line in header.read_text(errors="ignore").splitlines():
            if line.startswith(f"#define {macro} ") and '"' in line:
                return line.split('"')[1]
    except OSError:
        pass
    return fallback


libxml_version = header_version(sdk / "usr/include/libxml2/libxml/xmlversion.h", "LIBXML_DOTTED_VERSION", "2.9.4")
libxslt_version = header_version(sdk / "usr/include/libxslt/xsltconfig.h", "LIBXSLT_DOTTED_VERSION", "1.1.0")
sqlite_version = header_version(sdk / "usr/include/sqlite3.h", "SQLITE_VERSION", "3.7.7")
libcurl_version = header_version(sdk / "usr/include/curl/curlver.h", "LIBCURL_VERSION", "7.61.0")

items = {
    "libxml-2.0": ("libxml2", libxml_version, "-lxml2", f"-I{sdk}/usr/include/libxml2"),
    "libxslt": ("libxslt", libxslt_version, "-lxslt -lxml2", f"-I{sdk}/usr/include/libxml2"),
    "libexslt": ("libexslt", libxslt_version, "-lexslt -lxslt -lxml2", f"-I{sdk}/usr/include/libxml2"),
    "libcurl": ("libcurl", libcurl_version, "-lcurl", ""),
    "sqlite3": ("sqlite3", sqlite_version, "-lsqlite3", ""),
}
for filename, (name, version, libs, cflags) in items.items():
    cflags_line = f"Cflags: {cflags}\n" if cflags else ""
    (pc / f"{filename}.pc").write_text(
        f"prefix=/usr\nName: {name}\nDescription: {name} system library\nVersion: {version}\nLibs: {libs}\n{cflags_line}",
        encoding="utf-8",
    )
PY
    # PHP's bzip2 and iconv checks only probe explicit -I directories, never
    # CPPFLAGS, so the SDK headers are staged in the dependency prefix. The
    # iconv check also requires a library file next to the header; the SDK's
    # link stub points at the system /usr/lib/libiconv.2.dylib.
    if [[ -f "$sdk/usr/include/bzlib.h" ]]; then
        cp "$sdk/usr/include/bzlib.h" "$prefix/include/bzlib.h"
    fi
    if [[ -f "$sdk/usr/include/iconv.h" ]]; then
        cp "$sdk/usr/include/iconv.h" "$prefix/include/iconv.h"
    fi
    if [[ -f "$sdk/usr/lib/libiconv.tbd" ]]; then
        cp "$sdk/usr/lib/libiconv.tbd" "$prefix/lib/libiconv.tbd"
    fi
}

build_gettext() {
    local source="$1" prefix="$2"
    mkdir -p "$source/.devstack-build"
    cd "$source/.devstack-build"
    PKG_CONFIG_PATH="$prefix/lib/pkgconfig" "$source/configure" --prefix="$prefix" --enable-shared --disable-static --disable-java --disable-csharp --without-git --disable-curses
    # Only gettext-runtime is needed: it installs libintl for PHP's gettext
    # extension. gettext-tools' bundled libtextstyle does not link on current
    # clang, and none of the packaged runtimes use msgfmt or xgettext.
    make -C gettext-runtime -j "$jobs"
    make -C gettext-runtime install
    run_check_suite gettext-runtime make -C gettext-runtime check
}

build_target() {
    local target="$1" prefix="$2"
    rm -rf "$prefix"
    mkdir -p "$prefix"
    create_system_pc_files "$prefix"
    local recipes
    recipes="$("$repository_root/scripts/dependency-lock.py" "$target")"
    [[ -n "$recipes" ]] || { echo "The dependency lock lists nothing for $target." >&2; exit 65; }
    while IFS=$'\t' read -r id version url sha256; do
        source="$work_root/$target-$id"
        fetch_and_extract "$id" "$version" "$url" "$sha256" "$source"
        case "$id" in
            apr) build_autotools "$source" "$prefix" ;;
            apr-util) build_autotools "$source" "$prefix" --with-apr="$prefix/bin/apr-1-config" --without-berkeley-db ;;
            pcre2) build_autotools "$source" "$prefix" --enable-pcre2-8 --enable-jit ;;
            nghttp2) build_cmake "$source" "$prefix" -DENABLE_LIB_ONLY=ON -DENABLE_DOC=OFF -DENABLE_TESTING=OFF ;;
            zlib) build_zlib "$source" "$prefix" ;;
            libpng) build_autotools "$source" "$prefix" --with-zlib-prefix="$prefix" ;;
            icu)
                icu_source="$source/source"
                build_autotools "$icu_source" "$prefix" --disable-samples --disable-extras
                ;;
            oniguruma) build_autotools "$source" "$prefix" ;;
            libzip) build_cmake "$source" "$prefix" -DBUILD_TOOLS=OFF -DBUILD_REGRESS=ON -DBUILD_EXAMPLES=OFF ;;
            libjpeg-turbo) build_cmake "$source" "$prefix" -DENABLE_SHARED=ON -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=OFF ;;
            freetype) build_autotools "$source" "$prefix" --with-zlib=no --with-bzip2=no --with-png=no --with-harfbuzz=no --with-brotli=no ;;
            libwebp) build_cmake "$source" "$prefix" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF ;;
            libsodium) build_autotools "$source" "$prefix" ;;
            gmp) build_autotools "$source" "$prefix" --enable-cxx ;;
            tidy) build_cmake "$source" "$prefix" -DSUPPORT_CONSOLE_APP=OFF ;;
            gettext) build_gettext "$source" "$prefix" ;;
            *) echo "No dependency recipe for $id" >&2; exit 64 ;;
        esac
    done <<< "$recipes"
}

requested="${1:-all}"
if [[ "$requested" == "all" || "$requested" == "apache" ]]; then build_target apache "$dependency_root/apache-2.4"; fi
if [[ "$requested" == "all" || "$requested" == "php" ]]; then
    build_target php "$dependency_root/php-8.5"
    for php_target in php-7.4 php-8.4; do
        # Replace the copy: copying onto an existing tree would nest php-8.5
        # inside it and leave the previous build's files in place.
        rm -rf "$dependency_root/$php_target"
        cp -R "$dependency_root/php-8.5" "$dependency_root/$php_target"
        # Rewrite the whole prefix so prefix= lines without a trailing slash
        # move too.
        /usr/bin/find "$dependency_root/$php_target" \( -name '*.pc' -o -name '*.la' -o -name '*-config' \) -type f -exec /usr/bin/sed -i '' "s|$dependency_root/php-8.5|$dependency_root/$php_target|g" {} +
        "$repository_root/scripts/prepare-build-libraries.sh" "$dependency_root/$php_target"
    done
    "$repository_root/scripts/prepare-build-libraries.sh" "$dependency_root/php-8.5"
fi

if [[ "$requested" == "all" || "$requested" == "mysql" ]]; then
    # MySQL 8.4 always includes Boost from extra/boost/boost_1_84_0 in its
    # source tree; the upstream MySQL tarball does not bundle it.
    boost_root="$dependency_root/mysql-8.4/boost/boost_1_84_0"
    rm -rf "$dependency_root/mysql-8.4"
    mysql_sources="$("$repository_root/scripts/dependency-lock.py" mysql)"
    [[ -n "$mysql_sources" ]] || { echo "The dependency lock lists nothing for mysql." >&2; exit 65; }
    while IFS=$'\t' read -r id version url sha256; do
        fetch_and_extract "$id" "$version" "$url" "$sha256" "$boost_root"
    done <<< "$mysql_sources"
fi

if [[ -n "$dependency_test_failures" ]]; then
    echo "Dependency test suites with reported failures:$dependency_test_failures" >&2
fi

echo "Dependency output: $dependency_root"
