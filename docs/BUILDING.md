# Runtime build pipeline

These scripts run only on a build machine (a developer Mac or a CI runner) and compile every DevStack runtime into `.build/Runtimes`. DevStack itself never compiles anything on a user's Mac.

The source of truth is `locks/runtime-lock.json`. Every download is HTTPS-only and SHA-256 checked before extraction. Every runtime uses an isolated prefix. `audit-runtime.sh` rejects non-ARM64 code, unsigned Mach-O files, package-manager paths, build-machine paths, and forbidden RPATHs.

Run `scripts/fetch-build-tools.sh` once per build host, then `scripts/verify-sources.sh` to download and SHA-256 check every locked artifact, then `scripts/build-dependencies.sh all` and `scripts/build-runtimes.sh all`. Until signed runtime packs are published from this repository, the [DevStack app repository](https://github.com/parasetam0l/devstack) packages this payload into the app: its `scripts/package-release.sh` checks licence notices and sources, signs, notarizes and builds the DMG. Legacy payloads are considered only with `DEVSTACK_INCLUDE_LEGACY=1` and passing feasibility gates. Failed gates never remove staged payloads.

## Required build host

- Apple Silicon running macOS 27 with full Xcode selected by `xcode-select`.
- The pinned build tools from `locks/build-tools-lock.json` (CMake, Ninja, Autoconf, Automake, GNU libtool, pkgconf, Bison) installed by `scripts/fetch-build-tools.sh` into `.build/build-tools`; they are build-host inputs and are never packaged. The build scripts set their own `PATH` to these tools plus the system directories, so tools from a package manager never leak into a build.
- An Apple Developer ID Application identity and notarization keychain profile for a distributable image.

No Homebrew or MacPorts prefix is accepted by the audit, even on the release machine.

## Isolated dependencies

Apache dependencies must be built into `.build/runtime-dependencies/apache-2.4`. PHP dependencies are built into `.build/runtime-dependencies/php-8.5` and copied into separate `.build/runtime-dependencies/php-8.4` and `.build/runtime-dependencies/php-7.4` prefixes, so each PHP runtime resolves its own dependency tree. MySQL 8.4 requires the Boost 1.84 headers, which the dependency lock extracts into `.build/runtime-dependencies/mysql-8.4/boost/boost_1_84_0` and links into the source tree as `extra/boost/boost_1_84_0`. Their `pkg-config` metadata must resolve only inside the corresponding prefix. The required dylibs are copied into each final runtime, keeping the shipped trees independent. The build deliberately fails if these trees are absent; it never falls back to `/opt/homebrew`, `/usr/local`, or `/opt/local`.

Before PHP is configured, `prepare-build-libraries.sh` normalizes dependency install names to `@rpath` within each isolated prefix. PHP's build links against explicit build-prefix RPATHs so its configure probes, PHAR generator, and regression runner can load ICU and OpenSSL without `DYLD_*` variables. Release relocation removes these absolute build paths. Copied PHP 7.4 libtool metadata is also rewritten to its own prefix.

Every dependency is built with its upstream test suite and the results are recorded. A failing suite is reported and, unless `DEVSTACK_STRICT_TEST_SUITES=1` is set, does not stop the release so that environmental failures such as macOS iconv's UTF-7 mapping do not block it; review the build log for the recorded suites.

For a preview payload, `DEVSTACK_DEFER_TEST_SUITES=1` skips the long PHP, PHP-extension, and MySQL suites; their build directories are preserved so the suites can be re-run before release. OpenSSL's suite always runs because dependent runtimes must be built against a passing OpenSSL.

PHP 7.4 is copied to the final payload only after its native ARM64/OpenSSL 3.5.8 gate succeeds. MySQL 5.7 follows the same fail-closed rule. A failed legacy gate does not prevent the PHP 8.5/MySQL 8.4 product from being packaged.

A release runs all applicable upstream test suites, the two feasibility gates, runtime auditing, signing, notarization, and DevStack's own runtime checks against the result.

## Current development build and safe verification

The default payload includes Apache, Nginx (disabled by default), PHP 8.4/8.5, MySQL 8.4, PostgreSQL 18.6, OpenSSL, Mailpit, phpMyAdmin, Adminer, Composer and ImageMagick. ABI-specific Xdebug, Redis and Imagick modules live inside each PHP runtime. PHP 7.4 and MySQL 5.7 are currently omitted because their gates did not pass.

Packaging success is not full upstream acceptance: the release pipeline signs, notarizes and staples the image, while upstream suites and clean-machine acceptance remain separate work. Keep the packaging log as evidence; `.build/logs/package-latest.log` records the last run.

Upstream recipes now use `run-bounded-check.py`: checks run serially with a default 1,200-second wall limit, a per-process CPU limit, 1 GiB group RSS ceiling, 4 GiB limit on system wired-memory growth during the check, and process-group cleanup. PHP's own suite must pass except for the tests in `scripts/php-known-failures.txt`, each listed with the reason it fails outside the build (macOS iconv, the build machine's network and paths); PHP 7.4's suite is recorded and its legacy gate decides. `DEVSTACK_TEST_SECONDS` changes the wall limit and `DEVSTACK_TEST_RSS_MB` the memory ceiling (CI uses 4 GiB on its 7 GB runners). PHP debugger watchpoint tests are excluded from the automated host run after they caused runaway children and system memory pressure. Do not run two full PHP suites concurrently. Generated application PHP INI disables JIT; JIT regression failures remain unresolved.

Installed runtimes must never read build-machine paths. OpenSSL config/providers/certificates are explicitly supplied through `RuntimeEnvironment`; PHP FPM pools preserve that environment. ImageMagick is patched by `prepare-imagemagick.py` to honor the explicit DevStack configuration-only mode. phpMyAdmin uses an external writable configuration and temp directory through `configure-phpmyadmin.py`. MySQL clients specify no defaults/login paths and installed character-set/plug-in directories. Managed CLI wrappers use the same paths. The corresponding source payload includes both patch scripts.

Preview/release app replacements use staged directories and recoverable previous artifacts. Quit DevStack before installing a replacement; the preview installer refuses to replace a running app. Use `DEVSTACK_BUILD_JOBS=2` for modest build-host resource usage.

## PostgreSQL and PHP drivers

Build `postgresql-18` with `DEVSTACK_BUILD_JOBS=2 scripts/build-runtimes.sh postgresql-18`. The recipe uses the existing OpenSSL and ICU dependency prefixes, includes libedit support, and installs contrib extensions such as pgcrypto and citext. Then run `DEVSTACK_BUILD_JOBS=2 scripts/build-postgresql-extensions.sh` to build ABI-specific pgsql and pdo_pgsql modules from the already verified PHP 8.4/8.5 source trees. libpq is copied into each PHP runtime; relocation and runtime auditing follow. The full Adminer English build replaces the MySQL-only build.

PostgreSQL initializes a private cluster under Application Support/DevStack/Databases/postgresql-18. It binds only 127.0.0.1:5432, uses SCRAM authentication for TCP and sockets, and supports TLS using postgresql.localhost's managed certificate. Explicit shared-data, library, configuration, and client credential paths keep the shipped runtime independent of its build prefix.

SQL exports use pg_dumpall with clean/if-exists and exclude template1 and role password hashes. The managed devstack role is preserved, so restores can complete without dropping the login executing them; other roles and databases are restored by upstream SQL. Imports run through psql with ON_ERROR_STOP and are preceded by an automatic backup. SQL files can still fail when they require unavailable extensions, different privileges, or dropping databases with active external connections.

Service shutdown uses bounded process-identity polling and PostgreSQL's fast shutdown signal. There is no unbounded Foundation process wait in service shutdown or command execution. Recovery tools can stop only recorded, verified DevStack-owned processes using DevStackRuntimeChecks --stop-owned-services.
