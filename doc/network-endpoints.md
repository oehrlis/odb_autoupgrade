# Network Endpoints

Reference for network and proxy teams: which hosts odb_autoupgrade and Oracle AutoUpgrade contact, when, and how
to check them. Only the host that downloads patches needs these endpoints. Database hosts that run create_home or
deploy from a staged download folder need no Oracle internet access.

## Endpoint Table

All connections are outbound HTTPS on TCP 443, through the proxy from `AUTOUPGRADE_PROXY` or `https_proxy` (see
[Proxy and Truststore](proxy-and-truststore.md)).

<!-- markdownlint-disable MD013 MD060 -->

| Host | Purpose | Needed when | Source |
| --- | --- | --- | --- |
| `login-ext.identity.oraclecloud.com` | My Oracle Support login (OAuth, password and device flow) | every `-patch` run with `download=YES` | Upgrade Guide [1] |
| `updates.oracle.com` | My Oracle Support patch search and metadata | `-mode download` | Upgrade Guide [1] |
| `aru-akam.oracle.com` | patch file downloads | `-mode download` | Upgrade Guide [1] |
| `edelivery.oracle.com` | latest AutoUpgrade | patch keyword `AU` (part of `RECOMMENDED`) | Upgrade Guide [1] |
| `transport.oracle.com` | Oracle Update Advisor (OUA) | gold image download (`AU_GOLD_IMAGE=YES` or `AUTO`) | Upgrade Guide [1] |
| `objectstorage.us-ashburn-1.oraclecloud.com` | OUA gold image files | gold image download | Upgrade Guide [1] |
| `download.oracle.com` | `autoupgrade.jar` download | `au_update_jar.sh` without `--from` | `bin/au_update_jar.sh` |

<!-- markdownlint-restore -->

[1] Oracle Database Upgrade Guide 26ai, AutoUpgrade common parameter `download`:
<https://docs.oracle.com/en/database/oracle/oracle-database/26/upgrd/common-parameters-autoupgrade-config-file.html>
(checked 2026-10-14). The page lists the endpoints that "must be reachable" for a download.

## Download Hosts Change

Patch file URLs come from the My Oracle Support answer at run time. Oracle can move downloads to other hosts
without notice. If a download fails on a host that is not in the table, find the server names of the run as
described in [Discovering Runtime Download Hosts](proxy-and-truststore.md#discovering-runtime-download-hosts)
and add them to the allowlist.

## TLS Inspection

AutoUpgrade is a Java program and uses the truststore of its JVM, not the OS CA bundle. With a TLS-inspecting
proxy, either exempt these hosts from inspection or add the inspection CA to the truststore
(`AUTOUPGRADE_TRUSTSTORE`). Details: [Proxy and Truststore](proxy-and-truststore.md).

## Check

`au_check_connectivity.sh` tests every host in the table through the configured proxy and truststore, names the
TLS issuer and flags non-public issuers (likely TLS inspection):

```bash
bin/au_check_connectivity.sh              # all endpoints, keystore, truststore
bin/au_check_connectivity.sh --dry-run    # list the endpoints only
bin/au_check_connectivity.sh --endpoints site-endpoints.txt
```

Exit codes: `0` all OK, `1` at least one FAIL, `2` warnings only. An endpoint file has one
`host|url|purpose|source` entry per line and replaces the built-in list.

## Request Template

Text for a firewall or proxy change request:

```text
Source: <download host>, user oracle
Destination: login-ext.identity.oraclecloud.com, updates.oracle.com, aru-akam.oracle.com,
  edelivery.oracle.com, transport.oracle.com, objectstorage.us-ashburn-1.oraclecloud.com,
  download.oracle.com
Port: TCP 443 (HTTPS) via proxy <proxy:port>
TLS inspection: exempt, or provide the inspection CA certificate for the Java truststore
Purpose: Oracle Database patch download with Oracle AutoUpgrade (My Oracle Support)
```
