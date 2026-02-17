# OraDBA Autoupgrade (odb_autoupgrade)

OraDBA extension for Oracle AutoUpgrade. Ships wrapper scripts, ready-to-use
configs, and optional docs/patches/JAR layout. Can be installed as an OraDBA
extension or used standalone; build only packages the extension payload
(bin/etc/lib + metadata/docs), not the dev helpers.

## Quick Start (OraDBA Extension)

- Clone/copy this repo into `${ORADBA_LOCAL_BASE}`.
- Build tarball + checksum: `./scripts/build.sh` (outputs to `dist/`).
- Extract the tarball into `${ORADBA_LOCAL_BASE}`; auto-discovery loads
  `odb_autoupgrade`.
- Configure using `etc/` templates; scripts live in `bin/`.

## Quick Start (Standalone)

- Clone/copy this repo anywhere (e.g., `/u00/app/oracle/odb_autoupgrade`).
- Download/update the AutoUpgrade JAR: `./bin/update_autoupgrade.sh`.
- Run AutoUpgrade via wrapper:
  `./bin/run_autoupgrade.sh -config etc/download_patch.cfg -mode download`.
- Optional: add `bin/` to `PATH`.

## Structure (repo = extension)

```text
.extension                  # Extension metadata (name/version/priority/description)
README.md                   # This file
CHANGELOG.md, VERSION, LICENSE
bin/                        # Wrapper scripts (run/update autoupgrade, keystore)
etc/                        # AutoUpgrade config examples
lib/                        # Shared helpers
doc/                        # Docs for the extension
jar/                        # Place autoupgrade.jar here
patches/                    # Store patch bundles/metadata
scripts/                    # Dev tooling (build/rename)
tests/                      # BATS tests for dev tooling
.github/workflows/          # CI (lint/tests) and release
dist/                       # Build outputs (ignored)
log/                        # Logs (not packaged)
```

## Packaging

- `scripts/build.sh` reads `VERSION` and `.extension` to create
  `dist/<name>-<version>.tar.gz` plus `<tarball>.sha256`.
- Payload includes: `.extension`, `.checksumignore`,
  README/CHANGELOG/LICENSE/VERSION, bin/etc/lib/doc/jar/patches. Dev assets
  (`scripts/`, `tests/`, `.github/`, `dist/`, `.git*`) are excluded.
- Override output dir with `--dist`. Override version with `--version`.
- Build also generates `.extension.checksum` file for integrity verification.

## Integrity Checking

The `.checksumignore` file specifies patterns for files excluded from integrity checks:

- **Default exclusions**: `.extension`, `.checksumignore`, and `log/` directory
- **Glob patterns supported**: `*.log`, `keystore/`, `secrets/*.key`, etc.
- **One pattern per line**: Lines starting with `#` are comments
- **Common use cases**: credentials, caches, temporary files, user-specific configs

Example `.checksumignore`:

```text
# Exclude log directory (already default)
log/

# Credentials and secrets
keystore/
*.key
*.pem

# Cache and temporary files
cache/
*.tmp
```

When OraDBA verifies extension integrity, files matching these patterns are skipped.

## Extension Hooks (env/aliases)

This extension supports optional OraDBA etc hook files:

- `etc/env.sh`
- `etc/aliases.sh`

Current default in `.extension`:

- `load_env: false`
- `load_aliases: false`

To enable hook sourcing, set both:

1. Global switch `ORADBA_EXTENSIONS_SOURCE_ETC=true`
2. Set `load_env: true` and/or `load_aliases: true` in `.extension`

## Rename Helper

- `scripts/rename-extension.sh --name <newname> [--description "..."] [--workdir <path>]`
- Updates `.extension`, README, the sample config filename in `etc/`, and
  references to the old name (including release notes).
- Run immediately after cloning to avoid manual edits.

## CI and Releases

- CI: shellcheck for scripts, markdownlint for docs, BATS tests for helper scripts.
- Release: on tags `v*.*.*` (or manual dispatch), runs lint/tests, builds
  tarball + checksum, and publishes them as GitHub release assets.

## Using AutoUpgrade

- Download or update the JAR: `./bin/update_autoupgrade.sh` (stores in `jar/`).
- Run AutoUpgrade with wrapper:
  `./bin/run_autoupgrade.sh -config etc/download_patch.cfg -mode download`
  - Wrapper resolves configs relative to CWD or `etc/`, expands env vars with `envsubst`, and sets `AUTOUPGRADE_BASE`.
- MOS keystore: create with `create_mos_keystore.sh` and store credentials securely.

## Installation Options

- **OraDBA extension**: place in `${ORADBA_LOCAL_BASE}` and extract tarball; auto-discovery loads it.
- **Standalone**: clone/unpack anywhere, update JAR, and run via `bin/` scripts.
