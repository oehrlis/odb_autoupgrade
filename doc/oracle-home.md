# Oracle Home Management

Oracle Home creation, edition and OS group configuration, gold image handling,
home naming, and verification.

## create_home Mode

AutoUpgrade `-mode create_home` creates a new Oracle Home out of place from downloaded patch zips or a gold image.
It never needs a MOS keystore; `global.keystore` is not rendered in create_home configs.

### With a Source Home

When `AU_SOURCE_HOME` is set, AutoUpgrade derives the edition, `ORACLE_BASE`, and OS groups from the source home
(`rdbms/lib/config.c`). The wrapper only requires `AU_TARGET_HOME` in this case.

```bash
AU_SOURCE_HOME=/u00/app/oracle/product/19.28.0.0 \
AU_TARGET_HOME=/u00/app/oracle/product/19.32.0.0 \
  bin/au_run.sh --profile 19.32 -config etc/au_patch.cfg -patch -mode create_home
```

### Without a Source Home

Without a source home the wrapper applies edition and group defaults and checks group membership before calling
AutoUpgrade. Required variables:

- `AU_TARGET_HOME` - must not exist or must be empty
- `AU_ORACLE_BASE` - ORACLE_BASE for the new home
- `AU_EDITION` - `EE` (default when unset) or `SE2`
- OS groups - see below
- Inventory - from `/etc/oraInst.loc` or `AU_INVENTORY_LOCATION` + `AU_INVENTORY_GROUP`
- Target version - from `AU_TARGET_VERSION` or a versioned `RU:x.y` in `AU_PATCH`

On RHEL/OL 9, a new home must come from a gold image. The 19.3 base release is not supported on OL 9.
Set `AU_GOLD_IMAGE=YES` in the profile or caller environment for downloads that feed OL 9 builds.

## Edition

`AU_EDITION` maps to `patch1.home_settings.edition` (`EE` or `SE2`).

- When `AU_SOURCE_HOME` is set and `AU_EDITION` is unset: the line is dropped; AutoUpgrade derives the edition
  from the source home.
- When `AU_SOURCE_HOME` is unset and `AU_EDITION` is unset: the wrapper renders `EE`. AutoUpgrade fails with
  `IS_EDITION_FAIL` when this key is missing and there is no source home.
- An explicit `AU_EDITION` (from profile, env file or caller environment) is always rendered and overrides the
  derived value.

## OS Groups

<!-- markdownlint-disable MD013 MD060 -->
| Variable | Config key | Default (no source home) | Oracle Preinstallation RPM name |
| --- | --- | --- | --- |
| `AU_GROUP_OSDBA` | `osdba_group` | `dba` | dba |
| `AU_GROUP_OSOPER` | `osoper_group` | `oper` | oper |
| `AU_GROUP_OSBACKUPDBA` | `osbackupdba_group` | `backupdba` | backupdba |
| `AU_GROUP_OSDGDBA` | `osdgdba_group` | `dgdba` | dgdba |
| `AU_GROUP_OSKMDBA` | `oskmdba_group` | `kmdba` | kmdba |
| `AU_GROUP_OSRACDBA` | `osracdba_group` | `racdba` | racdba |
<!-- markdownlint-restore -->

The defaults match the groups that the `oracle-database-preinstall-19c` RPM creates on Oracle Linux 8 and 9
(`oinstall` 54321, `dba` 54322, `oper` 54323, `backupdba` 54324, `dgdba` 54325, `kmdba` 54326, `racdba` 54330; checked
in the RPM itself) and are documented in the
[Oracle Database 19c installation guide for Linux](https://docs.oracle.com/en/database/oracle/oracle-database/19/ladbi/creating-operating-system-privileges-groups.html).

With a source home, unset `AU_GROUP_*` lines are dropped and AutoUpgrade derives the groups from
`<source_home>/rdbms/lib/config.c`. A set `AU_GROUP_*` variable overrides the derived value.

Without a source home all six group lines are rendered. The wrapper checks with `id -nG` that the current user is
a member of every group before calling AutoUpgrade.

### Site Convention: Fixed GIDs

The `os*` group names with fixed GIDs (e.g. `osdba`, `osoper`, ...) are a site choice, not an Oracle default.
The example file `etc/groups/os-fixed-gid.env` contains the `AU_GROUP_*=os*` mappings with the GIDs documented
as comments. To use this convention, copy the relevant lines into your `autoupgrade.env`:

```bash
AU_GROUP_OSDBA=osdba
AU_GROUP_OSOPER=osoper
AU_GROUP_OSBACKUPDBA=osbackupdba
AU_GROUP_OSDGDBA=osdgdba
AU_GROUP_OSKMDBA=oskmdba
AU_GROUP_OSRACDBA=osracdba
```

Group creation with fixed GIDs is handled by the `oradba-ansible` collection. The engine only uses group names;
GIDs are site-specific and not stored in this repository.

The inventory group (`oinstall`) is not part of `AU_GROUP_*`. It comes from `/etc/oraInst.loc` or
`AU_INVENTORY_GROUP`.

## Home Naming

New homes follow the convention `${ORACLE_BASE}/product/<RU in four parts>`, for example
`product/19.32.0.0`. The four-part version comes from the `releaseUpdate` field in `patches_info.json`.

A second home on the same RU (different MRP level) gets a numeric suffix: `product/19.32.0.0_2`, `_3`, etc.

In OraDBA mode, new homes are registered in `oradba_homes.conf` automatically. In standalone mode the home path
is printed as a manual step.

## Config Generator (au_gen_config.sh)

`au_gen_config.sh` renders a static, per-host config from `etc/au_patch.cfg` and writes it to a file. The output
is a fully resolved config that needs no further variable substitution.

```bash
# With source home (groups, base, edition derived by AutoUpgrade)
bin/au_gen_config.sh --ru 19.32 \
  --source-home /u00/app/oracle/product/19.28.0.0 \
  --output /etc/autoupgrade/create_home_19.32.0.0.cfg

# Without source home (all values explicit)
bin/au_gen_config.sh --ru 19.32 \
  --oracle-base /u00/app/oracle \
  --edition EE \
  --groups-from /u00/app/oracle/product/19.28.0.0 \
  --output /etc/autoupgrade/create_home_19.32.0.0.cfg

# Using AU_GROUP_* defaults (preinstall names)
bin/au_gen_config.sh --ru 19.32 \
  --oracle-base /u00/app/oracle \
  --edition EE \
  --groups-standard \
  --output /etc/autoupgrade/create_home_19.32.0.0.cfg
```

With `--dry-run` the config and the derivation of each value are printed without writing a file.

## Home Verification (au_home_verify.sh)

`au_home_verify.sh` compares an Oracle Home against expected values before or after deploy:

- OPatch `lspatches` output vs patch IDs from `patches_info.json`
- Binary options (`ar -t rdbms/lib/libknlopt.a`) vs the source home
- OS groups (`rdbms/lib/config.c`) vs the source home or expected values
- Edition (when `--edition` is given)

```bash
bin/au_home_verify.sh \
  --home /u00/app/oracle/product/19.32.0.0 \
  --source-home /u00/app/oracle/product/19.28.0.0 \
  --download-folder patches/19.32
```

Exit 0 means all enabled checks passed; exit 1 means at least one mismatch was found with a named diff.

## deploy Mode

Out-of-place patching of a running database requires:

- `AU_SID` - database instance name
- `AU_SOURCE_HOME` - current Oracle Home
- `AU_TARGET_HOME` - the new home created by create_home

```bash
AU_SID=ORCL \
AU_SOURCE_HOME=/u00/app/oracle/product/19.28.0.0 \
AU_TARGET_HOME=/u00/app/oracle/product/19.32.0.0 \
  bin/au_run.sh --profile 19.32 -config etc/au_patch.cfg -patch -mode deploy
```

Deploy checks that the target home patch list matches the requested set (`THL_PATCH_MISMATCH`). The pin file
ensures the same `AU_PATCH` is used in all three modes.

## Gold Image Paths

### Oracle-Provided Gold Image (Oracle Update Advisor)

Set `AU_GOLD_IMAGE=YES` in the profile or caller environment. AutoUpgrade downloads the image through the Oracle
Update Advisor (OUA) during `-mode download`.

Requirements (checked in this order by AutoUpgrade):

- An RU in the patch list (`RECOMMENDED` satisfies this)
- MOS username and password in the keystore (device flow is not supported for gold images)
- Key pair `PKEY1` / `PKEY2` in the keystore
- Reachable OUA endpoint (`transport.oracle.com` and the object storage host listed in
  [doc/proxy-and-truststore.md](proxy-and-truststore.md))
- Platform `LINUX.X64`
- Requested RU not newer than the OUA recommendation
- Target release 19 or 23+

`AU_GOLD_IMAGE=YES` fails hard on each missing requirement. `AUTO` falls back to plain zips with only an INFO
line - which breaks create_home on OL 9 because the base image is required. Use `YES` for downloads that feed
OL 9 builds and check the `VDGI_*` lines in the patching log (printed automatically by `au_run.sh` after every
download).

An OUA image contains BASE_IMAGE, RU, MRP or CSPU, and OCW. OJVM, DPBP, OPatch, JDK and one-offs are downloaded
as separate zips alongside the image. `au_patch_verify.sh` checks all of them.

### Self-Built Gold Image (au_goldimage.sh)

Used when OUA is not reachable from any host, or when a site wants one image for all hosts.

Build from a patched home with `runInstaller -createGoldImage`:

```bash
# Build the image
bin/au_goldimage.sh --create \
  --home /u00/app/oracle/product/19.32.0.0 \
  --dest /opt/autoupgrade/images \
  --excl-files dbs/,network/admin/

# Verify the checksum
bin/au_goldimage.sh --verify /opt/autoupgrade/images/db_goldimage_19.32.0.0.zip
```

The script writes `<zip>.sha256` and a manifest (OPatch patch list, binary option listing) next to the zip.
AutoUpgrade recognises gold images by their content (`oui-patch.xml`, `PatchSearch.xml`, `.patch_storage`),
so the file name is free.

### Manual Install Fallback

When create_home with a gold image profile is not possible (no supported host), `au_goldimage.sh --install`
provides a manual fallback:

```bash
bin/au_goldimage.sh --install /opt/autoupgrade/images/db_goldimage_19.32.0.0.zip \
  --target /u00/app/oracle/product/19.32.0.0 \
  --oracle-base /u00/app/oracle \
  --edition EE
```

The script verifies the checksum, unzips into the target home, runs `runInstaller -silent` for software-only
installation, and prints the `root.sh` command. `root.sh` is never run by the script; it must be run separately
as root. See the
[Oracle documentation on running OUI with a response file](https://docs.oracle.com/en/database/oracle/oracle-database/19/axdbi/running-oracle-universal-installer-using-a-response-file.html).

## Not Yet Verified

These points follow from AutoUpgrade 26.6 test runs without My Oracle Support access and need a lab run before the
first production window:

- An Oracle-provided gold image (EE) used for an SE2 home (`AU_EDITION=SE2`): AutoUpgrade has no explicit check for
  this combination; whether the resulting home is a valid SE2 installation is not confirmed.
- create_home with an Oracle gold image plus a separately downloaded MRP zip (pinned MRP by patch number).
- Binary option relink in the create_home OPTIONS stage on a real source home.
- Key pair detection with `mkstore` against a real auto-login keystore (`au_keystore.sh --check` reports it as
  unverified with exit code 2 when it cannot confirm `PKEY1`/`PKEY2`).
