# Runtime build pipeline

DevStack never builds or downloads software on an installed Mac. These scripts run only on the online release machine and produce the immutable `Contents/Resources/Runtimes` payload.

The source of truth is `Sources/DevStackApp/Resources/runtime-lock.json`. Every download is HTTPS-only and SHA-256 checked before extraction. Every runtime uses an isolated prefix. `audit-runtime.sh` rejects non-ARM64 code, unsigned Mach-O files, package-manager paths, build-machine paths, and forbidden RPATHs.

Run `scripts/fetch-build-tools.sh` once per build host, then `scripts/verify-sources.sh` to download and SHA-256 check every locked artifact, then `scripts/build-dependencies.sh all` and `scripts/build-runtimes.sh all`. `scripts/package-release.sh` then runs the two feasibility gates fail-closed, rebuilds the SBOM from the final payload, signs the app, helper, and DMG, and notarizes and staples when `DEVSTACK_NOTARY_PROFILE` is set.

## Required build host

- Apple Silicon running macOS 27 with full Xcode selected by `xcode-select`.
- The pinned build tools from `Dependencies/build-tools-lock.json` (CMake, Ninja, Autoconf, Automake, GNU libtool, pkgconf) installed by `scripts/fetch-build-tools.sh` into `.build/build-tools`; they are build-host inputs and are never packaged. Put `.build/build-tools/bin` first on `PATH` before running the other scripts.
- An Apple Developer ID Application identity and notarization keychain profile for a distributable image.

No Homebrew or MacPorts prefix is accepted by the audit, even on the release machine.

## Isolated dependencies

Apache dependencies must be built into `.build/runtime-dependencies/apache-2.4`. PHP dependencies are built into `.build/runtime-dependencies/php-8.5` and copied into a separate `.build/runtime-dependencies/php-7.4` prefix, so each PHP runtime resolves its own dependency tree. Their `pkg-config` metadata must resolve only inside the corresponding prefix. The required dylibs are copied into each final runtime, keeping the shipped trees independent. The build deliberately fails if these trees are absent; it never falls back to `/opt/homebrew`, `/usr/local`, or `/opt/local`.

Every dependency is built with its upstream test suite and the results are recorded. A failing suite is reported and, unless `DEVSTACK_STRICT_TEST_SUITES=1` is set, does not stop the release so that environmental failures such as macOS iconv's UTF-7 mapping do not block it; review the build log for the recorded suites.

PHP 7.4 is copied to the final payload only after its native ARM64/OpenSSL 3.5.8 gate succeeds. MySQL 5.7 follows the same fail-closed rule. A failed legacy gate does not prevent the PHP 8.5/MySQL 8.4 product from being packaged.

The final release procedure runs all applicable upstream test suites, `DevStackCoreChecks`, the two feasibility gates, runtime auditing, nested signing, app signing, DMG signing, notarization, stapling, Gatekeeper assessment, and a network-disabled clean-machine acceptance pass.
