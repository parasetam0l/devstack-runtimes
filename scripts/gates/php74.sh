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

if [[ ! -f "$build_directory/Makefile" ]]; then
    echo "PHP source tree is unavailable; the mandatory upstream regression suite cannot run." >&2
    exit 66
fi

# Tests frozen with PHP 7.4 that assert behavior of older libraries. The
# runtime links the system libcurl (8.7, SecureTransport) and OpenSSL 3.5.8,
# so these expectations no longer hold; everything else must still pass:
#   curl: libcurl 8 error strings/errno and the removal of HTTP/2 server push
#   openssl: strict UTCTime parsing, the new codesign extension, and RSA
#     implicit rejection (OpenSSL 3.2+); SNI fixture certificates expired 2026
# Online tests (for example curl bug #78775) are skipped with --offline.
known_failures=(
    "Bug #76675 (Segfault with H2 server push write/writeheader handlers) [ext/curl/tests/bug76675.phpt]"
    "Bug #77946 (Errored cURL resources returned by curl_multi_info_read() must be compatible with curl_errno() and curl_error()) [ext/curl/tests/bug77946.phpt]"
    "Test curl_error() & curl_errno() function without url [ext/curl/tests/curl_basic_007.phpt]"
    "Test curl_error() & curl_errno() function with problematic protocol [ext/curl/tests/curl_basic_009.phpt]"
    "Bug #74341 (openssl_x509_parse fails to parse ASN.1 UTCTime without seconds) [ext/openssl/tests/bug74341.phpt]"
    "openssl_private_decrypt() tests [ext/openssl/tests/openssl_private_decrypt_basic.phpt]"
    "openssl_x509_parse() tests [ext/openssl/tests/openssl_x509_parse_basic.phpt]"
    "sni_server [ext/openssl/tests/sni_server.phpt]"
    "sni_server with separate pk and cert [ext/openssl/tests/sni_server_key_cert.phpt]"
)

suite_output="$temporary/regression-suite.log"
set +e
make -C "$build_directory" test TESTS="ext/openssl ext/curl ext/hash ext/phar" TEST_PHP_ARGS="-q --show-diff --offline" >"$suite_output" 2>&1
suite_status=$?
set -e

actual_failures="$(
    /usr/bin/python3 - "$suite_output" <<'PY'
import sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
try:
    start = next(i for i, line in enumerate(lines) if line.strip() == "FAILED TEST SUMMARY")
except StopIteration:
    raise SystemExit(0)
for line in lines[start + 2:]:
    if line.startswith("===="):
        break
    if line.strip():
        print(line.rstrip())
PY
)"
unexpected="$(
    printf '%s\n' "$actual_failures" | while IFS= read -r failure; do
        [[ -n "$failure" ]] || continue
        matched=0
        for known in "${known_failures[@]}"; do
            [[ "$failure" == "$known" ]] && { matched=1; break; }
        done
        [[ "$matched" -eq 1 ]] || printf '%s\n' "$failure"
    done
)"
if [[ -n "$unexpected" ]]; then
    echo "Unexpected PHP 7.4 regression failures:" >&2
    printf '%s\n' "$unexpected" >&2
    exit 65
fi
if [[ "$suite_status" -ne 0 && -z "$actual_failures" ]]; then
    echo "The PHP 7.4 regression suite did not run to completion:" >&2
    /usr/bin/tail -50 "$suite_output" >&2
    exit 65
fi
echo "PHP 7.4 regression suite: only documented modern-library drift failed."

for extension_name in xdebug redis imagick; do
    extension="$php_prefix/lib/php/extensions/$extension_name.so"
    [[ -f "$extension" ]] || { echo "Missing PHP 7.4 extension: $extension_name" >&2; exit 66; }
    directive="extension"
    [[ "$extension_name" == "xdebug" ]] && directive="zend_extension"
    "$php" -n -d "$directive=$extension" --ri "$extension_name" >/dev/null
done

echo "PHP 7.4/OpenSSL 3.5.8 feasibility gate passed."
