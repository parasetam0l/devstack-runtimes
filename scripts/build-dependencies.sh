#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cache_root="${DEVSTACK_SOURCE_CACHE:-$repository_root/.build/runtime-cache}/dependencies"
work_root="${DEVSTACK_BUILD_ROOT:-$repository_root/.build/runtime-work}/dependencies"
dependency_root="${DEVSTACK_DEPENDENCY_ROOT:-$repository_root/.build/runtime-dependencies}"
jobs="$(sysctl -n hw.logicalcpu)"
sdk="$(xcrun --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=27.0
export CFLAGS="-arch arm64 -O2"
export CXXFLAGS="-arch arm64 -O2"

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || { echo "Dependencies require Apple Silicon macOS." >&2; exit 69; }
command -v cmake >/dev/null || { echo "CMake is required on the build host." >&2; exit 69; }
command -v pkg-config >/dev/null || { echo "pkg-config is required on the build host." >&2; exit 69; }
mkdir -p "$cache_root" "$work_root" "$dependency_root"

dependency_test_failures=""

run_check_suite() {
    local component="$1"
    shift
    if "$@"; then
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
items = {
    "libxml-2.0": ("libxml2", "2.9.0", "-lxml2", f"-I{sdk}/usr/include/libxml2"),
    "libxslt": ("libxslt", "1.1.0", "-lxslt -lxml2", f"-I{sdk}/usr/include/libxml2"),
    "libexslt": ("libexslt", "0.8.0", "-lexslt -lxslt -lxml2", f"-I{sdk}/usr/include/libxml2"),
    "libcurl": ("libcurl", "8.0.0", "-lcurl", f"-I{sdk}/usr/include"),
    "sqlite3": ("sqlite3", "3.0.0", "-lsqlite3", f"-I{sdk}/usr/include"),
}
for filename, (name, version, libs, cflags) in items.items():
    (pc / f"{filename}.pc").write_text(f"prefix=/usr\nName: {name}\nVersion: {version}\nLibs: {libs}\nCflags: {cflags}\n", encoding="utf-8")
PY
}

build_target() {
    local target="$1" prefix="$2"
    rm -rf "$prefix"
    mkdir -p "$prefix"
    create_system_pc_files "$prefix"
    while IFS=$'\t' read -r id version url sha256; do
        source="$work_root/$target-$id"
        fetch_and_extract "$id" "$version" "$url" "$sha256" "$source"
        case "$id" in
            apr) build_autotools "$source" "$prefix" ;;
            apr-util) build_autotools "$source" "$prefix" --with-apr="$prefix/bin/apr-1-config" --without-berkeley-db ;;
            pcre2) build_autotools "$source" "$prefix" --enable-pcre2-8 --enable-jit ;;
            zlib) build_zlib "$source" "$prefix" ;;
            libpng) build_autotools "$source" "$prefix" --with-zlib-prefix="$prefix" ;;
            icu)
                icu_source="$source/source"
                build_autotools "$icu_source" "$prefix" --disable-samples --disable-extras
                ;;
            oniguruma) build_autotools "$source" "$prefix" ;;
            libzip) build_cmake "$source" "$prefix" -DBUILD_TOOLS=OFF -DBUILD_REGRESS=ON -DBUILD_EXAMPLES=OFF ;;
            libsodium) build_autotools "$source" "$prefix" ;;
            gmp) build_autotools "$source" "$prefix" --enable-cxx ;;
            tidy) build_cmake "$source" "$prefix" -DSUPPORT_CONSOLE_APP=OFF ;;
            gettext) build_autotools "$source" "$prefix" --disable-java --disable-csharp --without-git --disable-curses ;;
            *) echo "No dependency recipe for $id" >&2; exit 64 ;;
        esac
    done < <("$repository_root/scripts/dependency-lock.py" "$target")
}

requested="${1:-all}"
if [[ "$requested" == "all" || "$requested" == "apache" ]]; then build_target apache "$dependency_root/apache-2.4"; fi
if [[ "$requested" == "all" || "$requested" == "php" ]]; then
    build_target php "$dependency_root/php-8.5"
    cp -R "$dependency_root/php-8.5" "$dependency_root/php-7.4"
    # Point the copied pkg-config and config metadata at its own prefix so the
    # two PHP dependency trees resolve independently.
    /usr/bin/find "$dependency_root/php-7.4" \( -name '*.pc' -o -name '*-config' \) -type f -exec /usr/bin/sed -i '' 's|/php-8.5/|/php-7.4/|g' {} +
fi

if [[ -n "$dependency_test_failures" ]]; then
    echo "Dependency test suites with reported failures:$dependency_test_failures" >&2
fi

echo "Dependency output: $dependency_root"
