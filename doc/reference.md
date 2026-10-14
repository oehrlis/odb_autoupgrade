# Reference

Complete reference for `odb_autoupgrade` scripts, configuration and environment.

## Directory Structure

```text
odb_autoupgrade/
bin/
  au_run.sh                 AutoUpgrade wrapper
  au_update_jar.sh          JAR update
  au_keystore.sh            MOS keystore management
  au_check_connectivity.sh  Pre-flight connectivity check
  au_patch_pin.sh           Write AU_PATCH pin file after download
  au_patch_verify.sh        Verify download folder (size, SHA-256)
  au_gen_config.sh          Generate per-host create_home / deploy config
  au_home_verify.sh         Compare source and target Oracle Home
  au_goldimage.sh           Self-built gold image management
  au_log_cleanup.sh         Safe cleanup of global_log_dir
  run_autoupgrade.sh        Deprecation shim (removed in 1.0)
  update_autoupgrade.sh     Deprecation shim (removed in 1.0)
  create_mos_keystore.sh    Deprecation shim (removed in 1.0)
lib/
  common.sh                 Generic: logging, error trap, parse_common_opts, load_config
  au_lib.sh                 Loader: sources common.sh and au_* modules
  au_env.sh                 Configuration precedence, defaults, rendering, pin file
  au_net.sh                 Java resolution, proxy, truststore, au_curl
  au_tools.sh               JAR manifest, keystore helpers, patches_info.json, log scan
etc/
  au_patch.cfg              Unified template for download, create_home and deploy
  au_keystore.cfg           Minimal console config for au_keystore.sh
  au_download.cfg           Deprecated alias (removed in 1.0)
  au_create_home.cfg        Deprecated alias (removed in 1.0)
  au_deploy.cfg             Deprecated alias (removed in 1.0)
  autoupgrade.env.example   Site settings template
  odb_autoupgrade.conf.example  OraDBA extension config example
  env.sh                    Optional OraDBA env hook
  aliases.sh                Optional OraDBA aliases hook
  profiles/                 Shipped patch profiles
  groups/os-fixed-gid.env   Example site group profile
jar/                        Place autoupgrade.jar here (not committed)
patches/                    Downloaded patch zips and metadata (not committed)
keystore/                   MOS wallet (not committed)
logs/                       AutoUpgrade runtime logs (not committed)
doc/                        Documentation
tests/                      BATS tests
scripts/                    build.sh, rename-extension.sh
```

## Scripts

### au_run.sh

AutoUpgrade wrapper. All arguments are passed to AutoUpgrade; only `--help`, `--dry-run`, `--profile`,
`--no-pin` and `-config` are intercepted.

```text
Usage: au_run.sh [--help] [--dry-run] [--profile <name|path>] [--no-pin]
                 [-config <file>] [<autoupgrade-args>...]
```

Wrapper-only options: `--help`, `--dry-run`, `--profile <name>`, `--no-pin`.
`--dry-run` prints the rendered config to stdout and the java command line to stderr, then exits 0 without
running AutoUpgrade. Values of keys containing `pass`, `pwd`, `secret`, `token` or `credential` are shown as
`****`.
AutoUpgrade options use single-dash form (`-config`, `-patch`, `-mode`, `-help`).

### au_update_jar.sh

Download or install `autoupgrade.jar`. Compares `Implementation-Version`; refuses downgrade unless `--force`.

```text
Options: --from FILE|URL, --sha256 HEX, --keep N, --force, --yes, --no-verify
Common:  -h, -V, -v, -d, -q, -n (--dry-run)
```

### au_keystore.sh

MOS keystore management.

```text
Operations (default: --create): --create, --check, --resave, --backup
Keystore options: --workdir DIR, --cfg PATH, --mos-user, --mos-pass-file,
                  --ks-pass-file, --auto-login YES|SHARED|NO, --force, --yes,
                  --backup-dir DIR, --keep N, --insecure-argv
Common: -h, -V, -v, -d, -q, -n
```

### au_check_connectivity.sh

Pre-flight connectivity check for endpoints, TLS issuer, keystore and JAR version.

```text
Options: --keystore DIR, --endpoints FILE, --timeout N, --quiet, --dry-run
Exit codes: 0 all OK, 1 one or more FAIL, 2 only WARN
Common: -h, -V, -v, -d, -q, -n
```

### au_patch_pin.sh

Write `AU_PATCH` pin file from `patches_info.json`. Called automatically by `au_run.sh` after a download.

```text
Usage: au_patch_pin.sh [OPTIONS] [<download-folder>]
Options: --force, --yes, --resolve-mrp
Common: -h, -V, -v, -d, -q, -n
```

### au_patch_verify.sh

Verify a download folder against `patches_info.json` (size and SHA-256).

```text
Usage: au_patch_verify.sh [OPTIONS] [<download-folder>]
Common: -h, -V, -v, -d, -q
```

### au_gen_config.sh

Generate a per-host config rendered from `etc/au_patch.cfg`.

```text
Usage: au_gen_config.sh --ru <version> [OPTIONS]
Options: --source-home PATH, --oracle-base PATH, --edition EE|SE2,
         --inventory PATH, --inventory-group GRP,
         --groups-from HOME, --groups-standard, --skip-group-check,
         --output FILE, --force
Common: -h, -V, -v, -d, -q, -n
```

### au_home_verify.sh

Compare an Oracle Home against expected patches, binary options and OS groups.

```text
Usage: au_home_verify.sh --home <path> [OPTIONS]
Options: --source-home PATH, --download-folder PATH, --patches-json FILE,
         --edition EE|SE2, --no-patches, --no-binopts, --no-groups
Common: -h, -V, -v, -d, -q
```

### au_goldimage.sh

Self-built gold image management.

```text
Usage:
  au_goldimage.sh --create --home <OH> --dest <dir> [OPTIONS]
  au_goldimage.sh --verify <zip>
  au_goldimage.sh --install <zip> --target <OH> [OPTIONS]
Create options: --excl-files LIST
Install options: --target PATH, --oracle-base PATH, --edition EE|SE2,
                 --inventory PATH, --inventory-group GRP, --response FILE
Common: -h, -V, -v, -d, -q, -n
```

### au_log_cleanup.sh

Safe cleanup of AutoUpgrade `global_log_dir`.

```text
Options: --delete, --yes, --older-than DAYS, --keep-jobs N, --log-dir DIR, --log-file FILE
Common: -h, -V, -v, -d, -q, -n (--dry-run)
```

## Configuration Files

- `etc/au_patch.cfg` - unified template; see [doc/configuration.md](configuration.md)
- `etc/au_keystore.cfg` - minimal console config for `au_keystore.sh`
- `etc/autoupgrade.env.example` - copy to `etc/autoupgrade.env` and adapt

## Environment Variables

See [doc/configuration.md](configuration.md) for the complete variable table.

Key groups:

- `AUTOUPGRADE_*` - wrapper settings (proxy, truststore, Java, debug)
- `AU_*` - template values (patch, platform, paths, edition, groups)
- `ORADBA_*` - OraDBA integration (config dir, extension base)
