# Configuration

Configuration reference for `odb_autoupgrade`: env files, variables, `au_patch.cfg` keys, and security rules.

## Precedence Levels

The following table lists all configuration sources in priority order. The same order applies in standalone and
OraDBA extension mode; levels that do not exist are skipped and logged at DEBUG.

<!-- markdownlint-disable MD013 MD060 -->
| Level | Source | Standalone | OraDBA extension |
| --- | --- | --- | --- |
| 1 | CLI options of the `au_*` script | yes | yes |
| 2 | Caller environment (shell, cron, Ansible `environment:`) | yes | yes; also includes variables exported at login by `etc/env.sh` and by `oradba_customer.conf` |
| 2a | Patch profile selected with `--profile` (parsed, allow-listed keys only) | yes | yes; also searches `${ORADBA_CONFIG_DIR}/autoupgrade/profiles` |
| 3 | Explicit env file named by `AUTOUPGRADE_ENV_FILE` (missing file is an error) | yes | yes |
| 4 | OraDBA site config `${ORADBA_CONFIG_DIR}/autoupgrade.env` (`ORADBA_ETC` as fallback) | skipped | yes, when the variable is set |
| 5 | Extension env file `${AUTOUPGRADE_BASE}/etc/autoupgrade.env` | yes | yes |
| 6 | Pin file `${AU_DOWNLOAD_FOLDER}/au_patch.env` (only `AU_PATCH`, parsed not sourced) | yes | yes |
| 7 | Built-in defaults (`au_set_defaults`) | yes | yes |
<!-- markdownlint-restore -->

The pin file wins over the profile value for `AU_PATCH`: after a download the resolved value in the pin file is the
authoritative patch list for create_home and deploy. See [doc/patch-profiles.md](patch-profiles.md).

## Evaluation Order

1. CLI options are parsed into local variables (not yet applied).
2. A snapshot of the caller environment is taken once (all names and values, no `eval`).
3. Levels 5, 4, 3 are sourced in this order (lowest first) with `set -a`.
4. The parsed profile (level 2a) is applied; its values replace file values.
5. The caller snapshot is restored - caller values win over all files and the profile.
6. Defaults are applied for all variables except `AU_PATCH` (so `AU_DOWNLOAD_FOLDER` is known).
7. The pin file is read for `AU_PATCH` if it is still unset or came from the profile.
8. CLI options are applied last.

## File Security Rules

Sourced env files (levels 3-5) are checked before sourcing. A violation is fatal (exit 1):

- The file must be a regular file (no symlinks as the target; symlinks are resolved and the target is checked).
- The file must be owned by the current user or by root (numeric UID comparison).
- The file must not be group- or world-writable.
- The containing directory must not be group- or world-writable.

The third rule means that sites with `umask 002` must run `chmod go-w etc/` and the site configuration directory
before the scripts will load them. The error message includes the exact `chmod go-w` command.

The pin file (`au_patch.env`) and patch profiles are parsed with an allow-list, never sourced. They are accepted from
transferred download folders and are treated as untrusted input.

## autoupgrade.env

`etc/autoupgrade.env` is the main site configuration file. It is not committed to git; copy from the example:

```bash
cp etc/autoupgrade.env.example etc/autoupgrade.env
chmod go-w etc/autoupgrade.env
$EDITOR etc/autoupgrade.env
```

The file is shell code sourced with `set -a`. Do not store passwords here; use `op read` at the call site.

## Environment Variables

### AutoUpgrade wrapper variables (AUTOUPGRADE_*)

<!-- markdownlint-disable MD013 MD060 -->
| Variable | Purpose | Default |
| --- | --- | --- |
| `AUTOUPGRADE_BASE` | Install root (derived from the script location; a different value in the caller environment is logged as WARN and not used) | script directory |
| `AUTOUPGRADE_ENV_FILE` | Path to an explicit env file (level 3); a missing file is an error | unset |
| `AUTOUPGRADE_PROXY` | Outbound proxy URL; `none` disables proxy | from `https_proxy` / `HTTPS_PROXY` / `http_proxy` / `HTTP_PROXY` |
| `AUTOUPGRADE_TRUSTSTORE` | Java truststore path (JKS); `none` uses the JDK default | OS truststore if found, else JDK default |
| `AUTOUPGRADE_TRUSTSTORE_PASS` | Truststore password; only passed to JVM when set | unset |
| `AUTOUPGRADE_JAVA_HOME` | JDK home to use instead of PATH or ORACLE_HOME | ORACLE_HOME JDK, then PATH |
| `AUTOUPGRADE_JAVA_OPTS` | Additional JVM options (word-split on spaces) | empty |
| `AUTOUPGRADE_JAVA_SUPPORTED` | Space-separated additional Java major versions to allow (e.g. `17 21`) | empty (allow-list is `8 11`) |
| `AUTOUPGRADE_DEBUG_SSL` | `true` adds `-Djavax.net.debug=ssl:handshake` | false |
| `AUTOUPGRADE_DRY_RUN` | `true` prints the java command line and exits 0 | false |
<!-- markdownlint-restore -->

### Template variables (AU_*)

<!-- markdownlint-disable MD013 MD060 -->
| Variable | Config key | Default | Required for mode |
| --- | --- | --- | --- |
| `AU_LOG_DIR` | `global.global_log_dir` | `${AUTOUPGRADE_BASE}/logs` | all |
| `AU_KEYSTORE` | `global.keystore` | `${AUTOUPGRADE_BASE}/keystore` | download only |
| `AU_PLATFORM` | `patch1.platform` | `LINUX.X64` | download |
| `AU_TARGET_VERSION` | `patch1.target_version` | `19` | download, create_home (without source) |
| `AU_DOWNLOAD_FOLDER` | `patch1.download_folder` | `${AUTOUPGRADE_BASE}/patches` (or `patches/<profile>` with a profile) | all |
| `AU_PATCH` | `patch1.patch` | pin file, then profile, then `RECOMMENDED` | download, create_home |
| `AU_GOLD_IMAGE` | `patch1.gold_image` | `NO` or profile value | download, create_home |
| `AU_SOURCE_HOME` | `patch1.source_home` | empty (optional) | deploy (required), create_home (optional) |
| `AU_TARGET_HOME` | `patch1.target_home` | empty | create_home (required), deploy (required) |
| `AU_SID` | `patch1.sid` | empty | deploy (required) |
| `AU_EDITION` | `patch1.home_settings.edition` | `EE` when no source home; derived from source home otherwise | create_home without source home |
| `AU_ORACLE_BASE` | `patch1.home_settings.oracle_base` | empty | create_home without source home |
| `AU_INVENTORY_LOCATION` | `patch1.home_settings.inventory_location` | from `/etc/oraInst.loc` | create_home without source home |
| `AU_INVENTORY_GROUP` | `patch1.home_settings.inventory_group` | from `/etc/oraInst.loc` | create_home without source home |
| `AU_GROUP_OSDBA` | `patch1.home_settings.osdba_group` | `dba` | create_home without source home |
| `AU_GROUP_OSOPER` | `patch1.home_settings.osoper_group` | `oper` | create_home without source home |
| `AU_GROUP_OSBACKUPDBA` | `patch1.home_settings.osbackupdba_group` | `backupdba` | create_home without source home |
| `AU_GROUP_OSDGDBA` | `patch1.home_settings.osdgdba_group` | `dgdba` | create_home without source home |
| `AU_GROUP_OSKMDBA` | `patch1.home_settings.oskmdba_group` | `kmdba` | create_home without source home |
| `AU_GROUP_OSRACDBA` | `patch1.home_settings.osracdba_group` | `racdba` | create_home without source home |
| `AU_JAR` | autoupgrade.jar path | `${AUTOUPGRADE_BASE}/jar/autoupgrade.jar` | all |
| `AU_KEYSTORE_BACKUP` | backup root for keystore archives | `${AU_KEYSTORE}_backup` | au_keystore.sh --backup |
| `AU_PROFILE_DIR` | extra directory searched for profiles before `etc/profiles/` | unset | optional |
<!-- markdownlint-restore -->

### OraDBA integration variables

<!-- markdownlint-disable MD013 MD060 -->
| Variable | Purpose |
| --- | --- |
| `ORADBA_CONFIG_DIR` | Site configuration directory; level-4 env file is `${ORADBA_CONFIG_DIR}/autoupgrade.env` |
| `ORADBA_ETC` | Legacy alias for `ORADBA_CONFIG_DIR` (accepted as fallback) |
| `ODB_AUTOUPGRADE_BASE` | Exported automatically by the OraDBA loader; same value as `AUTOUPGRADE_BASE` |
<!-- markdownlint-restore -->

## au_patch.cfg Keys per Mode

`etc/au_patch.cfg` is the unified template for all three AutoUpgrade patch modes. Lines whose variable is empty
after expansion are dropped; every dropped key is named in the output. Mandatory variables that are empty abort
the run before AutoUpgrade starts.

<!-- markdownlint-disable MD013 MD060 -->
| Mode | Mandatory | Optional (dropped when empty) |
| --- | --- | --- |
| `download` | `AU_PATCH`, `AU_PLATFORM`, `AU_TARGET_VERSION`, `AU_LOG_DIR`, `AU_DOWNLOAD_FOLDER`, `AU_KEYSTORE` | `AU_SOURCE_HOME` (must exist when set), `AU_GOLD_IMAGE` |
| `create_home` | `AU_TARGET_HOME`; also either `AU_SOURCE_HOME` or all of: `AU_ORACLE_BASE`, `AU_EDITION`, groups, inventory, target version | `AU_SOURCE_HOME`, `AU_EDITION`, `AU_ORACLE_BASE`, `AU_INVENTORY_LOCATION`, `AU_INVENTORY_GROUP`, `AU_GROUP_*` |
| `deploy` | `AU_SID`, `AU_SOURCE_HOME`, `AU_TARGET_HOME` | all `AU_GROUP_*`, `AU_EDITION`, inventory |
| `analyze` | no wrapper check; AutoUpgrade validates | - |
<!-- markdownlint-restore -->

`global.keystore` is rendered only for `-mode download`; create_home and deploy configs carry no keystore entry
because a copied auto-login keystore fails with TDE104 even in create_home mode.

The deprecated 0.5.0 templates `au_download.cfg`, `au_create_home.cfg` and `au_deploy.cfg` are accepted until 1.0
with a deprecation warning that names `au_patch.cfg`.

## Dropped Empty Lines

When a variable in `au_patch.cfg` is empty after expansion, `au_render_cfg` drops that line and names it in the
output. With `--dry-run` the rendered config and the list of dropped keys are printed without running AutoUpgrade.

Example - create_home with a source home (edition and groups are derived by AutoUpgrade, so their lines are dropped):

```text
[INFO] Dropped (empty): patch1.home_settings.edition (AU_EDITION)
[INFO] Dropped (empty): patch1.home_settings.osdba_group (AU_GROUP_OSDBA)
...
```

An unset variable outside the optional set still aborts the run with the variable name.
