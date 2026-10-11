# Migration Guide: 0.5.0 to 0.6.0

Migration steps when upgrading from 0.5.0 or from the legacy `autoupgrade` repository layout.

## Script Renames

The `au_` prefix was introduced in 0.5.0. All scripts were present in 0.5.0 under their new names.
No renames happened in 0.6.0; the three deprecation shims added in 0.5.0 remain until 1.0:

| Old name (shim, until 1.0) | Current name |
| --- | --- |
| `bin/run_autoupgrade.sh` | `bin/au_run.sh` |
| `bin/update_autoupgrade.sh` | `bin/au_update_jar.sh` |
| `bin/create_mos_keystore.sh` | `bin/au_keystore.sh` |

Update scripts, cron jobs and Ansible tasks to use the new names. The shims print a deprecation warning on every
call and are removed in 1.0.

## Unified Config Template (au_patch.cfg)

`etc/au_patch.cfg` replaces the three mode-specific templates from 0.5.0. The old templates remain as deprecated
aliases until 1.0 and print a deprecation warning naming `au_patch.cfg`.

| Deprecated (until 1.0) | Replacement |
| --- | --- |
| `etc/au_download.cfg` | `etc/au_patch.cfg` |
| `etc/au_create_home.cfg` | `etc/au_patch.cfg` |
| `etc/au_deploy.cfg` | `etc/au_patch.cfg` |

Switch to `au_patch.cfg`:

```bash
# Before (0.5.0)
bin/au_run.sh -config etc/au_download.cfg -patch -mode download

# After (0.6.0)
bin/au_run.sh -config etc/au_patch.cfg -patch -mode download

# With a profile (new in 0.6.0)
bin/au_run.sh --profile recommended -config etc/au_patch.cfg -patch -mode download
```

The `au_patch.cfg` template drops lines whose variable is empty after expansion. Variables that were hard-coded
in the old templates must now come from `autoupgrade.env`, a profile, or the caller environment.

## Removed Legacy Files

The following files from the legacy `autoupgrade` repository and the 0.5.0 copies are removed in 0.6.0:

- `etc/download_RU19.20.cfg` through `etc/download_RU19.29*.cfg` (14 files) - replaced by profiles
- `etc/download_patch.cfg`, `etc/download_test.cfg` - one-off use, replaced by `AU_PATCH` in au_patch.cfg
- `etc/sample_config.cfg`, `etc/sample_setting.cfg` - regenerate with AutoUpgrade `-patch -create_sample_file`
- `etc/test.cfg` - replaced by `etc/au_keystore.cfg`
- `bin/extension_tool.sh` - extension-template example, no function
- `bin/template.sh` - old template, replaced by the OraDBA-standard template

## Removed Deprecation: etc/test.cfg

`etc/test.cfg` was the default config for `au_keystore.sh` in 0.5.0 and contained a deprecated `folder` key.
It is replaced by `etc/au_keystore.cfg`, which contains only `global.global_log_dir` and `global.keystore`.
The default config for `au_keystore.sh` is now `etc/au_keystore.cfg`.

## Bash 4.2 Requirement

bash 4.2 or later is required. This is satisfied by:

- Oracle Linux 8 and 9 (system bash)
- Homebrew bash on macOS (`brew install bash`)

The macOS system bash (3.2) is not supported. Set `BASH_PATH` or invoke scripts with the full path to bash 4.2+.

## Env Files Refused in Group-Writable Directories

Since 0.6.0, env files (levels 3-5 in the precedence chain) are refused when their containing directory is
group- or world-writable. This blocks injection attacks on systems with `umask 002`.

If the scripts refuse to load `etc/autoupgrade.env` with a message like:
"parent directory is group-writable", run:

```bash
chmod go-w etc/
chmod go-w /path/to/site/config/dir
```

OraDBA installations that keep site configs in `${ORADBA_CONFIG_DIR}` must apply the same fix.

## New Defaults

| Setting | Old default | New default | Note |
| --- | --- | --- | --- |
| Oracle edition (no source home) | none (AutoUpgrade fails) | `EE` | Wrapper sets `EE` when no source home and `AU_EDITION` unset |
| OS groups (no source home) | only `dba` (AutoUpgrade default) | all six preinstall names | Wrapper renders all six explicitly |
| Keystore config for au_keystore.sh | `etc/test.cfg` | `etc/au_keystore.cfg` | test.cfg removed |

## New Variables

The following variables are new in 0.6.0. They do not break existing configs because their lines are dropped when
they are empty:

- `AU_EDITION` - Oracle edition for create_home without source home
- `AU_ORACLE_BASE` - ORACLE_BASE for create_home without source home
- `AU_INVENTORY_LOCATION`, `AU_INVENTORY_GROUP` - inventory settings
- `AU_GROUP_OSDBA` through `AU_GROUP_OSRACDBA` - OS groups
- `AU_JAR` - autoupgrade.jar path override
- `AU_KEYSTORE_BACKUP` - keystore backup directory
- `AU_PROFILE_DIR` - extra profile search directory

## Migration from Legacy Layout

If migrating from the legacy `autoupgrade` repository (before 0.5.0):

1. The download configs (`download_RU19.*.cfg`) used the deprecated `folder` key and a second `ARM.x64` block.
   Replace them with `au_patch.cfg` and the `AU_PLATFORM` variable.

2. The `ARM.x64` casing in legacy files differs from the documented `ARM.X64` value. Use `ARM.X64` in 0.6.0.

3. `RECOMMENDED` combined with `RU:x.y` in the same patch list is rejected by AutoUpgrade 26.x. Use either
   `RECOMMENDED:<x.y>` (resolved) or an explicit `RU:x.y,...` list.

4. The `keystore/README.md` example from the legacy repository used outdated prompts. AutoUpgrade 26.x prompts
   `YES`, `NO` or `SHARED` for the auto-login question. `au_keystore.sh` handles this automatically.
