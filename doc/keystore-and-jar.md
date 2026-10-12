# Keystore and JAR Management

MOS keystore (ewallet.p12 + cwallet.sso) and AutoUpgrade JAR lifecycle.

## MOS Keystore (au_keystore.sh)

The MOS keystore stores the Oracle Support credentials that AutoUpgrade uses to download patches. It is created
once on a designated download host. `au_keystore.sh` always calls AutoUpgrade with `-patch` through `au_run.sh`,
so Java, proxy and truststore resolution are identical to a download run.

### Create

```bash
bin/au_keystore.sh --create \
  --mos-user your.email@example.com \
  --mos-pass-file /run/secrets/mos_pass \
  --auto-login YES
```

The create flow opens the AutoUpgrade keystore console (`-patch -load_password`), runs `group mos`,
`add -user <user>`, `save`, and answers the `KSM_AUTO_LOGIN_PROMPT` with the `--auto-login` value. This creates
the MOS credential entries `ARU_MAP` / `ARU_SECRET` and the key pair `PKEY1` / `PKEY2`. The key pair is required
for Oracle gold image downloads (`AU_GOLD_IMAGE=YES`).

Device flow (`add -no_password`) is not offered because it creates no key pair, making gold image downloads fail.

### Auto-Login Modes

<!-- markdownlint-disable MD013 MD060 -->
| Mode | Value | Portability | Notes |
| --- | --- | --- | --- |
| Local auto-login | `YES` (default) | Host-bound; a copy fails with TDE104 | Recommended for download hosts |
| Shared auto-login | `SHARED` | Portable; treat as a copyable credential | Needed for multi-host setups; WARN on create |
| No auto-login | `NO` | Not portable | Requires `-noconsole` to be absent; interactive only |
<!-- markdownlint-restore -->

A `YES` keystore copied to another host or to a create_home config fails with TDE104 even in create_home mode.
The design rule is one keystore per download host; create_home and deploy configs carry no `global.keystore` entry.

### Check (non-interactive)

`--check` verifies the keystore without modifying it. It is also called by `au_update_jar.sh` and
`au_check_connectivity.sh`.

Checks performed:

- Directory mode 0700, `ewallet.p12` / `cwallet.sso` mode 0600, owned by the current user, no symlinks
- `.autoupgrade/` subdirectory not group/world-writable (AutoUpgrade refuses it)
- Key pair `PKEY1` / `PKEY2` via `mkstore -wrl <dir> -list` or `orapki wallet display`; if neither tool is
  available, a WARN is printed with the equivalent console command (`group mos`, `list`)
- Age: keystore files older than the build date of the installed JAR produce a WARN "re-save required"

```bash
bin/au_keystore.sh --check
```

### Re-save

`--resave` backs up the keystore, then opens the console and runs `group mos`, `save`. Re-saving recreates a
missing key pair, increments the sequence number, and removes the CSI entry. The keystore password is asked
interactively or via `--ks-pass-file`.

```bash
bin/au_keystore.sh --resave
```

### Backup

`--backup` archives the keystore directory (including `.autoupgrade/`) into
`${AU_KEYSTORE_BACKUP}/keystore_<yyyymmdd_hhmmss>.tgz`. The archive has umask 077; the backup directory is 0700.

Backup is run automatically before every create, re-save and forced overwrite.

```bash
bin/au_keystore.sh --backup --keep 5
```

`--keep N` retains the N most recent backups (default 5). The backup directory must be outside `AU_KEYSTORE` and
outside `AU_LOG_DIR`.

### Password Handling

<!-- markdownlint-disable MD013 MD060 -->
| Precedence | Method |
| --- | --- |
| 1 (highest) | `--mos-pass-file` / `--ks-pass-file` (read from file) |
| 2 | `MOS_PASS` / `KS_PASS` environment variables |
| 3 | `--mos-pass` / `--ks-pass` on argv (requires `--insecure-argv`; visible in `ps`) |
| 4 | Interactive prompt (when stdin is a TTY) |
<!-- markdownlint-restore -->

Passwords passed on the command line are never inherited by AutoUpgrade. `--insecure-argv` is required for argv
passwords and produces a warning.

### Key Pair and Gold Image

Gold image downloads (`AU_GOLD_IMAGE=YES`) require `PKEY1` and `PKEY2` in the keystore. After a JAR update,
`au_update_jar.sh` checks whether the keystore predates the new JAR and prints a WARN with the exact
`au_keystore.sh --resave` command when the key pair may be stale.

## JAR Update (au_update_jar.sh)

`au_update_jar.sh` downloads or installs `autoupgrade.jar` with version comparison, downgrade protection, backup
and checksum verification.

### Update Flow

1. Source: `--url` (default public Oracle URL) or `--from FILE` (offline host or a jar from a download folder).
2. Download into a temp file in the jar directory (same filesystem for an atomic move); a `trap` removes it on exit.
3. Sanity: size >= 1 MB, `PK` magic bytes, `META-INF/MANIFEST.MF` readable, `Main-Class` and
   `Implementation-Version` present.
4. Checksum: SHA-256 is printed; `--sha256 <hex>` enforces an expected value for fleet pinning. Oracle does not
   publish a checksum for `autoupgrade.jar`; use SHA-256 from the download host to pin a specific build.
5. Version compare: equal - no change, exit 0; older than installed - refused unless `--force`; newer - backup
   and install.
6. Backup: `jar/autoupgrade_<Implementation-Version>.jar`; `--keep N` retains the N most recent (default 3).
7. Verify: `au_run.sh -version` with the resolved Java (skip with `--no-verify`).
8. Keystore staleness check: `au_keystore.sh --check`; a WARN with the `--resave` command is printed when the
   keystore predates the new JAR or lacks the key pair. The update exits 0 regardless.

### Examples

```bash
# Default: download from Oracle and update if newer
bin/au_update_jar.sh

# Offline install from a transferred file
bin/au_update_jar.sh --from /u01/downloads/autoupgrade.jar --sha256 abc123...

# Fleet pinning: enforce a specific build by SHA-256
bin/au_update_jar.sh --sha256 <expected-hex>

# Allow downgrade (e.g. rollback)
bin/au_update_jar.sh --from autoupgrade_26.5.jar --force --yes

# Keep more backups
bin/au_update_jar.sh --keep 5
```

### Re-save Warning after JAR Update

After installing a newer JAR, the keystore files may be older than the new build date. AutoUpgrade may require a
re-save before the first download with the updated JAR. Run:

```bash
bin/au_keystore.sh --resave
```
