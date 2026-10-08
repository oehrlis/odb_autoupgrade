# Proxy and Truststore Handling

## Symptom

Patch downloads fail with a PKIX certificate validation error:

```text
unable to find valid certification path to requested target
```

Additional symptoms may include:

- MOS `list` command succeeds but "Oracle Update Advisor service - Connection Failure"
- Error: "No public/private key pair has been added to the keystore" (when gold image mode is AUTO)

## Cause

Three separate issues combine:

- **Java keystore**: AutoUpgrade uses the JDK from the Oracle Home (e.g. 1.8.0_4xx). This JDK has its own
  `cacerts` file that may lack the root CA chain needed for your environment.

- **TLS inspection proxies**: Corporate proxies that intercept HTTPS connections re-sign certificates with a
  corporate CA. The OS truststore knows the CA, but Java reads only its bundled cacerts, not the system store.

- **Proxy environment variables**: AutoUpgrade reads only the lowercase `https_proxy` variable (with `no_proxy`
  for exceptions). Uppercase variants like `HTTPS_PROXY` or `http_proxy` are ignored. If your shell sets only
  these, no proxy is used.

## How the Wrapper Resolves It

The `bin/au_run.sh` wrapper and `lib/au_lib.sh` implement a flexible precedence system:

### Environment Variable Precedence

The wrapper sources `etc/autoupgrade.env` for each run and allows the caller's environment to override it:

```bash
caller environment > etc/autoupgrade.env > compiled defaults
```

### Java Selection

The wrapper searches for a suitable JDK in this order:

1. `AUTOUPGRADE_JAVA_HOME` (if set and valid)
2. `$ORACLE_HOME/jdk/bin/java` (if present)
3. First `java` found on `PATH`

Supported major versions (default): 8, 11

- Oracle documentation: 8 and 11
- AutoUpgrade JAR 26.6 also starts on 17 and 21 and refuses 25
- Set `AUTOUPGRADE_JAVA_SUPPORTED="8 11 17 21"` to enable testing with newer versions

### Proxy Configuration

The wrapper detects proxies in this order and exports a sanitized lowercase `https_proxy`:

```bash
AUTOUPGRADE_PROXY > https_proxy > HTTPS_PROXY > http_proxy > HTTP_PROXY
```

Special values:

- `AUTOUPGRADE_PROXY=none` disables the proxy and unsets `https_proxy`
- Credentials embedded in the proxy URL (e.g. `http://user:pass@host:port`) are stripped and logged as
  a warning
- Default port if not specified: 80

The wrapper also exports JVM properties:

- `-Dhttps.proxyHost` / `-Dhttps.proxyPort`
- `-Dhttp.proxyHost` / `-Dhttp.proxyPort` (for artifact metadata)
- `-Dhttp.nonProxyHosts` (derived from `no_proxy`; leading dot `.*` converted to `*`)

CIDR notation in `no_proxy` is skipped (no JVM support).

### Truststore Configuration

The wrapper resolves the truststore path in this order:

1. `AUTOUPGRADE_TRUSTSTORE` (explicit path or `"none"` to disable)
2. `/etc/pki/ca-trust/extracted/java/cacerts` (OL/RHEL standard location)
3. `/etc/ssl/certs/java/cacerts` (alternative location)
4. None (use JDK's bundled cacerts)

`-Djavax.net.ssl.trustStorePassword` is passed only when `AUTOUPGRADE_TRUSTSTORE_PASS` is set. A truststore with
certificates only loads without a password; a password on the command line is visible in the process list.

### JVM Options and Debug

Pass additional JVM options:

```bash
export AUTOUPGRADE_JAVA_OPTS="-Xmx4g -Xms2g"
```

The wrapper also accepts:

- `AUTOUPGRADE_DEBUG_SSL=true` - Adds `-Djavax.net.debug=ssl:handshake` (handshake details only; never use `all`, it dumps
  plaintext and key material)
- `AUTOUPGRADE_DRY_RUN=true` - Print the constructed java command without executing it

All JVM options are passed on the command line, never via `JAVA_TOOL_OPTIONS` (which would pollute child processes).

### Configuration Precedence for Patch Runs

```bash
bin/au_run.sh -config /path/to/my.cfg -patch -download -noconsole
```

1. Caller sets `AUTOUPGRADE_PROXY=http://proxy.example.com:3128`
2. Wrapper reads `etc/autoupgrade.env` (if it has `AUTOUPGRADE_PROXY=...` too, it is ignored because step 1 wins)
3. If neither, defaults apply (no proxy)

## Adding a Corporate CA to the OS Truststore

On OL/RHEL systems, add your corporate CA certificate to the system truststore so Java can find it:

### Steps

1. Obtain the CA certificate in PEM format (ask your network team for the root CA certificate, not the
   intermediate):

   ```bash
   # Example: copy from a file or extract from your proxy
   cp /path/to/corporate-ca.pem /etc/pki/ca-trust/source/anchors/
   chmod 644 /etc/pki/ca-trust/source/anchors/corporate-ca.pem
   ```

1. Update the system truststore:

   ```bash
   sudo update-ca-trust extract
   ```

1. Verify the CA was added:

   ```bash
   grep -r "corporate-ca" /etc/pki/ca-trust/extracted/
   ```

1. Java will pick up the truststore automatically from `/etc/pki/ca-trust/extracted/java/cacerts`.

## Required Network Endpoints

The AutoUpgrade JAR contacts these hosts. All must be allowed on your proxy and (if using TLS inspection)
exempted from inspection or the inspection CA must be in the truststore.

<!-- markdownlint-disable MD013 MD060 -->

| Host | Purpose | Needed For | Source |
|------|---------|-----------|--------|
| login-ext.identity.oraclecloud.com | MOS OAuth login (password and device flow) | All MOS modes | JAR 26.6 |
| updates.oracle.com | ARU REST: patch search, metadata, release IDs | Download mode | JAR 26.6 |
| transport.oracle.com | Oracle Update Advisor (gold image download), OUA registration | Gold image AUTO/YES, download | JAR 26.6 |
| download.oracle.com | AutoUpgrade JAR version file, AU tool updates | Patch AU keyword, JAR update | JAR 26.6 |
| aru-akam.oracle.com | Patch file downloads (returned at runtime) | Download mode | Oracle docs |
| objectstorage.us-ashburn-1.oraclecloud.com | Gold image file downloads (OUA) | Gold image AUTO/YES, download | Oracle docs |

<!-- markdownlint-restore -->

### Discovering Runtime Download Hosts

The patch file URLs and gold image download locations are returned dynamically at runtime. To find them:

1. Run once with debug enabled:

   ```bash
   export AUTOUPGRADE_DEBUG_SSL=true
   bin/au_run.sh -config my.cfg -patch -download -noconsole 2>&1 | tee debug.log
   ```

1. Extract the server names from the TLS handshake logs:

   ```bash
   grep "server_name" debug.log | sort -u
   ```

1. Share the unique hostnames with your network team for proxy allowlisting and inspection exemption.

## MOS Keystore Notes

AutoUpgrade stores MOS credentials in an encrypted keystore managed via a console.

### Creating the Keystore

For download mode (not needed for create_home):

```bash
bin/au_run.sh -config au_download.cfg -patch -load_password
```

The `-load_password` flag starts the interactive console. Without `-patch` it opens the upgrade keystore instead.

### Console Workflow

```text
group mos
add -user your_mos_user@example.com
# Enter password when prompted
save
list
exit
```

The `list` command shows the status of both MOS credentials and the Oracle Update Advisor connection.

### Auto-Login Modes

When saving, you are prompted for the auto-login mode:

- **YES** - Local auto-login, bound to the current host and OS user. A copy to another machine fails with
  "Loading auto-login keystore failed (TDE104)".

- **SHARED** - Portable auto-login. The files work on other hosts - and for anyone who obtains a copy, the
  MOS credentials included. Use only if the keystore must be distributed.

- **NO** - Password-only; not usable with `-noconsole`.

**Recommendation**: Create the keystore on your download/build host with `YES` mode.

### Device Flow (No Password)

To avoid storing passwords, use device flow:

```text
group mos
add -no_password
# Follow the device flow login on the shown URL
save
```

Device-flow mode creates **no key pair**, so gold image mode `AUTO` falls back to `NO` and uses ZIP downloads instead.

### Key Pair and OUA

The key pair (wallet aliases `PKEY1` / `PKEY2`) is created by `add -user` and recreated on `save`. It is required
for gold image downloads with `AUTO` or `YES` mode.

Checking for the key pair without the console (best effort, not verified against a real keystore): on the
host and as the OS user that owns the keystore, list the wallet entries and look for `PKEY1` and `PKEY2`.
`bin/au_check_connectivity.sh` does this with `mkstore` when available. The reliable check is the console:
`group mos`, then `list` shows the MOS and the Update Advisor connection status.

```bash
$ORACLE_HOME/bin/mkstore -wrl <keystore_directory> -list
```

### Keystore Permissions and Location

- Permissions: `0600` (owner read/write only)
- Directory: must not be group- or world-writable
- Subdirectory `<keystore>/.autoupgrade/`:
  - `aru-device.tokens` - device-flow token (encrypted)
  - `oracle-updater.tokens` - OUA API key and connection metadata

## Gold Image Download

Gold images from the Oracle Update Advisor (OUA) bundle the base image, the Release Update and the MRP. They
are available for target releases 19 and 23 on LINUX.X64 only.

### Using Gold Image

Set `AU_GOLD_IMAGE=YES` for `etc/au_download.cfg`:

```bash
AU_GOLD_IMAGE=YES bin/au_run.sh -config au_download.cfg -patch -mode download
```

`RECOMMENDED` satisfies the RU requirement of the Update Advisor (it is expanded before the gold image check).

`gold_image.security_patch_level` is only relevant for release 23 and later.

Options:

- `AUTO` (default) - Try OUA; if unavailable, fall back to individual ZIP downloads (silent)
- `YES` - Require OUA; fail loudly if unavailable
- `ALL` - Require OUA and include all patches, not just RU and MRP
- `NO` - Skip OUA, download individual files

### Auto Fall-Back Reasons

AUTO falls back to NO (no gold image) if any of these checks fail (logged as INFO, not an error):

1. No RU specified in the patch list
2. Target release not supported (OUA: 19 and 23+ only)
3. No MOS credentials (username/password) in the keystore
4. No public/private key pair in the keystore (device-flow login does not create a pair)
5. Oracle Update Advisor service unreachable (proxy or network issue)
6. Platform is not LINUX.X64
7. OUA returns no recommended version for your release
8. Your requested RU is newer than the OUA recommendation

Check the log for `VDGI_*` messages to diagnose why AUTO fell back:

```bash
grep -E "VDGI_|GOLD_IMAGE" logs/cfgtoollogs/patch/auto/autoupgrade_patching.log
```

### Gold Image Coverage

OUA gold images include:

- Base image
- Release Update (RU)
- Monthly security patch (MRP or CSPU)
- OCW (Oracle Clusterware)

Separately downloaded from MOS:

- OJVM, DPBP, OPATCH, JDK, AU
- Patch numbers (one-offs)

So a gold image covers the most common patches, but you still download the rest.

## Generic Configuration Templates

Three templates in `etc/` cover the patch workflow without one file per RU. They contain only variables;
`bin/au_run.sh` expands them and aborts with the names of any unset variable.

| Template | Mode | Keystore | Per-run variables |
| --- | --- | --- | --- |
| `au_download.cfg` | `-patch -mode download` | yes | - |
| `au_create_home.cfg` | `-patch -mode create_home` | no | `AU_SOURCE_HOME`, `AU_TARGET_HOME` |
| `au_deploy.cfg` | `-patch -mode analyze`, `deploy` | no | `AU_SID`, `AU_SOURCE_HOME`, `AU_TARGET_HOME` |

Defaults (override in `etc/autoupgrade.env` or on the command line): `AU_PATCH=RECOMMENDED`,
`AU_TARGET_VERSION=19`, `AU_PLATFORM=LINUX.X64`, `AU_GOLD_IMAGE=NO`, and `AU_LOG_DIR`, `AU_KEYSTORE`,
`AU_DOWNLOAD_FOLDER` below `AUTOUPGRADE_BASE` (`logs/`, `keystore/`, `patches/`).

### One Patch List for All Modes

`AU_PATCH` must be identical for download, create_home and deploy. Resolution order:

1. Caller environment
1. `etc/autoupgrade.env`
1. `${AU_DOWNLOAD_FOLDER}/au_patch.env` (pin written after a download)
1. Default `RECOMMENDED`

Unversioned `RECOMMENDED` is resolved differently per mode: download asks MOS for the current recommendation,
while create_home picks the newest RU zip found in the download folder (AutoUpgrade 26.6 code). With a folder
that holds more than one quarter, this is not deterministic. Pin the version after the download - the
resolved RU is in the `releaseUpdate` field of `patches_info.json`:

```bash
grep -o '"releaseUpdate" *: *"[0-9.]*"' "${AUTOUPGRADE_BASE}/patches/patches_info.json"
echo 'AU_PATCH=RECOMMENDED:19.32' > "${AUTOUPGRADE_BASE}/patches/au_patch.env"
```

`au_patch.env` is parsed, not sourced: only a line `AU_PATCH=<value>` with letters, digits and `_.,:-` is
accepted. The file is ignored with a warning if it is a symlink, not owned by the current user, or group or
world writable - it usually arrives with a transferred download folder.

Writing `au_patch.env` automatically after a download is planned for Phase 2. Rules for `AU_PATCH`:

- `RECOMMENDED` resolves to RU, OPATCH, DPBP, OJVM, AU and MRP on Linux (no JDK)
- `RECOMMENDED:19.32` and `RU:19.32,OPATCH,OJVM,DPBP,MRP` are valid; `MRP` takes no version
- `RECOMMENDED,RU:19.32` is rejected - AutoUpgrade requires the same version on both
- `CSPU` is rejected on Linux for 19c - use `MRP`

### Typical Flow

```bash
# Download host (keystore present)
bin/au_run.sh -config au_download.cfg -patch -mode download
echo 'AU_PATCH=RECOMMENDED:19.32' > patches/au_patch.env

# Stage the whole folder, including bug-map.json, patches_info.json and au_patch.env
rsync -av patches/ db-host:/u00/app/oracle/autoupgrade/patches/

# DB host
AU_SOURCE_HOME=/u00/app/oracle/product/19.31.0.0 AU_TARGET_HOME=/u00/app/oracle/product/19.32.0.0 \
  bin/au_run.sh -config au_create_home.cfg -patch -mode create_home
AU_SID=ORCL AU_SOURCE_HOME=/u00/app/oracle/product/19.31.0.0 AU_TARGET_HOME=/u00/app/oracle/product/19.32.0.0 \
  bin/au_run.sh -config au_deploy.cfg -patch -mode deploy
```

Deploy creates the target home itself if it does not exist. If it exists, its installed patches must match
`AU_PATCH` exactly (`THL_PATCH_MISMATCH`).

## Runtime Data

After a download run, the log directory contains reused metadata:

```text
logs/cfgtoollogs/patch/auto/
├── autoupgrade_patching.log
├── autoupgrade_patching_user.log
├── autoupgrade_patching_err.log
├── config_files/
├── aru/
│   ├── request_id_cache.json       # Previous gold image request IDs (keyed by config hash)
│   ├── *.csd                       # Stored checksums of downloaded files
│   ├── aru.log
│   ├── aru_user.log
│   └── ous.log
```

**Important**: Do not delete the `aru/` directory when cleaning logs. The cached request IDs and checksums
avoid redundant downloads and API calls in subsequent runs.

In the download folder itself:

- `bug-map.json` - Bug information for the patch set
- `patches_info.json` - Patch metadata

Create_home and deploy modes **require** these JSON files. Always copy the entire download folder including all
metadata files when staging patches elsewhere.

## Pre-flight Connectivity Check

A helper script validates network connectivity before starting AutoUpgrade:

```bash
bin/au_check_connectivity.sh
```

Output: one check per line, summary of resolved hostnames for the network team, exit codes:

- `0` - All checks passed
- `1` - At least one check failed (hard error)
- `2` - Some checks skipped (optional endpoints, informational)

Review the output with your network team to confirm proxy allowlisting and TLS inspection exemptions.
