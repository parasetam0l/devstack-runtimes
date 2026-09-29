#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
runtime_root="${DEVSTACK_RUNTIME_OUTPUT:-$repository_root/.build/Runtimes}"
work_root="${DEVSTACK_BUILD_ROOT:-$repository_root/.build/runtime-work}"
php_prefix="$runtime_root/php-7.4"
php="$php_prefix/bin/php"
fpm="$php_prefix/sbin/php-fpm"
build_directory="$work_root/php-7.4/build"

[[ -x "$php" && -x "$fpm" ]] || { echo "PHP 7.4 CLI/FPM payload is missing." >&2; exit 66; }
/usr/bin/file "$php" | /usr/bin/grep -q 'arm64' || { echo "PHP 7.4 is not native ARM64." >&2; exit 65; }
"$php" -n -r '
if (PHP_VERSION !== "7.4.33") exit(10);
if (!extension_loaded("openssl")) exit(11);
if (strpos(OPENSSL_VERSION_TEXT, "OpenSSL 3.5.8") === false) exit(12);
$key = openssl_pkey_new(["private_key_type" => OPENSSL_KEYTYPE_RSA, "private_key_bits" => 2048]);
if ($key === false) exit(13);
$data = "devstack-openssl-gate";
if (!openssl_sign($data, $signature, $key, OPENSSL_ALGO_SHA256)) exit(14);
$details = openssl_pkey_get_details($key);
if (openssl_verify($data, $signature, $details["key"], OPENSSL_ALGO_SHA256) !== 1) exit(15);
'

temporary="$(mktemp -d -t devstack-php74-gate)"
trap 'rm -rf "$temporary"' EXIT
socket="$temporary/php-fpm.sock"
configuration="$temporary/php-fpm.conf"
/usr/bin/printf '%s\n' \
    '[global]' 'daemonize = no' "error_log = $temporary/error.log" \
    '[gate]' "user = $USER" 'group = staff' "listen = $socket" \
    'pm = static' 'pm.max_children = 1' > "$configuration"
"$fpm" -t -y "$configuration"

if [[ -f "$build_directory/Makefile" ]]; then
    make -C "$build_directory" test TESTS="ext/openssl ext/curl ext/hash ext/phar" TEST_PHP_ARGS="-q --show-diff"
else
    echo "PHP source tree is unavailable; the mandatory upstream regression suite cannot run." >&2
    exit 66
fi

for extension_name in xdebug redis imagick; do
    extension="$php_prefix/lib/php/extensions/$extension_name.so"
    [[ -f "$extension" ]] || { echo "Missing PHP 7.4 extension: $extension_name" >&2; exit 66; }
    directive="extension"
    [[ "$extension_name" == "xdebug" ]] && directive="zend_extension"
    "$php" -n -d "$directive=$extension" --ri "$extension_name" >/dev/null
done

echo "PHP 7.4/OpenSSL 3.5.8 feasibility gate passed."
