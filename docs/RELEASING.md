# Releasing runtime packs

Each runtime ships as its own **pack**: a signed archive that DevStack
downloads, verifies and installs during setup or from its Runtimes tab. A
pack release is named after the pack, for example `php-8.5-8.5.11-r1`, and
holds:

| Asset | What it is |
| --- | --- |
| `<name>.devstack-runtime` | The pack: the runtime, its SBOM and licence notices, with a manifest signed by the DevStack runtime key |
| `<name>.sbom.cdx.json` | The same SBOM, readable without unpacking |
| `pack.json` | What DevStack pins: file, SHA-256, size, the packs it requires, minimum macOS |
| `sources-*` | The exact upstream sources and patches the pack was built from |

Packs are built by the **Build runtime** GitHub Actions workflow
(`.github/workflows/build-runtime.yml`). It runs only when started by hand.
Every binary is signed with Developer ID and the pack is notarized. Before
publishing, the workflow checks the pack with DevStack's own importer, using
the keys DevStack trusts.

The repository is public, so the macOS runner minutes are free.

## One-time setup

The Developer ID certificate and the notarization password are the same as for
DevStack and SemiVPN (see their `docs/RELEASING.md` for how to create them).
In this repository's folder:

```sh
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64
```

```sh
gh secret set DEVELOPER_ID_P12_PASSWORD
```

```sh
gh secret set NOTARY_APPLE_ID
```

```sh
gh secret set NOTARY_PASSWORD
```

The runtime pack signing key is the `devstack-release-1` key that DevStack
trusts (`Sources/DevStackApp/Resources/trusted-runtime-keys.json` in the app
repository). Its private half is in the app repository's `.secrets` folder:

```sh
base64 -i ../devstack/.secrets/runtime-signing-key.raw | gh secret set RUNTIME_PACK_SIGNING_KEY
```

Optionally, require input packs to carry your Developer ID as well:

```sh
gh variable set TEAM_ID --body P7V7795SS9
```

`gh secret set NAME` without a value asks for it, so it stays out of your
shell history. Delete the exported `DeveloperID.p12` afterwards.

## Building a pack

1. GitHub → **Actions** → **Build runtime** → **Run workflow**. Pick the
   runtime and leave **Publish** off for a dry run. A dry run needs no
   secrets: it builds, runs the upstream test suites, audits, and packs with
   a throwaway key. The pack is attached to the run as an artifact.
2. Run it again with **Publish** on. It signs, packs with the DevStack
   runtime key, notarizes and publishes the release.
3. In DevStack, pin the new pack (`scripts/pin-runtime.sh` in the app
   repository) and release the app.

A runtime's inputs must already be published, because the workflow installs
them instead of rebuilding them:

| Order | Runtimes |
| --- | --- |
| 1 | `openssl-3.5`, `imagemagick-7.1`, `mailpit-1.31.1`, `phpmyadmin-5.2.3`, `composer-2.10.3` |
| 2 | `postgresql-18`, `apache-2.4`, `nginx-1.30`, `mysql-8.4`, `mysql-5.7` |
| 3 | `php-8.5`, `php-8.4`, `php-7.4` |
| 4 | `adminer-6.1.1` |

PHP 7.4 and MySQL 5.7 publish only when their feasibility gate passes.

## Updating a runtime

- **New upstream version:** update its `version`, `source.url` and
  `source.sha256` in `locks/runtime-lock.json`, and set `packRevision` back to
  1. `scripts/verify-sources.sh` checks the new hash.
- **Rebuild of the same version** (a packaging fix, a newer dependency):
  raise its `packRevision`. A published release is never replaced; the
  workflow refuses to overwrite one.

Then build the pack as above.

## Building on a Mac instead

The free runner has 3 cores, 7 GB of memory, 14 GB of disk and a 6-hour limit
per job. If a runtime outgrows it, build it on a Mac with the same scripts
(see `docs/BUILDING.md`). Then sign it with Developer ID, pack it with
`scripts/pack-runtime.py`, and check the result with
`DevStackRuntimePackager verify`. Publish it with `gh release create` under
the name `scripts/ci-build-plan.py <runtime>` prints.
