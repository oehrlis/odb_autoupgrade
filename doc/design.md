# odb_autoupgrade - Phase 2 Design

Status: approved 2026-10-09 (Phase 2, consolidation and refactor). Scope of this document is design only - no
code changes are part of it.

Evidence conventions used below:

- **AU facts** refers to the maintainer verification notes for AutoUpgrade 26.6 (build 26.6.260925) from Phase 1:
  `-help` / `-patch -help` output, AutoUpgrade messages and offline test runs. The notes are not published; each
  behaviour the tooling relies on is covered by a test or by Oracle documentation.
  Section numbers are given as "AU facts 9". Items marked UNVERIFIED there stay UNVERIFIED here.
- **Standard** means a rule taken 1:1 from `oradba` (core) or `odb_datasafe` (reference implementation). Where the
  two disagree or no rule exists, the point is listed under [Decisions](#decisions) instead of being
  decided here.
- Oracle documentation links are given where a feature is not covered by AU facts.

## Purpose and scope

`odb_autoupgrade` is the single repository for Oracle AutoUpgrade Patching tooling. It runs in two modes from the
same code:

- **Standalone** - unpacked anywhere (classic layout `bin/ etc/ jar/ keystore/ patches/ logs/`), no OraDBA needed
- **OraDBA extension** - installed in `${ORADBA_LOCAL_BASE}`, discovered by the OraDBA extension loader, optional
  `etc/env.sh` / `etc/aliases.sh` hooks

Functional scope:

- AutoUpgrade setup: JAR update, MOS keystore (create, check, re-save, backup)
- Patch download (RU, OPATCH, OJVM, DPBP, MRP; Oracle gold images through the Oracle Update Advisor)
- Oracle home creation out of place (`-mode create_home`), from a gold image - never from the 19.3 base release
  on RHEL/OL 9
- Out-of-place patching of databases (`-mode analyze|deploy`)
- Pre-flight checks (endpoints, TLS inspection, keystore, JAR version)
- Later (Phase 3): Ansible roles and playbooks for regular RU / MRP / CSPU patching on top of these scripts

Out of scope: database upgrades (AutoUpgrade upgrade mode), Grid Infrastructure patching, Windows.

## Inventory legacy vs target

Legacy repository: `github.com/oehrlis/autoupgrade` (read-only until Phase 5). Target: this repository at v0.5.0.
The target already carries 1:1 copies of several legacy files (marked "copied in 0.5.0").

### Legacy files

<!-- markdownlint-disable MD013 MD060 -->
| Path | Legacy | Target (v0.5.0) | Action | Reason |
| --- | --- | --- | --- | --- |
| `.github/workflows/build-init-script.yml` | no-op workflow, all steps commented out, references a `GH_PAT` secret | `ci.yml`, `release.yml` | drop | builds an `init_project.sh` that does not exist; target CI covers lint/test/release |
| `.gitignore` | ignores jar/patches/keystore/logs, `keystore.orig/` | broader list incl. `*.sso`, `*.p12`, `.autoupgrade/` | merge | take over `keystore.orig/` pattern and add keystore backup pattern (see keystore design) |
| `LICENSE` | Apache 2.0 full text | Apache 2.0 short form | keep target | same license; check whether the full text is required in the tarball (docs-writer) |
| `README.md` | structure, online/offline install, keystore, update | extension + standalone quick start | merge | offline installation and offline JAR update sections go to `doc/installation.md`; emoji headings and absolute legacy paths dropped |
| `artefacts/.gitkeep`, `artefacts/README.md` | output folder for PDFs, Excel, PPTX | - | drop | generated artefacts do not belong in a code repo; release tarball and Markdown docs replace them |
| `bin/.gitkeep` | placeholder | - | drop | not needed |
| `bin/README.md` | script descriptions | `doc/reference.md` | merge | content superseded; `update_project.sh` section dropped (see below) |
| `bin/create_mos_keystore.sh` | expect driver for `-patch -load_password` | `bin/au_keystore.sh` + shim | migrated | already ported and hardened in 0.5.0 |
| `bin/generate_pdf.sh` | Pandoc via Docker image `oehrlis/pandoc`, output to `artefacts/` | - | drop | no PDF build in the reference implementation; OraDBA core has its own `make docs-pdf` - see open question 12 |
| `bin/run_autoupgrade.sh` | wrapper: base dir, envsubst, Java 8/11 check | `bin/au_run.sh` + shim | migrated | ported with proxy/truststore fix in 0.5.0 |
| `bin/template.sh` | old script template (`log_message`, `Usage`) | - | drop | replaced by a port of `odb_datasafe/bin/template.sh` (WP3) |
| `bin/update_autoupgrade.sh` | curl download, `cmp`, backup by build.version | `bin/au_update_jar.sh` + shim | migrated | ported in 0.5.0; extended in WP5 |
| `bin/update_project.sh` | in-place update from a GitHub ZIP, preserves etc/keystore/jar/patches/logs | - | drop | replaced by `oradba_extension.sh add --update` (OraDBA) and tarball extract (standalone); the update procedure is documented in `doc/installation.md` |
| `doc/.gitkeep`, `doc/README.md`, `doc/template.md`, `doc/template.yml` | PDF document template with placeholders | `doc/*.md` | drop | placeholder content only |
| `etc/README.md` | why and how `$AUTOUPGRADE_BASE` is substituted | `doc/configuration.md` | merge | the envsubst explanation moves to the configuration doc; the `download_patch.cfg` table is obsolete |
| `etc/download_RU19.20.cfg` ... `etc/download_RU19.29*.cfg` (14 files) | one file per RU, x86 and ARM blocks | copied in 0.5.0 | drop | use the deprecated `folder` key (AU facts 9: `FOLDER_DEPRECATED`, fatal together with `download_folder`); several combine `RECOMMENDED` with `RU:x.y`, which 26.x rejects (AU facts 2, `PCB_RECOMMENDED_VERSION_MISMATCH`); `ARM.x64` casing differs from the documented `ARM.X64` value. Replaced by `etc/au_download.cfg` with `AU_PATCH` / `AU_PLATFORM` |
| ARM download blocks (`patch2.platform=ARM.x64` in several files) | second prefix per file | - | drop | covered by `AU_PLATFORM=ARM.X64` on the generic template (AU facts 2: platform values, `patch1.platform` defaults to the host platform). MRP is Linux x86-64 only and is rejected on ARM (AU facts 2) - documented, no separate template |
| `etc/download_patch.cfg`, `etc/download_test.cfg` | one-off patch numbers, `folder` key, dummy `target_home` | copied in 0.5.0 | drop | one-off use; `AU_PATCH` accepts patch numbers (AU facts 2) |
| `etc/sample_config.cfg` | AU 25.3 upgrade-mode sample (contains a workstation hostname) | copied in 0.5.0 | drop | upgrade mode is out of scope; regenerate on demand with `-patch -create_sample_file config` (AU facts 4) |
| `etc/sample_setting.cfg` | AU 25.3 internal settings sample | copied in 0.5.0 | drop | regenerate with `-patch -create_sample_file settings` (AU facts 8) |
| `etc/test.cfg` | minimal config used to open the keystore console | copied in 0.5.0, default `AU_CFG` of `au_keystore.sh` | drop after replacement | contains the deprecated `folder` key and a dummy home; replaced by `etc/au_keystore.cfg` (global keys only) in WP6 |
| `fonts/*.otf`, `fonts/*.ttf`, `fonts/README.md`, `fonts/.gitkeep` | commercial typefaces for the PDF build | - | drop | redistribution license unclear for a public repo; not needed without the PDF build |
| `images/*.png`, `images/README.md`, `images/.gitkeep` | a corporate brand logo | - | drop | third-party brand asset, not to be redistributed |
| `jar/README.md` | folder purpose | `jar/README.md` | merge | keep target version, add backup naming (WP5) |
| `logs/.ap_build` | AutoUpgrade runtime file committed to git | - | drop | runtime data, not migrated |
| `patches/README.md` | folder purpose | `patches/README.md` | merge | add the "copy the whole folder incl. JSON files" rule (AU facts 7) |
| `keystore/README.md` (deleted in the last legacy commit, content in history) | example `-load_password` session, git exclusion | `doc/proxy-and-truststore.md` (partial) | merge | session example is valuable but outdated: 26.x prompts `YES`, `NO` or `SHARED` and uses `group mos` (AU facts 5); the absolute path in the example is not copied |
| `notes/`, `sql/` (deleted in history) | placeholders | - | drop | no content |
<!-- markdownlint-restore -->

### Target files without legacy counterpart

<!-- markdownlint-disable MD013 MD060 -->
| Path | Action | Reason |
| --- | --- | --- |
| `.extension` | fix | `provides.sql` and `provides.rcv` are `true` but there is no `sql/` or `rcv/`; add `doc: true` like `odb_datasafe`; generic description |
| `.checksumignore` | extend | add keystore backup directory and generated configs (see below) |
| `.markdownlint.yaml` | keep | see open question 12 |
| `bin/au_run.sh`, `bin/au_check_connectivity.sh`, `bin/au_keystore.sh`, `bin/au_update_jar.sh` | refactor | onto the common library and template (WP2-WP6) |
| `bin/run_autoupgrade.sh`, `bin/update_autoupgrade.sh`, `bin/create_mos_keystore.sh` | keep | deprecation shims until 1.0 (Phase 1 decision) |
| `bin/extension_tool.sh` | drop | extension-template example, no function |
| `lib/common.sh` | replace | template stub; replaced by the port of `odb_datasafe/lib/common.sh` (WP1) |
| `lib/au_lib.sh` | split | becomes the loader plus AutoUpgrade modules (WP1) |
| `etc/au_download.cfg`, `etc/au_create_home.cfg`, `etc/au_deploy.cfg` | keep | generic templates from 0.5.0 |
| `etc/autoupgrade.env.example`, `etc/odb_autoupgrade.conf.example`, `etc/env.sh`, `etc/aliases.sh` | update | precedence text, new variables |
| `scripts/build.sh`, `scripts/rename-extension.sh` | keep | same as `odb_datasafe` |
| `tests/*.bats` | restructure | `lib_*` / `script_*` / `integration_*` layout (see testing) |
| `doc/*.md` | update | Phase 4; this design is the input |
<!-- markdownlint-restore -->

## Gap analysis

Requirements are Phase 2 items 2-5 and the configuration precedence section of the project brief.

<!-- markdownlint-disable MD013 MD060 -->
| Requirement | State in v0.5.0 | Gap | Work package |
| --- | --- | --- | --- |
| Common lib for logging, env resolution, Java/proxy/truststore shared by all scripts | `lib/au_lib.sh` used by `au_run.sh` and `au_check_connectivity.sh`; `au_update_jar.sh` and `au_keystore.sh` have their own code; logging is plain `echo` | no logging API, no common option parsing, no error trap; `au_update_jar.sh` uses raw curl without the resolved proxy/truststore | WP1, WP3 |
| Scripts to standards 1:1 | OraDBA headers present; CLI parsing differs per script | adopt `odb_datasafe` template structure (`parse_common_opts`, `usage`, `validate_inputs`, `do_work`, `main`) | WP3 |
| JAR self-update: same Java/proxy handling, version compare, backup, checksum/size | download, size >= 1 MB, `PK` magic, SHA-256 print, `cmp`, backup named by `build.version` | no version compare (only byte compare), no downgrade guard, no expected checksum, no offline source, no backup retention, no keystore staleness warning | WP5 |
| Keystore: interactive create via `-patch -load_password`, auto-login option, permissions, location, portability | create via expect, `--auto-login` (`YES`, `SHARED`, `NO`), 0700/0600, symlink refusal; portability documented | no `--check`, no `--resave`, no backup before change, key pair check only in the connectivity check; default config `etc/test.cfg` is legacy | WP6 |
| Key pair detection, re-save after JAR update, warning when keystore predates JAR | connectivity check runs `mkstore -list` for `PKEY1`/`PKEY2` | no re-save flow; no age comparison | WP5, WP6 |
| Runtime data in `global_log_dir` across runs; log cleanup never removes it; wiping `logs/*` must not break later runs (tested) | identified in AU facts 7 | no cleanup tool, no test | WP8 |
| Gold image download with version pinning and checksum verification | `AU_GOLD_IMAGE` in `au_download.cfg`; pin file read by the wrapper, written by hand | automatic pin from `patches_info.json`; checksum verification of the folder; surfacing of `VDGI_*` log lines | WP7 |
| Self-built gold image (`runInstaller -createGoldImage`) and distribution | - | script and doc | WP10 |
| Gold image install on RHEL/OL 9 without 19.3 base; naming convention | `au_create_home.cfg` uses a gold image in the folder | no-source-home config generator (F10), manual silent-install fallback, naming convention | WP9, WP10 |
| Configuration precedence, standalone + OraDBA, `AUTOUPGRADE_*` compatible, `.extension` hooks | caller env > `etc/autoupgrade.env` > pin file > defaults; `AUTOUPGRADE_ENV_FILE` hard-coded | no explicit env file override, no OraDBA site level, per-file snapshot breaks multi-file precedence | WP2 |
<!-- markdownlint-restore -->

## Target architecture

### Repository layout

```text
.extension  .checksumignore  VERSION  CHANGELOG.md  README.md  LICENSE  Makefile
bin/
  au_run.sh                 wrapper: java, proxy, truststore, config render, exit code, post-run checks
  au_update_jar.sh          JAR update (online or from file), version compare, backup, checksum
  au_keystore.sh            keystore create / check / resave / backup
  au_check_connectivity.sh  pre-flight: endpoints, TLS issuer, keystore, JAR version
  au_patch_pin.sh           write the AU_PATCH pin from patches_info.json (also called by au_run.sh)
  au_patch_verify.sh        verify a download folder against patches_info.json (size, SHA-256)
  au_gen_config.sh          render a per-host create_home / deploy config (F10 groups, inventory, base)
  au_home_verify.sh         compare source and target home (binary options, groups, patches) before deploy
  au_goldimage.sh           self-built gold image: create, checksum, manual silent install fallback
  au_log_cleanup.sh         safe cleanup of global_log_dir
  template.sh               script template (port of odb_datasafe/bin/template.sh)
  run_autoupgrade.sh  update_autoupgrade.sh  create_mos_keystore.sh   deprecation shims (until 1.0)
lib/
  common.sh                 generic: logging, die, error trap, parse_common_opts, load_config, require_cmd
  au_lib.sh                 loader: sources common.sh and the au_* modules in order
  au_env.sh                 configuration precedence, defaults, config render, pin file
  au_net.sh                 Java resolution, proxy, truststore, curl wrapper
  au_tools.sh               JAR manifest, keystore helpers, patches_info.json, log scan
etc/
  au_download.cfg  au_create_home.cfg  au_create_home_nosource.cfg  au_deploy.cfg  au_keystore.cfg
  autoupgrade.env.example  odb_autoupgrade.conf.example  env.sh  aliases.sh
jar/README.md  patches/README.md  doc/  tests/  scripts/  .github/workflows/
```

Script names follow the `au_` prefix decided in Phase 1. One script per task, as in `odb_datasafe`. New names are
proposals for review; none of them is a standard.

### Library layering

The layering mirrors `odb_datasafe`: `lib/common.sh` is generic and reusable, `lib/ds_lib.sh` is a loader that
sources `common.sh` and the domain modules. Here `lib/au_lib.sh` keeps its name (scripts and tests already source
it) and becomes the loader.

- `common.sh` is a port of `odb_datasafe/lib/common.sh` with the OCI- and Python-specific parts removed
  (`PYTHONWARNINGS`, OCI CLI variables, `is_ocid`). Kept 1:1: `log`, `log_trace|debug|info|warn|error|fatal`,
  `die`, `stacktrace`, `error_handler`, `setup_error_handling`, `require_cmd`, `require_var`, `need_val`,
  `parse_common_opts`, `load_config` (with the SEC-005 checks), `confirm`, `trim_trailing_crlf`.
- Logging decision: **own logging in both modes**, exactly as `odb_datasafe` does (`uses_oradba_libs: false`,
  no call to `oradba_log`). Reasons: one code path for standalone and extension, testable without OraDBA, and the
  reference implementation does the same. `oradba_common.sh` marks `log_info`-style names as deprecated in favour of
  `oradba_log`, and the `.extension` field `uses_oradba_libs` is not read anywhere in `oradba/src` - both are open
  question 1.
- Wrapper messages go to stderr through `log_*`; AutoUpgrade stdout/stderr pass through unchanged, so the AutoUpgrade
  exit code and console output stay intact.
- `au_env.sh` - `au_load_config` (precedence below), `au_set_defaults`, `au_check_cfg_vars`, `au_render_cfg`
  (envsubst restricted to referenced variables, as in 0.5.0), `au_read_pin`.
- `au_net.sh` - `au_resolve_java` (refuse major > 21, AU facts 1: `MAX_SUPPORTED_JAVA_VERSION = 21`; default
  allow-list stays `8 11` per the Upgrade Guide, 17/21 opt-in through `AUTOUPGRADE_JAVA_SUPPORTED`),
  `au_build_proxy_opts` (exports lowercase `https_proxy`, the only proxy variable AutoUpgrade reads, AU facts 8),
  `au_resolve_truststore`, `au_build_jvm_opts`, and new `au_curl` (same proxy and CA source for curl: `--proxy`
  from the resolved proxy, `--cacert` from a PEM derived from a custom truststore, `--proto =https`).
- `au_tools.sh` - `au_jar_version` (manifest `Implementation-Version`, AU facts 1), `au_keystore_state`,
  `au_patches_info_*` (JSON access, see pinning), `au_log_scan` (prints `VDGI_*` and other fallback lines from
  `autoupgrade_patching.log`).

### CLI conventions

- All scripts except `au_run.sh` use `parse_common_opts` from `common.sh`: `-h|--help`, `-V|--version`,
  `-v|--verbose`, `-d|--debug`, `-q|--quiet`, `-n|--dry-run`, `--log-file`, `--no-color`.
- Scripts that delete or overwrite (`au_log_cleanup.sh`, `au_keystore.sh --resave|--force`, `au_update_jar.sh
  --force`) add `--yes`; `au_log_cleanup.sh` adds `--delete` (default is a listing). Whether every script must carry
  `--delete`/`--yes` is open question 7.
- `au_run.sh` passes its arguments to AutoUpgrade. AutoUpgrade options are single-dash words (`-config`, `-patch`,
  `-mode`, `-version`, `-debug`, `-noconsole`; AU facts 4), so `au_run.sh` accepts wrapper options only in
  `--long` form (`--dry-run`, `--env-file`, `--debug-ssl`, `--no-post-checks`) and never interprets single-dash
  tokens. This avoids the clash between `-d`/`-v` (common options) and AutoUpgrade arguments.

### Base directory and runtime data

- `AUTOUPGRADE_BASE` is the install root and is always derived from the script location (as in 0.5.0 and the
  legacy wrapper). A different value in the caller environment is reported with a WARN and not used - the library
  path must not be redirectable from the environment.
- In OraDBA mode the loader exports `ODB_AUTOUPGRADE_BASE` automatically (`<NAME>_BASE`, `oradba/src/lib/extensions.sh`);
  `etc/env.sh` keeps `AUTOUPGRADE_BASE` as an alias for backward compatibility.
- Runtime data roots stay configurable through the existing variables `AU_LOG_DIR`, `AU_KEYSTORE`,
  `AU_DOWNLOAD_FOLDER` (defaults below `AUTOUPGRADE_BASE`). New: `AU_JAR` (default `${AUTOUPGRADE_BASE}/jar/autoupgrade.jar`)
  and `AU_KEYSTORE_BACKUP` (default `${AU_KEYSTORE}.backup`).
- OraDBA extension update (`oradba_extension.sh add --update`, `oradba/src/bin/oradba_extension.sh`) removes and
  replaces only `bin sql rcv etc lib`; `keystore/`, `patches/`, `logs/`, `jar/` survive. Two side effects matter:
  the update first copies the whole extension with `cp -R` into a backup directory (keystore and multi-GB patch
  zips included), and files in `etc/` survive only if they match its preserve list (`*.env` yes, `*.cfg` no). Where
  runtime data and site configs should live in OraDBA mode is open question 8.

### Configuration templates

- `au_download.cfg`, `au_create_home.cfg`, `au_deploy.cfg` stay as in 0.5.0 (variables only, one `AU_PATCH`).
- New `au_create_home_nosource.cfg` for hosts without an installed source home (new RHEL/OL 9 host): adds
  `platform`, `target_version`, `home_settings.oracle_base`, `home_settings.edition`,
  `home_settings.inventory_location`, `home_settings.inventory_group` and the six `home_settings.os*_group` keys
  (AU facts 9 and 10: exact key names, required when `source_home` is absent). A separate template is needed because
  the envsubst guard aborts on unset variables, so optional keys cannot live in the source-home template.
- New `au_keystore.cfg` with only `global.global_log_dir` and `global.keystore` (keystore must not equal
  `global_log_dir`, AU facts 5) - replaces `etc/test.cfg` as the console config.

### Config generator (F10)

`au_gen_config.sh` renders a static, per-host config that needs no further envsubst.

- **With a source home** AutoUpgrade derives OS groups from `<source_home>/rdbms/lib/config.c`
  (`ParseConfigC`, regex `#define %s "(\w*)"`), ORACLE_BASE from `bin/orabase`, the edition and the binary options
  natively (AU facts 11). The generator then only fills `sid`, homes and folder; it does not duplicate what
  AutoUpgrade derives, and it warns when the current user is not in a derived group (`IS_SOURCE_OH_GROUP_FAIL`).
- **Without a source home** (`--groups-from <config.c|home>` or `--groups-standard`):
  - reads `SS_DBA_GRP`, `SS_OPER_GRP`, `SS_BKP_GRP`, `SS_DGD_GRP`, `SS_KMT_GRP`, `SS_RAC_GRP` from a `config.c` of a
    reference home (copied file or local home) and maps them to `home_settings.osdba_group`, `osoper_group`,
    `osbackupdba_group`, `osdgdba_group`, `oskmdba_group`, `osracdba_group`
  - `--groups-standard` uses the standard group names from F11 (Phase 3 defines them)
  - inventory from `/etc/oraInst.loc` (`inventory_loc`, `inst_group`), else from options
  - checks with `id -nG` that the current user is member of every group (fails early instead of in `IS_*`)
  - binary options: optional `--binopt-from <libknlopt listing|home>` sets `home_settings.binopt.*` (AU facts 10)
- Output to stdout or `--output FILE` (mode 0600, refuses to overwrite without `--force`). `--dry-run` prints the
  config and the derivation of each value.

### Automatic AU_PATCH pinning

Problem (F7, AU facts 12 Q1 and Q5): an unversioned `RECOMMENDED` resolves to the newest RU zip found in the folder
at create_home time, and deploy checks the target home against the requested list (`THL_PATCH_MISMATCH`). The patch
list must therefore be pinned once, right after the download.

- Source: `patches_info.json` in the download folder, field `patches[].releaseUpdate` (e.g. `"19.28.0.0.0"`) of the
  RU entry; `patchId` for a cross-check (AU facts 12 Q2; exact JSON from a live run is UNVERIFIED).
- `au_patch_pin.sh` (run automatically by `au_run.sh` after a successful `-mode download`, or by hand):
  - `RECOMMENDED` becomes `RECOMMENDED:<x.y>` (accepted, AU facts 2)
  - a list with an unversioned `RU` becomes `RU:<x.y>,...`; a list that is already versioned is left alone
  - an existing pin with a different value is never overwritten silently: WARN with both values, `--force` replaces
  - version mapping: `19.28.0.0.0` -> `19.28`; for 23ai/26ai versions with a third component (`23.26.1.0.0` ->
    `23.26.1`) the mapping follows the `TYPE:NN.N[.N]` form (AU facts 2) - UNVERIFIED by a run
- Pin file `${AU_DOWNLOAD_FOLDER}/au_patch.env` stays a **parsed** file (single `AU_PATCH=` line, value pattern
  `^[A-Za-z0-9_.,:-]+$`, owner and permission checks) and is never sourced - it travels with transferred folders and
  is untrusted input (Phase 1 security finding).
- JSON access: `jq` if present, else `python3 -I` with an inline reader, else WARN that names the manual command;
  the dependency choice is open question 10.

### Checksum verification

`au_patch_verify.sh <folder>` checks every file listed in `patches_info.json` (`files[].name`, `size`, SHA-256) with
`sha256sum` or `shasum -a 256`. The key name of the SHA-256 field is not confirmed (AU facts 12 lists `SHA-256` /
`checksum-256`); the reader accepts both and fails if neither is present. It also checks that the metadata files
`bug-map.json` / `aru-bug-map.json` and `patches_info.json` exist, because create_home and deploy need them (AU facts 7:
`APPLY_RU_BUG_MAP_FILE_REQUIRED`). Files in the folder that are not listed are named in the output (no silent skip).
For self-built gold images `au_goldimage.sh` writes `<zip>.sha256` next to the zip.

### Keystore flow

`au_keystore.sh` always runs AutoUpgrade with `-patch` (without it the jar opens the upgrade keystore, AU facts 5)
through `au_run.sh`, so Java, proxy and truststore resolution are the same as for downloads.

- `--create` (default): as in 0.5.0 - console `group mos`, `add -user <user>`, `save`, answer to
  `KSM_AUTO_LOGIN_PROMPT` with `--auto-login YES|SHARED|NO` (default YES). `add -user` creates `ARU_MAP`/`ARU_SECRET`
  and the key pair `PKEY1`/`PKEY2` (AU facts 5). Device flow (`add -no_password`) is not offered: it creates no key
  pair and makes `gold_image=AUTO|YES` fail (AU facts 3).
- `--check` (non-interactive, also used by `au_update_jar.sh` and the connectivity check):
  - directory 0700, `ewallet.p12` / `cwallet.sso` 0600, owner = current user, no symlinks; `.autoupgrade/` not
    group/world-writable (AutoUpgrade refuses it, AU facts 5)
  - key pair: `mkstore -wrl <dir> -list` or `orapki wallet display` for `PKEY1`/`PKEY2` (method UNVERIFIED against a
    real wallet, AU facts 5); if neither tool is available, WARN with the console check (`group mos`, `list`)
  - age: keystore files older than the build date of the installed JAR -> WARN "re-save required". The build date
    comes from `-version` (`build.date`); the date suffix of `Implementation-Version` (`26.6.260925`) is only a
    fallback - inferred from AU facts 1, not documented
- `--resave`: backup, then console `group mos`, `save` (recreates a missing key pair, increments `KS.SEQUENCE`,
  removes `CSI`; AU facts 5), auto-login answer, `exit`. Whether the console opens an auto-login keystore without
  the keystore password is UNVERIFIED; the script asks for the password and passes it only through the expect
  environment (as in 0.5.0).
- `--backup` and implicitly before every create/resave/force: `tar` of the keystore directory including
  `.autoupgrade/` into `${AU_KEYSTORE_BACKUP}/keystore_<yyyymmdd_hhmmss>.tgz`, umask 077, directory 0700, retention
  `--keep N` (default 5). The backup directory must be outside `AU_KEYSTORE` and outside `AU_LOG_DIR`.
- Portability: `YES` = local auto-login, bound to host and OS user; a copy fails with TDE104 "Loading auto-login
  keystore failed" - even in create_home if `global.keystore` points to it (AU facts 5, 9). `SHARED` is portable and
  therefore a credential that can be copied; `NO` cannot run with `-noconsole`. Design rule: one keystore per
  download host with `YES`; create_home and deploy configs carry no `global.keystore` (0.5.0 templates).

### JAR update flow

`au_update_jar.sh` keeps curl as the transport and uses `au_curl` (same proxy and CA source as the wrapper). The
public URL `https://download.oracle.com/otn-pub/otn_software/autoupgrade.jar` is the legacy and AU facts source.
AutoUpgrade can also fetch itself: patch keyword `AU` (part of `RECOMMENDED` and `TOOLS`, download mode only) uses
`https://download.oracle.com/otn-pub/otn_software/autoupgrade.json` (AU facts 2, 6); where that jar lands in the
download folder is UNVERIFIED, so it is supported only as `--from FILE`.

1. Source: `--url` (default above) or `--from FILE` (offline host, transferred jar, or the jar from a download folder).
2. Download into a temp file in the jar directory (same filesystem for an atomic `mv`); `trap` cleanup.
3. Sanity: size >= 1 MB, `PK` magic, `META-INF/MANIFEST.MF` readable with `unzip -p`, `Main-Class: oracle.boot.JointBoot`
   and `Implementation-Version` present (AU facts 1).
4. Checksum: print SHA-256 and size; `--sha256 <hex>` enforces an expected value (fleet pinning, F9b). Oracle does not
   publish a checksum for this jar as far as known - see risks.
5. Version compare on `Implementation-Version` (dotted numeric): equal -> no change, exit 0; older than installed ->
   refuse unless `--force` (downgrade); newer -> backup.
6. Backup: `jar/autoupgrade_<Implementation-Version>.jar` (0.5.0 naming used `build.version`; same value), timestamp
   only if no version is readable; retention `--keep N` (default 3); `chmod 0644`.
7. Verify: `au_run.sh -version` with the resolved Java (skippable with `--no-verify`).
8. Keystore staleness: run `au_keystore.sh --check`; if the keystore predates the new jar or lacks the key pair, print
   a WARN with the exact `au_keystore.sh --resave` command. The update itself still exits 0.
9. `--dry-run` prints source, versions and planned actions.

### Runtime data in global_log_dir

From AU facts 7 (download-mode run; paths for deploy mode with real SIDs UNVERIFIED):

<!-- markdownlint-disable MD013 MD060 -->
| Path (below `global_log_dir`) | Purpose | Needed across runs | Impact of loss | Cleanup rule |
| --- | --- | --- | --- | --- |
| `cfgtoollogs/patch/auto/aru/request_id_cache.json` | previous OUA gold image request ID, keyed by config hash | yes | new OUA request (time), `URD_CACHED_RESPONSE_FAILED` if stale | always keep |
| `cfgtoollogs/patch/auto/aru/*.csd` | checksum store of downloaded files | yes | files are validated or downloaded again (`DF_FILE_EXISTS` no longer applies) | always keep |
| `.ap_build` | written at the root by AutoUpgrade, purpose unknown | unknown | unknown | always keep |
| `cfgtoollogs/patch/auto/lock/` | run lock | while running | concurrent runs | never touch; cleanup refuses while an AutoUpgrade process runs |
| job directories with recovery data, `status.json`, `progress.json` | `-resume`, reporting | until the job is finished | `-resume` impossible | keep the newest `--keep-jobs N`; older only by age |
| `*.log`, `aru/*.log`, `aru/ous.log`, `config_files/`, `examiner/`, `sql/` | diagnostics | no | none | delete by age |
<!-- markdownlint-restore -->

Not under `global_log_dir` and never touched by log cleanup: the download folder (`*.zip`, `bug-map.json`,
`aru-bug-map.json`, `patches_info.json`, `au_patch.env` - create_home and deploy fail without the JSON files) and the
keystore subdirectory `.autoupgrade/` (`aru-device.tokens`, `oracle-updater.tokens`).

### Log cleanup

`au_log_cleanup.sh`:

- default is a listing of what would be deleted (`--delete` deletes, `--yes` skips the confirmation)
- `--older-than DAYS` (default 30), `--keep-jobs N` (default 3)
- refuses if the target is `/`, `$HOME`, not a directory, or has no `cfgtoollogs/` (not an AutoUpgrade log dir)
- refuses while `autoupgrade.jar` runs for the same user (`pgrep -f`), because of `lock/` and recovery data
- `find -P -xdev`: never follows symlinks, never leaves the filesystem
- preserve list as above, applied before age; every preserved file is named with the reason, and the summary
  counts deleted, preserved and skipped entries - nothing is held back silently

Test plan ("wiping `logs/*` must not break subsequent runs"):

1. BATS with a fixture tree (all paths from the table, ages set with `touch -t`): preserve list kept, age filter,
   `--keep-jobs`, refusal cases, dry-run deletes nothing, output names every preserved file.
2. Container test with the public jar, `--network none` (method of AU facts 7/9): `-mode download` creates the tree;
   `au_log_cleanup.sh --delete --yes --older-than 0`; the second run stops at the same message ("Operation requires
   MOS credentials ...") as the first - no new error.
3. Same with `rm -rf logs/*` (worst case) - same stop point.
4. Container test `-mode create_home` without source home against a staged folder: the stop point
   (`LocatePatchFiles`, "No 19.x Oracle Database Release Update file is found") is identical before and after the wipe.
5. Lab test with real MOS credentials (manual, documented, not in CI): download twice and compare `DF_FILE_EXISTS`;
   delete `aru/*.csd` and measure re-validation; gold image download twice and check reuse of the request ID.

## Gold image path

Hard constraint: on RHEL/OL 9 a new home is built from a gold image, never from the 19.3 base release. Every
automated path has a manual fallback.

### Oracle-provided gold image (Oracle Update Advisor)

- Download host config: `au_download.cfg` with `AU_GOLD_IMAGE=YES` (parameter `gold_image`, values `YES|NO|AUTO|ALL`,
  default AUTO; AU facts 3). Not to be confused with the patch keyword `GOLDIMAGE:<file>.zip`, which is exclusive and
  not allowed in download mode (AU facts 2).
- Requirements, in the order AutoUpgrade checks them (AU facts 3, 11): RU in the patch list (`RECOMMENDED` satisfies it,
  AU facts 12 Q3); target release 19, or 23+ with `gold_image.security_patch_level`; MOS username/password in the
  keystore (not device flow); key pair `PKEY1`/`PKEY2`; OUA connection (`transport.oracle.com`, plus the object storage
  host listed in `doc/proxy-and-truststore.md`); platform `LINUX.X64`; requested RU not newer than the OUA
  recommendation.
- `YES` fails hard on each missing requirement; `AUTO` falls back to plain zips with only an INFO line. On OL 9 targets
  a fallback to zips means create_home would need the base image, which the constraint forbids. Therefore: `YES` for
  downloads that feed OL 9 builds, and `au_run.sh` always prints the `VDGI_*` lines from `autoupgrade_patching.log`
  after a download (open question 11 for the default).
- Coverage: an OUA image contains BASE_IMAGE, RU, MRP (or CSPU), OCW; OJVM, DPBP, OPatch, JDK, AU and one-offs are
  downloaded separately (AU facts 3). The folder therefore holds the image plus zips; `au_patch_verify.sh` checks all.
- Version pinning: same `AU_PATCH` pin as for zips; `RECOMMENDED:<x.y>` keeps the gold image and the separate patches
  on one RU.

### Self-built gold image

Used when the Update Advisor is not reachable from any host, or when a site wants one image for all hosts.

- Build once from a patched home (created with create_home on a host where that is supported, or an existing,
  verified home): `runInstaller -createGoldImage -destinationLocation <dir> [-exclFiles <list>]`
  ([Oracle documentation](https://docs.oracle.com/cd/G11854_01/ladbi/runinstaller-creategoldimage-command.html),
  [19c setup wizard options](https://docs.oracle.com/en/database/oracle/oracle-database/19/ntdbi/setup-wizard-installation-options-for-creating-images.html)).
  `-exclFiles` excludes site files (`dbs/`, `network/admin/`, logs).
- Alternative inside AutoUpgrade: local parameter `create_gold_image` (default NO, placeholders `%RELEASE%`, `%UPDATE%`,
  `%TIMESTAMP%`, default name `db_goldimage_%RELEASE%_%UPDATE%_%TIMESTAMP%.zip`, stage `CREATE_GOLD_IMAGE`; AU facts 3,
  4). The accepted value form is UNVERIFIED; WP10 verifies it before the script offers it.
- `au_goldimage.sh --create --home <OH> --dest <dir>` wraps the OUI call, writes `<zip>.sha256` and a small manifest
  (`opatch lspatches` output, binary option listing) next to the zip. AutoUpgrade recognises gold images by content
  (`oui-patch.xml`, `PatchSearch.xml`, `.patch_storage`; AU facts 3), so the file name is free.

### Install on RHEL/OL 9

- Primary: `au_create_home_nosource.cfg` (or the source-home template on hosts that already have a 19c home) with the
  gold image in `download_folder`. create_home extracts a matching gold image automatically (stage EXTRACT,
  "Extracting Gold Image"); no match gives `APPLY_RU_NO_GOLD_IMAGE_MATCH` (AU facts 9). create_home never downloads and
  needs no keystore (AU facts 9).
- Manual fallback (`au_goldimage.sh --install`, prints and optionally runs the non-root steps): verify the checksum,
  unzip into the empty target home, run `runInstaller -silent` software-only with response parameters for
  `ORACLE_BASE`, inventory, edition and OS groups (values from `au_gen_config.sh`), then show the `root.sh` command for
  a root user ([Running OUI using a response file](https://docs.oracle.com/en/database/oracle/oracle-database/19/axdbi/running-oracle-universal-installer-using-a-response-file.html);
  the Linux x86-64 19c page has to be confirmed by docs-writer). `root.sh` is never run by the script.
- After either path: `au_home_verify.sh` (patches against `patches_info.json`, binary options, groups).

### Home naming

OraDBA has no naming convention for Oracle homes (examples in `oradba` mix `product/19.0.0/dbhome_1`, `product/19c`,
`product/19.0.0.0`). Proposal: `${ORACLE_BASE}/product/<RU in four parts>`, e.g. `product/19.32.0.0`, derived from
`releaseUpdate`. Monthly MRPs change the content of a home without changing the RU, so a second home on the same RU
needs a suffix. Open question 9. Registration of the new home in `oradba_homes.conf` (OraDBA mode) is part of the same
question.

## Configuration precedence

### Resolution order

Highest wins. The same order applies in both modes; levels that do not exist are skipped and the effective sources are
logged at DEBUG (like `_DATASAFE_CONF_FILES` in `odb_datasafe`).

<!-- markdownlint-disable MD013 MD060 -->
| Level | Source | Standalone | OraDBA extension |
| --- | --- | --- | --- |
| 1 | CLI options of the `au_*` script | yes | yes |
| 2 | caller environment | shell, cron, Ansible `environment:` | as standalone, plus variables exported at login from `${ORADBA_CONFIG_DIR}/oradba_customer.conf` and by the `etc/env.sh` hook |
| 3 | explicit env file `AUTOUPGRADE_ENV_FILE` (if set; missing file = ERROR) | yes | yes |
| 4 | OraDBA site config `${ORADBA_CONFIG_DIR}/autoupgrade.env` (`ORADBA_ETC` as fallback alias) | skipped | yes, if the variable is set |
| 5 | extension file `${AUTOUPGRADE_BASE}/etc/autoupgrade.env` | yes | yes |
| 6 | pin file `${AU_DOWNLOAD_FOLDER}/au_patch.env` (only `AU_PATCH`, parsed) | yes | yes |
| 7 | built-in defaults (`au_set_defaults`) | yes | yes |
<!-- markdownlint-restore -->

Notes on the names:

- `ORADBA_CONFIG_DIR` is the canonical OraDBA config directory; `ORADBA_ETC` is defined in `oradba_core.conf` as an
  alias for compatibility. `ORADBA_BASE` is canonical, `ORADBA_PREFIX` is deprecated (`oradba_common.sh`, CF-007).
  `odb_datasafe` reads `${ORADBA_ETC}/datasafe.conf`; this design reads `ORADBA_CONFIG_DIR` first and falls back to
  `ORADBA_ETC`.
- No OraDBA or `odb_datasafe` standard exists for an explicit env file variable (`odb_datasafe` loads
  `${ODB_DATASAFE_BASE}/.env` without an override). The design keeps the existing `AUTOUPGRADE_ENV_FILE` instead of
  introducing `ODB_AUTOUPGRADE_ENV` (open question 4).
- The OraDBA extension guide says extension configs are not auto-loaded and settings are copied into
  `oradba_customer.conf`; `odb_datasafe` auto-loads `${ORADBA_ETC}/datasafe.conf`. Level 4 follows the reference
  implementation; open question 2.
- `AUTOUPGRADE_*` variables (tool settings) and `AU_*` variables (template values) keep their names. Proxy order
  inside level 2 stays `AUTOUPGRADE_PROXY` > `https_proxy` > `HTTPS_PROXY` > `http_proxy` > `HTTP_PROXY` (0.5.0).

### Evaluation

1. Parse CLI options into local variables (not yet applied).
2. Take **one** snapshot of the caller environment (names and values, without `eval`, as in 0.5.0).
3. Source levels 5, 4, 3 in this order (lowest first) with `set -a`, each after the file checks below.
4. Restore the snapshot - caller values win over all files. One snapshot for all files is required: the 0.5.0
   per-file snapshot would let an earlier file win over a later one.
5. Apply defaults for all variables except `AU_PATCH`, so `AU_DOWNLOAD_FOLDER` is known.
6. Read the pin file for `AU_PATCH` if it is still unset; else default `RECOMMENDED`.
7. Apply CLI values.

The caller-wins rule differs from `odb_datasafe`, where files are sourced after the script defaults and override the
caller environment unless they use `: "${VAR:=...}"` (open question 3).

### Security constraints (from Phase 1)

- Sourced env files (levels 3-5) must be regular files, not group/world-writable and owned by the current user; a
  violation is fatal (exit 1). `odb_datasafe` (SEC-005) also accepts root-owned files, resolves symlinks and only
  warns and skips - the rules are to be aligned (open question 5).
- Values from files are shell code by design (sourced, same as `odb_datasafe`). Secrets are not stored in them; use
  `op read` at the call site.
- The pin file and every file that travels with a transferred download folder are parsed, never sourced.
- Config rendering substitutes only variables referenced in the cfg; unset references abort the run (0.5.0 guard).

### .extension hooks

- Both hooks stay opt-in (`load_env: false`, `load_aliases: false`; OraDBA sources them only with
  `ORADBA_EXTENSIONS_SOURCE_ETC=true` and the flag in `.extension`).
- `etc/env.sh` sets only `ODB_AUTOUPGRADE_BASE`, `AUTOUPGRADE_BASE` and `PATH`; it never sources `autoupgrade.env`.
  Reasons: login-shell speed, no site settings in every interactive shell, and the scripts read the files at runtime
  anyway.
- `etc/aliases.sh` keeps `au` and the navigation alias.
- `etc/odb_autoupgrade.conf.example` documents `ORADBA_EXT_ODB_AUTOUPGRADE_ENABLED` / `_PRIORITY` (OraDBA pattern
  `ORADBA_EXT_<NAME>_<SETTING>`) and `AUTOUPGRADE_ENV_FILE` for `oradba_customer.conf`.

## Field findings F7-F13

<!-- markdownlint-disable MD013 MD060 -->
| Finding | Native AutoUpgrade coverage | Our component | Phase |
| --- | --- | --- | --- |
| F7 single patch list for download / create_home / deploy | versioned `RECOMMENDED:<x.y>` accepted, must match RU/OJVM versions (AU facts 2); create_home picks the newest RU in the folder (AU facts 12 Q1); deploy compares patches (`THL_PATCH_MISMATCH`, Q5); gold image in the folder is extracted (AU facts 9) | one `AU_PATCH`, `au_patch_pin.sh` called by `au_run.sh`, pin parsed | 2 (WP7) |
| F8 keystore not portable, create_home without keystore, `-patch` needed | `YES` = host-bound LSSO, `SHARED` portable, TDE104 on an unreadable wallet even in create_home, `-patch` selects the patching keystore (AU facts 5, 9) | `au_keystore.sh --auto-login`, `--check`; templates without `global.keystore` (0.5.0) | 2 (WP6) |
| F9 binary options of a gold image home | with `source_home`, stage OPTIONS compares `ar -t libknlopt.a` and relinks with `ins_rdbms.mk` (AU facts 11, read from code); `THL_BINARY_OPTION_MISMATCH` only when deploy reuses an existing target home | `au_home_verify.sh` before deploy; `home_settings.binopt.*` via `au_gen_config.sh` when there is no source home | 2 (WP9), 3 |
| F9b one JAR version on all hosts | none | `au_update_jar.sh --from/--sha256`, version in the connectivity check (0.5.0); enforcement in Ansible | 2 (WP5), 3 |
| F10 OS groups from `config.c` | derived from `source_home` natively (AU facts 11); default `dba` without it | `au_gen_config.sh` for the no-source-home case | 2 (WP9) |
| F11 standard OS groups with fixed GIDs | none (groups must exist; `IS_*_GROUP_FAIL`) | Ansible role (root tasks, report-only for `oinstall` GID mismatch) | 3 |
| F12 `datapatch_summary.log` not found, stage durations | AutoUpgrade writes `status.json` / `progress.json` (AU facts 10); doubled-path bug UNVERIFIED | Phase 2: capture a real `status.json` in the lab; Phase 3: post-check on `cdb_registry_sqlpatch` / `dba_registry_sqlpatch` per container, stage durations from JSON | 3 |
| F13 deploy copies `dbs/` and `network/admin` files | patch mode has no keys for this (only `source_tns_admin_dir`, `source_ldap_admin_dir`; AU facts 10); which files are copied is UNVERIFIED | Phase 3: pre-deploy baseline, post-deploy restore of the symlink layout, invalid-object baseline, listener switch after the last DB | 3 |
<!-- markdownlint-restore -->

## Testing strategy

### Layout

Following `odb_datasafe/tests`:

- `tests/test_helper.bash` - shared helpers (temp dirs, mock PATH, fixtures)
- `tests/lib_common.bats`, `tests/lib_au_env.bats`, `tests/lib_au_net.bats`, `tests/lib_au_tools.bats`
- `tests/script_au_<name>.bats` - one file per script (existing `au_run.bats` and `au_check_connectivity.bats` are
  renamed)
- `tests/integration_*.bats` - container tests, skipped unless `AU_TEST_JAR` points to a jar and a container runtime is
  present
- `tests/template_helpers.bats`, `tests/script_template.bats` - template compliance, as in `odb_datasafe`
- `tests/fixtures/` - synthetic `patches_info.json`, `config.c`, `oraInst.loc`, `ar -t` listings, a fake
  `global_log_dir` tree; no Oracle content, no real hostnames

### Mocks

- `java` - shell stub that records its arguments and returns a configurable exit code and output (`-version`
  build lines, `-load_password` console prompts for the expect tests)
- `curl`, `mkstore`, `orapki`, `unzip`, `pgrep`, `id` - stubs on a test PATH
- a minimal jar built in the test (zip with `META-INF/MANIFEST.MF`) for manifest parsing and version compare

### Container integration

- Public `autoupgrade.jar` + JRE 8/11/21 container, `--network none` - the method used for AU facts. Covers config
  validation of all templates, the generator output, the log cleanup test plan and the Java >21 refusal.
- Oracle Database Free 23.26 container (optional, manual or nightly): gives a real instance for `-mode analyze`
  connection checks and the SQL post-checks of Phase 3. It cannot exercise RU patching (no MOS patches for Free) - it
  is not a substitute for the lab test with a licensed 19c home.

### CI

- Existing `ci.yml` (shellcheck, markdownlint, BATS) extended with `make format-check` (shfmt) and a version check, as
  in the `odb_datasafe` Makefile (`check-version`).
- New job: gitleaks on every PR.
- Container integration as a separate `workflow_dispatch` workflow (downloads the public jar; not a merge gate).

## Phase 2 plan

<!-- markdownlint-disable MD013 MD060 -->
| WP | Content | Agent | Depends on | Definition of done |
| --- | --- | --- | --- | --- |
| WP0 | this design, review by Stefan, answers to open questions | architect | - | design approved, open questions answered |
| WP1 | `lib/common.sh` port, `au_lib.sh` loader, split into `au_env.sh` / `au_net.sh` / `au_tools.sh` | shell-dev | WP0 | `lib_*.bats` green, shellcheck clean, existing tests still green |
| WP2 | configuration precedence (`au_load_config`), single snapshot, file checks, `AUTOUPGRADE_ENV_FILE`, OraDBA level | shell-dev, then security-reviewer | WP1 | BATS cover every level and every refusal; security review signed off |
| WP3 | `bin/template.sh` port; `au_run.sh` and `au_check_connectivity.sh` onto the library and template; post-run `VDGI_*` scan | shell-dev | WP1, WP2 | behaviour of 0.5.0 unchanged (tests), new options documented in `--help` |
| WP4 | legacy cleanup in target: drop the 14 `download_RU*.cfg`, `download_*`, `sample_*`, `test.cfg`, `extension_tool.sh`; fix `.extension`, `.gitignore`, `.checksumignore` | shell-dev | WP6 (keystore cfg) | no file references a dropped file (`grep`), build tarball content checked |
| WP5 | `au_update_jar.sh` flow | shell-dev | WP1, WP6 `--check` | tests for equal/older/newer/`--from`/`--sha256`/backup retention/staleness WARN |
| WP6 | `au_keystore.sh` `--check`, `--resave`, `--backup`; `etc/au_keystore.cfg` | shell-dev, then security-reviewer | WP3 | expect tests with mocked console; backup permissions tested; review signed off |
| WP7 | `au_patch_pin.sh`, `au_patch_verify.sh`, call from `au_run.sh` after download | shell-dev | WP3 | fixture tests incl. conflicting pin, missing SHA field, unlisted files named |
| WP8 | `au_log_cleanup.sh` and its test plan (BATS + container steps 2-4) | shell-dev | WP1 | all refusal cases tested; container steps pass |
| WP9 | `au_gen_config.sh`, `au_create_home_nosource.cfg`, `au_home_verify.sh` | shell-dev | WP2 | generated configs pass AU 26.6 config validation in the container |
| WP10 | `au_goldimage.sh` (create, checksum, manual install fallback); verify `create_gold_image` value form | shell-dev, architect for the AU check | WP9 | dry-run tested; real build verified once in the lab |
| WP11 | docs: `doc/configuration.md` (precedence), `doc/installation.md` (offline install and update), keystore, gold image, cleanup; CHANGELOG, VERSION | docs-writer, reviewed against AU facts | WP2-WP10 | markdownlint clean; every AutoUpgrade statement traceable to AU facts or an Oracle doc URL |
| WP12 | final review: gitleaks, no customer data, phase report | security-reviewer, architect | all | DoD of the project brief met |
<!-- markdownlint-restore -->

Order: WP0 -> WP1 -> WP2 -> WP3 -> (WP6 -> WP5, WP4) and (WP7, WP8, WP9 -> WP10) in parallel where files do not
overlap -> WP11 -> WP12. WP2 and WP6 are security-relevant and get a review before dependent work starts. Release
target: 0.6.0 (minor) at the end of Phase 2.

### Outlook

- **Phase 3 (Ansible)**: roles call the `au_*` scripts instead of re-implementing them; one download host, artefacts
  verified with `au_patch_verify.sh` before distribution; F9b JAR pinning by checksum; F11 groups; F12/F13 checks;
  Data Guard order; rollback playbook.
- **Phase 4 (docs)**: network endpoint table for network teams, troubleshooting, migration guide from the legacy layout.
- **Phase 5 (retire legacy)**: full-history secret scan of the legacy repository, reference sweep,
  archive, then delete after explicit confirmation.

## Risks

- **AutoUpgrade changes monthly.** The OUA behaviour already differed between 26.5 and 26.6 in the field. Mitigation:
  one JAR version per fleet (F9b), re-run the AU facts checks for each new jar before rollout.
- **Static evidence.** Several key behaviours are read from the jar code, not observed end to end (create_home with a
  real source home and zips, binary option relink, OUA gold image download, key pair check with `mkstore`). Mitigation:
  lab validation before the first production window; items stay marked UNVERIFIED until then.
- **Silent fallbacks.** `gold_image=AUTO` drops to zips with only an INFO line; on OL 9 that ends in an unusable folder
  at patch time. Mitigation: `YES` for OL 9 feeds and the post-run `VDGI_*` scan.
- **OraDBA extension update.** `cp -R` backup duplicates keystore and patch zips; `etc/*.cfg` site files are not in the
  preserve list. Mitigation: open question 8; report to `oradba`.
- **Credentials.** `SHARED` keystores and keystore backups are copyable credentials. Mitigation: `YES` by default,
  backups 0600/0700 outside log and patch dirs, `.checksumignore` / `.gitignore` entries.
- **No published checksum for `autoupgrade.jar`** (as far as known). Mitigation: fleet pinning by SHA-256 from the
  download host, manifest checks.
- **Toolchain dependencies.** bash 4+ (if `common.sh` is ported 1:1), `jq` or `python3`, `expect`, `unzip`, `mkstore`.
  Mitigation: `require_cmd` with clear messages, fallbacks named in the output.
- **Java.** Java above 21 is a hard stop in AU 26.6; Oracle home JDK 8 has an old `cacerts`. Mitigation: refusal in
  `au_resolve_java`, OS truststore by default (0.5.0).
- **Drift of copied library code.** `lib/common.sh` copied from `odb_datasafe` will diverge. Mitigation: record the
  source version in the header; sync check in a later phase.
- **Legacy history.** Files are copied, never imported with history (subtree or merge), so nothing from the
  legacy history reaches the public repository.

## Decisions

Open questions of the design review, decided 2026-10-09. They are binding for Phase 2.

1. Logging: own logging in `lib/common.sh` in both modes (`odb_datasafe` 1:1), `uses_oradba_libs: false`. An
   OraDBA issue asks to define or drop the field.
2. Site config: both levels - scripts read `${ORADBA_CONFIG_DIR}/autoupgrade.env` (fallback `ORADBA_ETC`), and
   settings in `oradba_customer.conf` arrive as caller environment. One file name, `autoupgrade.env`, everywhere.
3. Precedence: the caller environment wins over all files. This deviates from `odb_datasafe` on purpose (Ansible and
   cron pass values through the environment); aligning `odb_datasafe` is decided separately.
4. Explicit env file: `AUTOUPGRADE_ENV_FILE`.
5. Env file checks: owner is the current user or root; symlinks are resolved and the target is checked; not group or
   world writable; a violation is fatal.
6. Shell baseline: bash 4.2 or later (OL 8/9; Homebrew bash on macOS), `set -euo pipefail` as the first statement
   plus `setup_error_handling` from `lib/common.sh`.
7. `--delete` and `--yes` only on scripts that delete or overwrite (log cleanup, keystore re-save or force, JAR
   force); `--help`, `--dry-run` and the common options on every script. The shell rule wording is updated.
8. Runtime data: defaults below the extension directory; for OraDBA installations the documentation requires
   `AU_LOG_DIR`, `AU_KEYSTORE` and `AU_DOWNLOAD_FOLDER` outside it. An OraDBA issue covers the extension update
   (backup copies keystore and patch zips, site `etc/*.cfg` not preserved).
9. Oracle Home naming: `${ORACLE_BASE}/product/<RU in four parts>`, e.g. `product/19.32.0.0`; a second home on the
   same RU gets `_2`, `_3`. New homes are registered in `oradba_homes.conf` when OraDBA is present.
10. JSON parsing: `jq` if present, else `python3 -I`, else a WARN with the manual command.
11. `AU_GOLD_IMAGE` stays `NO` in the generic template; `YES` is documented as mandatory for downloads that feed
    OL 9 builds; `au_run.sh` prints the `VDGI_*` lines after every download.
12. Documentation tooling: `generate_pdf.sh`, fonts and images are dropped; `make docs-pdf` from OraDBA core is adopted
    only if a PDF is needed. `.markdownlint.yaml` stays until the rule and the repositories agree on one file.

The questions as originally raised:

1. `uses_oradba_libs` is set in `.extension` here and in `odb_datasafe`, but no code in `oradba/src` reads it, and
   `oradba_common.sh` marks the `log_*` names as deprecated in favour of `oradba_log`. Keep own logging (as designed),
   bridge to `oradba_log`, or define the field in OraDBA?
2. OraDBA site config: auto-read `${ORADBA_CONFIG_DIR}/autoupgrade.env` (`odb_datasafe` pattern), only settings copied
   into `oradba_customer.conf` (OraDBA extension guide), or both (as designed)? And file name `autoupgrade.env` versus a
   `.conf` name like `datasafe.conf`.
3. Precedence semantics: caller environment wins over files (0.5.0 and this design) while `odb_datasafe` lets files
   override the caller. Keep the deviation, or align one of the two repos?
4. Explicit env file variable: keep `AUTOUPGRADE_ENV_FILE`, introduce `ODB_AUTOUPGRADE_ENV`, or follow `odb_datasafe`
   (`<base>/.env`, no override)?
5. Env file checks: owner current user only, fatal, no symlinks (0.5.0) versus owner user or root, symlink resolved,
   warn and skip (`odb_datasafe` SEC-005). Which one becomes the shared rule?
6. Shell baseline: `odb_datasafe/lib/common.sh` requires bash 4.0+ and sets `set -euo pipefail` inside
   `setup_error_handling`; the project rules ask for `set -euo pipefail` as the first line and bash 3.2 compatible
   built-ins. Minimum bash version and placement of `set -euo pipefail`?
7. The project shell rule lists `--dry-run`, `--delete`, `--yes`, `--help` as required flags; `odb_datasafe`
   `parse_common_opts` has neither `--delete` nor `--yes`. Required on every script or only on destructive ones?
8. Runtime data in OraDBA mode (keystore, patches, logs, jar, generated configs): below the extension directory
   (default), or set outside it by site config, or one new base variable for all runtime data?
9. Oracle home naming: no OraDBA convention. `product/19.32.0.0` as proposed, plus a suffix for a second home on the
   same RU (MRP level or date)? Register new homes in `oradba_homes.conf` in OraDBA mode?
10. JSON parsing of `patches_info.json`: require `jq`, fall back to `python3 -I`, or both with a named manual fallback
    (as designed)?
11. Default `AU_GOLD_IMAGE` in `au_download.cfg`: keep `NO`, switch to `YES`, or `AUTO` with a mandatory log scan?
12. Documentation tooling: drop `generate_pdf.sh`, fonts and images now and adopt the OraDBA core `make docs-pdf` only if
    a PDF is needed? The repo uses `.markdownlint.yaml` (MD033 allow-list) while the markdown rule refers to
    `.markdownlint.json` with MD033 off; `odb_datasafe` ships both files. Which config is the standard?
