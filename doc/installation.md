# Installation

odb_autoupgrade runs standalone or as an OraDBA extension. Both modes use the same release tarball
`odb_autoupgrade-<version>.tar.gz` from [GitHub Releases](https://github.com/oehrlis/odb_autoupgrade/releases).

The repository is `oehrlis/odb_autoupgrade`. The legacy repository `oehrlis/autoupgrade` is private and
cannot be installed from - see [Troubleshooting](#troubleshooting).

## Prerequisites

- Bash 4.2 or later
- Java 8 or later for `autoupgrade.jar` (`AUTOUPGRADE_JAVA_HOME`, the `ORACLE_HOME` JDK, or `java` in `PATH`)
- `envsubst` from the `gettext` package for `au_run.sh -config` (renders the config templates). Minimal
  `oraclelinux:9` images lack it: `dnf install -y gettext`
- `expect` for `au_keystore.sh --create`
- `curl` for JAR updates, connectivity checks and downloads
- For the extension mode: OraDBA with `oradba_extension.sh` (tested with OraDBA 1.1.1)

## OraDBA Extension

### Online Install

```bash
oradba_extension.sh add oehrlis/odb_autoupgrade           # latest release
oradba_extension.sh add oehrlis/odb_autoupgrade@v0.6.1    # specific release
```

The installer reads the release through the GitHub API (`api.github.com`) and downloads the asset
`odb_autoupgrade-<version>.tar.gz`. A correct install prints `Latest release: v<version>` and a download URL
under `/releases/download/`.

Check the result:

```bash
oradba_extension.sh validate odb_autoupgrade
cat "${ORADBA_LOCAL_BASE}/odb_autoupgrade/VERSION"
ls "${ORADBA_LOCAL_BASE}/odb_autoupgrade/.extension.checksum"
```

`.extension.checksum` is only part of a release tarball. If it is missing, the installer fell back to a branch
archive - see [Troubleshooting](#troubleshooting).

### Offline Install

Use this path on hosts without access to `api.github.com`, or when the API rate limit is exhausted. Download
both release assets on a host with access and copy them over:

```bash
VERSION=0.6.1
BASE_URL="https://github.com/oehrlis/odb_autoupgrade/releases/download/v${VERSION}"
curl -fLO "${BASE_URL}/odb_autoupgrade-${VERSION}.tar.gz"
curl -fLO "${BASE_URL}/odb_autoupgrade-${VERSION}.tar.gz.sha256"
```

On the target host verify the tarball and install it as a local file:

```bash
sha256sum -c "odb_autoupgrade-${VERSION}.tar.gz.sha256"
oradba_extension.sh add "$PWD/odb_autoupgrade-${VERSION}.tar.gz"
```

### Update

```bash
oradba_extension.sh add oehrlis/odb_autoupgrade --update
oradba_extension.sh add "$PWD/odb_autoupgrade-${VERSION}.tar.gz" --update   # offline
```

The update creates a full backup `odb_autoupgrade_backup_<timestamp>` next to the extension, then replaces
`bin/`, `lib/` and `etc/` and copies the new `doc/` over the old one. Files in `etc/` that differ from the release
checksum and user-added `*.env` and `*.conf` files are kept. `keystore/`, `jar/` and `patches/` are not touched.

Read the release notes before an update; [Upgrade 0.6.0](upgrade-0.6.0.md) covers the migration from 0.5.0.

## Standalone

```bash
mkdir -p /u00/app/oracle/local
cd /u00/app/oracle/local
sha256sum -c odb_autoupgrade-0.6.1.tar.gz.sha256
tar xzf odb_autoupgrade-0.6.1.tar.gz
cd odb_autoupgrade
cp etc/autoupgrade.env.example etc/autoupgrade.env
chmod go-w etc etc/autoupgrade.env
```

The scripts refuse config files in group- or world-writable locations; see
[Configuration](configuration.md#file-security-rules). To update, extract the new tarball over the old directory
after a backup of `etc/`, `keystore/` and `jar/`.

## First Steps

```bash
bin/au_check_connectivity.sh      # proxy, truststore, Oracle endpoints
bin/au_update_jar.sh              # latest autoupgrade.jar
bin/au_keystore.sh --create       # MOS credentials keystore
```

See [Proxy and Truststore](proxy-and-truststore.md) for hosts behind a TLS-inspecting proxy and
[Keystore and JAR](keystore-and-jar.md) for the keystore lifecycle.

## Troubleshooting

### "No releases found"

`oradba_extension.sh` prints `No releases found, checking for tags...` whenever the GitHub API call fails, not
only when a repository has no release. Typical causes:

| Cause | Check |
| --- | --- |
| Wrong repository name, e.g. the private legacy `oehrlis/autoupgrade` | use `oehrlis/odb_autoupgrade` |
| API rate limit exhausted (60 requests per hour per IP without a token, shared NAT counts once) | `curl -s https://api.github.com/rate_limit` |
| Proxy or firewall blocks `api.github.com` while `github.com` is allowed | `curl -fsSI https://api.github.com/repos/oehrlis/odb_autoupgrade/releases/latest` |

With the wrong repository name the install fails with a 404. With the two API failures the installer falls
back to the **main branch archive** and reports success: the result is the development tree, not a release
(`tests/`, `Makefile`, no `.extension.checksum`). Remove that directory and use the
[Offline Install](#offline-install).

### Extension Not Listed

```bash
oradba_extension.sh list
cat "${ORADBA_LOCAL_BASE}/odb_autoupgrade/.extension"
```

The extension directory must be directly below `ORADBA_LOCAL_BASE` and contain `.extension`.
