# odb_autoupgrade

Oracle AutoUpgrade patching tooling for Oracle Database 19c, 21c and 23ai.
Runs standalone or as an OraDBA extension; the same scripts and config work in both modes.

## Prerequisites

Bash 4.2+, Java 8+, `envsubst` (package `gettext`), `expect` (keystore creation) and `curl`. Details:
[Installation](doc/installation.md#prerequisites).

## Quick Start - Standalone

```bash
# 1. Unpack anywhere, e.g. /u00/app/oracle/odb_autoupgrade
tar xzf odb_autoupgrade-0.6.0.tar.gz
cd odb_autoupgrade

# 2. Update the AutoUpgrade JAR
bin/au_update_jar.sh

# 3. Configure site settings (proxy, truststore, paths)
cp etc/autoupgrade.env.example etc/autoupgrade.env
$EDITOR etc/autoupgrade.env

# 4. Download the recommended patch set (profile selects patch list)
bin/au_run.sh --profile recommended -config etc/au_patch.cfg -patch -mode download

# 5. Verify the download
bin/au_patch_verify.sh patches/recommended

# 6. Create a new Oracle Home from the downloaded set
AU_TARGET_HOME=/u00/app/oracle/product/19.32.0.0 \
  bin/au_run.sh --profile recommended -config etc/au_patch.cfg -patch -mode create_home
```

## Quick Start - OraDBA Extension

```bash
# Install into the OraDBA local base
cd "${ORADBA_LOCAL_BASE}"
tar xzf odb_autoupgrade-0.6.0.tar.gz

# OraDBA auto-discovery loads the extension.
# Optional: enable env/alias hooks in .extension and set
#   ORADBA_EXTENSIONS_SOURCE_ETC=true

# Download with a profile using a pinned release
bin/au_run.sh --profile 19.32 -config etc/au_patch.cfg -patch -mode download
```

## Script Overview

<!-- markdownlint-disable MD013 MD060 -->
| Script | Purpose | Replaces (until 1.0) |
| --- | --- | --- |
| `bin/au_run.sh` | AutoUpgrade wrapper: Java, proxy, truststore, config render, pin write, post-run log scan | `bin/run_autoupgrade.sh` (shim) |
| `bin/au_update_jar.sh` | Download or install autoupgrade.jar; version compare, backup, checksum | `bin/update_autoupgrade.sh` (shim) |
| `bin/au_keystore.sh` | MOS keystore: create, check, re-save, backup | `bin/create_mos_keystore.sh` (shim) |
| `bin/au_check_connectivity.sh` | Pre-flight: endpoints, TLS issuer, keystore, JAR version | - |
| `bin/au_patch_pin.sh` | Write AU_PATCH pin file from patches_info.json after download | - |
| `bin/au_patch_verify.sh` | Verify a download folder against patches_info.json (size, SHA-256) | - |
| `bin/au_gen_config.sh` | Generate a per-host create_home / deploy config from au_patch.cfg | - |
| `bin/au_home_verify.sh` | Compare source and target Oracle Home (patches, binary options, groups) | - |
| `bin/au_goldimage.sh` | Self-built gold image: create, verify, manual install fallback | - |
| `bin/au_log_cleanup.sh` | Safe cleanup of AutoUpgrade global_log_dir | - |
| `bin/run_autoupgrade.sh` | Deprecation shim - use au_run.sh | removed in 1.0 |
| `bin/update_autoupgrade.sh` | Deprecation shim - use au_update_jar.sh | removed in 1.0 |
| `bin/create_mos_keystore.sh` | Deprecation shim - use au_keystore.sh | removed in 1.0 |
<!-- markdownlint-restore -->

## Feature Matrix

<!-- markdownlint-disable MD013 MD060 -->
| Function | Standalone | With OraDBA | Manual step (standalone) |
| --- | --- | --- | --- |
| Wrapper, profiles, templates, download, create_home, deploy | yes | yes | - |
| Pin, verify, keystore, JAR update, log cleanup | yes | yes | - |
| Connectivity check, gold image create and install | yes | yes | - |
| Site config directory `${ORADBA_CONFIG_DIR}` | no | yes | Use `AUTOUPGRADE_ENV_FILE` or `etc/autoupgrade.env` |
| Profile search path `${ORADBA_CONFIG_DIR}/autoupgrade/profiles` | no | yes | Set `AU_PROFILE_DIR` |
| Register new home in `oradba_homes.conf` | no | yes | Printed as manual step by au_run.sh |
| Switch environment to the new home | no | yes | Printed as manual step by au_run.sh |
| Aliases (`au`), extension hooks, integrity check | no | yes | - |
| Logging | own log files | own log files | - |
<!-- markdownlint-restore -->

## Configuration Precedence

Highest priority wins:

1. CLI options passed to the script
2. Caller environment
3. Profile selected with `--profile` (`AU_PATCH`, `AU_TARGET_VERSION`, etc.)
4. Explicit env file `AUTOUPGRADE_ENV_FILE`
5. OraDBA site config `${ORADBA_CONFIG_DIR}/autoupgrade.env` (OraDBA mode only)
6. Extension env file `etc/autoupgrade.env`
7. Pin file `${AU_DOWNLOAD_FOLDER}/au_patch.env` (only `AU_PATCH`)
8. Built-in defaults

See [doc/configuration.md](doc/configuration.md) for the full reference.

## Profiles Quick Example

A profile selects a named patch set for download, create_home and deploy in one command:

```bash
# Download pinned release RU 19.32 (zips, no gold image)
bin/au_run.sh --profile 19.32 -config etc/au_patch.cfg -patch -mode download

# Download with Oracle gold image for OL 9 builds
AU_GOLD_IMAGE=YES \
  bin/au_run.sh --profile recommended -config etc/au_patch.cfg -patch -mode download

# Create Oracle Home from the downloaded folder
AU_TARGET_HOME=/u00/app/oracle/product/19.32.0.0 \
  bin/au_run.sh --profile 19.32 -config etc/au_patch.cfg -patch -mode create_home
```

Shipped profiles in `etc/profiles/`:

- `recommended` - current Oracle recommendation, pinned to `RECOMMENDED:<x.y>` after download
- `19.32` - RU 19.32 with OPatch, OJVM, DPBP, MRP
- `cputest-example` - reproducible CPU-test with pinned MRP (replace placeholder before use)
- `21c-cspu` - 21c with CSPU (valid on Linux for 21c; replace RU version before use)

See [doc/patch-profiles.md](doc/patch-profiles.md).

## Documentation

- [Configuration](doc/configuration.md) - env files, all AU_* variables, au_patch.cfg keys
- [Patch Profiles](doc/patch-profiles.md) - profile format, shipped profiles, pinning, verification
- [Oracle Home](doc/oracle-home.md) - create_home, edition, OS groups, gold image, naming
- [Keystore and JAR](doc/keystore-and-jar.md) - MOS keystore, auto-login, JAR update flow
- [Log Cleanup](doc/log-cleanup.md) - safe cleanup of AutoUpgrade log directory
- [Proxy and Truststore](doc/proxy-and-truststore.md) - TLS inspection, proxy config, endpoints
- [Upgrade Notes 0.6.0](doc/upgrade-0.6.0.md) - migration from 0.5.0 and legacy layout
- [All docs](doc/index.md)

## Repository Layout

```text
.extension  .checksumignore  VERSION  CHANGELOG.md  README.md  LICENSE  Makefile
bin/         wrapper and tool scripts (au_*.sh) plus deprecation shims
lib/         common.sh (generic), au_lib.sh (loader), au_env.sh, au_net.sh, au_tools.sh
etc/         au_patch.cfg, au_keystore.cfg, autoupgrade.env.example, profiles/, groups/
jar/         autoupgrade.jar goes here (not committed)
patches/     downloaded patch zips and metadata (not committed)
keystore/    MOS wallet (not committed)
logs/        AutoUpgrade runtime logs (not committed)
doc/         this documentation
tests/       BATS tests
scripts/     build.sh, rename-extension.sh
```

## Renamed Scripts (since 0.5.0)

| Old name | New name |
| --- | --- |
| `bin/run_autoupgrade.sh` | `bin/au_run.sh` |
| `bin/update_autoupgrade.sh` | `bin/au_update_jar.sh` |
| `bin/create_mos_keystore.sh` | `bin/au_keystore.sh` |

The old names remain as deprecation shims and are removed in 1.0.
The 0.5.0 config templates `au_download.cfg`, `au_create_home.cfg` and `au_deploy.cfg`
are deprecated aliases for `au_patch.cfg` and are also removed in 1.0.

## License

Apache License 2.0 - see [LICENSE](LICENSE).
