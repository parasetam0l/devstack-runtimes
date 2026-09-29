# Runtime build pipeline

DevStack never builds or downloads software on an installed Mac. These scripts run only on the online release machine and produce the immutable `Contents/Resources/Runtimes` payload.

The source of truth is `Sources/DevStackApp/Resources/runtime-lock.json`. Every download is HTTPS-only and SHA-256 checked before extraction. Every runtime uses an isolated prefix. `audit-runtime.sh` rejects non-ARM64 code, unsigned Mach-O files, package-manager paths, build-machine paths, and forbidden RPATHs.

Run `scripts/build-dependencies.sh all`, then `scripts/build-runtimes.sh all`. After the builds, run `scripts/gates/php74.sh` and `scripts/gates/mysql57.sh`, followed by `scripts/package-release.sh`.

## Required build host

- Apple Silicon running macOS 27 with full Xcode selected by `xcode-select`.
- CMake, Ninja, Autoconf, Automake, libtool, and pkg-config supplied as pinned build tools; they are build-host inputs and are never packaged.
- An Apple Developer ID Application identity and notarization keychain profile for a distributable image.

No Homebrew or MacPorts prefix is accepted by the audit, even on the release machine.

## Isolated dependencies

Apache dependencies must be built into `.build/runtime-dependencies/apache-2.4`. PHP dependencies must be built independently into `.build/runtime-dependencies/php-7.4` and `.build/runtime-dependencies/php-8.5`. Their `pkg-config` metadata must resolve only inside the corresponding prefix. The required dylibs are copied into each final runtime, keeping the shipped trees independent. The build deliberately fails if these trees are absent; it never falls back to `/opt/homebrew`, `/usr/local`, or `/opt/local`.

PHP 7.4 is copied to the final payload only after its native ARM64/OpenSSL 3.5.8 gate succeeds. MySQL 5.7 follows the same fail-closed rule. A failed legacy gate does not prevent the PHP 8.5/MySQL 8.4 product from being packaged.

The final release procedure runs all applicable upstream test suites, `DevStackCoreChecks`, the two feasibility gates, runtime auditing, nested signing, app signing, DMG signing, notarization, stapling, Gatekeeper assessment, and a network-disabled clean-machine acceptance pass.
