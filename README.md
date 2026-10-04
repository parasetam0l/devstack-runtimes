# DevStack runtimes

The build pipeline for the server software [DevStack](https://github.com/parasetam0l/devstack) runs: web servers, PHP, databases and tools, each compiled natively for Apple Silicon from pinned, SHA-256-checked upstream sources.

Every runtime is built for macOS 15 and later in its own prefix, relocated so it runs from any folder and loads only its own libraries, and audited: ARM64 only, signed, nothing newer than its minimum macOS, and no references to the build machine or a package manager. Each pack ships with its SBOM, licence notices and the exact sources it was built from.

Built runtimes are published here as signed, notarized runtime packs that DevStack downloads during setup, one release per pack, by the hand-started **Build runtime** workflow. How to build and publish them: [docs/RELEASING.md](docs/RELEASING.md).

## Runtimes

| ID | Software | Version | Licence | Note |
| --- | --- | --- | --- | --- |
| `openssl-3.5` | OpenSSL | 3.5.8 | Apache-2.0 |  |
| `apache-2.4` | Apache HTTP Server | 2.4.68 | Apache-2.0 |  |
| `php-7.4` | PHP | 7.4.33 | PHP-3.01 | legacy, optional |
| `php-8.5` | PHP | 8.5.11 | PHP-3.01 |  |
| `mysql-5.7` | MySQL | 5.7.44 | GPL-2.0-only WITH Universal-FOSS-exception-1.0 | legacy, optional |
| `mysql-8.4` | MySQL | 8.4.11 | GPL-2.0-only WITH Universal-FOSS-exception-1.0 |  |
| `phpmyadmin-5.2.3` | phpMyAdmin | 5.2.3 | GPL-2.0-only |  |
| `mailpit-1.31.1` | Mailpit | 1.31.1 | MIT |  |
| `composer-2.10.3` | Composer | 2.10.3 | MIT |  |
| `imagemagick-7.1` | ImageMagick | 7.1.2-32 | ImageMagick |  |
| `xdebug-php74` | Xdebug (PHP extension) | 3.1.6 | Xdebug-1.03 | legacy, optional |
| `xdebug-php85` | Xdebug (PHP extension) | 3.5.3 | Xdebug-1.03 |  |
| `redis-php` | Redis (PHP extension) | 6.3.0 | PHP-3.01 |  |
| `imagick-php` | Imagick (PHP extension) | 3.8.1 | PHP-3.01 |  |
| `php-8.4` | PHP | 8.4.26 | PHP-3.01 |  |
| `xdebug-php84` | Xdebug (PHP extension) | 3.5.3 | Xdebug-1.03 |  |
| `nginx-1.30` | Nginx | 1.30.5 | BSD-2-Clause |  |
| `adminer-6.1.1` | Adminer | 6.1.1 | Apache-2.0 OR GPL-2.0-only |  |
| `postgresql-18` | PostgreSQL | 18.6 | PostgreSQL |  |

The exact source URL and SHA-256 of each one is in [`locks/runtime-lock.json`](locks/runtime-lock.json); the libraries they link against are in [`locks/dependency-lock.json`](locks/dependency-lock.json).

## Building

Requires an Apple Silicon Mac on macOS 27 with Xcode. The scripts install their own pinned build tools and use nothing from Homebrew or MacPorts.

```sh
scripts/fetch-build-tools.sh
scripts/verify-sources.sh
scripts/build-dependencies.sh all
scripts/build-runtimes.sh all
```

To build a single runtime after the dependencies: `scripts/build-runtimes.sh php-8.5`. The result is in `.build/Runtimes`. Details, test suites and the legacy gates: [docs/BUILDING.md](docs/BUILDING.md).

## Layout

| Path | Contents |
| --- | --- |
| `locks/` | Pinned sources: runtimes, the libraries they need, and the build tools |
| `scripts/` | Fetch, build, relocate, audit, SBOM and licence notices |
| `scripts/gates/` | Feasibility gates that legacy runtimes (PHP 7.4, MySQL 5.7) must pass |
| `docs/` | The build guide |

## Licences

The scripts in this repository are MIT licensed. Each runtime keeps its own licence, listed above; its notices and corresponding source travel with it.
