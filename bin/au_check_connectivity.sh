#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Name.......: au_check_connectivity.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Editor.....: Stefan Oehrli
# Date.......: 2026.10.08
# Version....: v0.5.0
# Purpose....: Pre-flight connectivity check for Oracle AutoUpgrade.
#              Validates that all required Oracle endpoints are reachable
#              through the configured proxy, TLS inspection is detected,
#              the keystore and truststore are in order, and the JAR is present.
# Notes......: - Resolves AUTOUPGRADE_BASE from script location.
#              - Sources ${AUTOUPGRADE_BASE}/etc/autoupgrade.env via
#                au_source_env_file (caller env wins over env file).
#              - Java, proxy, and truststore resolution via lib/au_lib.sh.
#                au_build_proxy_opts also exports https_proxy so AutoUpgrade's
#                native proxy path (System.getenv) agrees with -D properties.
#              - When TRUSTSTORE_INFO is set and keytool is available, all
#                trustedCertEntry certificates are exported to a temp PEM bundle
#                (keytool -list -rfc) and passed to curl via --cacert so that
#                curl and Java use the same trust anchors. A WARN is emitted
#                when the anchors differ (no keytool / JDK default cacerts).
#              - TLS inspection detection: the O= value of each certificate
#                issuer seen across ALL redirect hops is extracted and matched
#                (case-insensitive exact match) against a list of known public
#                CA organisation names. If any hop has a non-public O= value,
#                WARN is emitted. Oracle Corporation and Microsoft Corporation
#                are excluded from the public CA list (ambiguous with
#                inspection appliances).
#              - au_check_truststore uses -storepass:env AUTOUPGRADE_TRUSTSTORE_PASS
#                (JDK 9+) and FAILS on keytool error or 0 trusted cert entries.
#              - --dry-run: list what would be checked, exit 0.
#              - --yes / --delete: accepted, silently ignored (no destructive op).
#              - Dynamic download URLs (ARU patch files, gold images) are not
#                listed here; to find them set AUTOUPGRADE_DEBUG_SSL=true in
#                autoupgrade.env and grep the AutoUpgrade log for server_name.
#
#              Exit codes:
#                0 - all checks passed
#                1 - one or more FAIL results
#                2 - only WARN results (no FAIL)
#
#              Environment variables (all optional):
#                AUTOUPGRADE_PROXY           Proxy URL; "none" disables proxy
#                AUTOUPGRADE_TRUSTSTORE      Truststore path; "none" = JDK default
#                AUTOUPGRADE_TRUSTSTORE_PASS Truststore password
#                AUTOUPGRADE_JAVA_HOME       JDK to use
#
# Reference..: https://github.com/oehrlis/odb_autoupgrade
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.08 oehrli - initial version
# 2026.10.08 oehrli - security: -storepass:env, FAIL on 0 entries,
#                     truststore PEM for curl --cacert, issuer O= exact match,
#                     drop Oracle/Microsoft from public CA list,
#                     report all redirect-hop issuers
# ------------------------------------------------------------------------------

set -euo pipefail

# - Default Values -------------------------------------------------------------
SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")
SCRIPT_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SCRIPT_BASE="$(dirname "${SCRIPT_BIN_DIR}")"
export AUTOUPGRADE_BASE="${SCRIPT_BASE}"

AUTOUPGRADE_ENV_FILE="${AUTOUPGRADE_BASE}/etc/autoupgrade.env"
JAR_FILE="${AUTOUPGRADE_BASE}/jar/autoupgrade.jar"

# Defaults for CLI options
KEYSTORE_DIR="${AUTOUPGRADE_BASE}/keystore"
ENDPOINTS_FILE=""
TIMEOUT=15
QUIET=false
DRY_RUN=false

# Globals set by au_build_proxy_opts / au_resolve_truststore / au_resolve_java
JAVA_OPTS=()
PROXY_INFO=""
TRUSTSTORE_INFO=""
JAVA_BIN=""
JAVA_VERSION_FULL=""

# Temp PEM bundle exported from the truststore for curl --cacert.
# Cleaned up by the EXIT trap below.
TRUSTSTORE_PEM=""
# curl args for --cacert (empty when not using a custom bundle)
_CURL_CACERT_ARGS=()

# Result counters
_FAIL_COUNT=0
_WARN_COUNT=0

# Hosts flagged for FAIL or TLS inspection (for summary block)
_FLAGGED_HOSTS=()

# Built-in endpoint list.  Format: host|url|purpose|source
# Source field references the AutoUpgrade jar class or Oracle docs that
# confirms each endpoint is required.
AU_ENDPOINTS=(
    "login-ext.identity.oraclecloud.com|https://login-ext.identity.oraclecloud.com/oauth2/v1/token|MOS OAuth login (password + device flow)|jar 26.6 AruProductionServer"
    "updates.oracle.com|https://updates.oracle.com/Orion/Services/search|MOS ARU REST: patch search metadata downloads|jar 26.6 SearchBuilder/MetadataBuilder"
    "transport.oracle.com|https://transport.oracle.com/|Oracle Update Advisor (gold image)|jar 26.6 UpdaterSite"
    "download.oracle.com|https://download.oracle.com/otn-pub/otn_software/autoupgrade.json|AutoUpgrade version/JAR self-patch|jar 26.6 ApplyAU"
    "aru-akam.oracle.com|https://aru-akam.oracle.com/|patch file downloads (URL returned by ARU)|Oracle docs"
    "objectstorage.us-ashburn-1.oraclecloud.com|https://objectstorage.us-ashburn-1.oraclecloud.com/|gold image file download (OUA)|Oracle docs"
)

# Issuers from well-known public CAs.  The O= value of the issuer DN is
# extracted and matched case-insensitively against this list (exact match).
# Oracle Corporation and Microsoft Corporation are intentionally excluded:
# they are ambiguous with TLS-inspection appliances in enterprise environments.
AU_PUBLIC_CA_PATTERNS=(
    "DigiCert Inc"
    "Entrust, Inc."
    "GlobalSign nv-sa"
    "Let's Encrypt"
    "Sectigo Limited"
    "Amazon"
    "Google Trust Services"
    "Google Trust Services LLC"
    "GeoTrust Inc."
    "thawte, Inc."
    "IdenTrust"
)
# Lowercased once (bash 3.2 has no ${var,,}); used by _is_public_ca
AU_PUBLIC_CA_PATTERNS_LC=()
while IFS= read -r _ca_lc; do
    AU_PUBLIC_CA_PATTERNS_LC+=("${_ca_lc}")
done < <(printf '%s\n' "${AU_PUBLIC_CA_PATTERNS[@]}" | tr '[:upper:]' '[:lower:]')
# - EOF Default Values ---------------------------------------------------------

# - Load Library ---------------------------------------------------------------
# shellcheck source=lib/au_lib.sh
. "${SCRIPT_BIN_DIR}/../lib/au_lib.sh"
# - EOF Load Library -----------------------------------------------------------

# - Site Settings --------------------------------------------------------------
au_source_env_file "${AUTOUPGRADE_ENV_FILE}"
# - EOF Site Settings ----------------------------------------------------------

# EXIT trap: remove temp PEM bundle
trap 'rm -f "${TRUSTSTORE_PEM:-}"' EXIT

# - Functions ------------------------------------------------------------------

# Print usage and exit 0
au_show_help() {
    cat >&2 <<HELP
Usage: ${SCRIPT_NAME} [options]

Pre-flight connectivity check for Oracle AutoUpgrade.

Options:
  --help                Show this message and exit
  --keystore <dir>      Keystore directory (default: \${AUTOUPGRADE_BASE}/keystore)
  --endpoints <file>    Override endpoint list; one entry per line:
                        host|url|purpose|source  (# comments ignored)
  --timeout <seconds>   curl timeout in seconds (default: ${TIMEOUT})
  --quiet               Suppress [OK] lines; show only [WARN] and [FAIL]
  --dry-run             Print what would be checked and exit 0
  --yes                 Accepted and silently ignored
  --delete              Accepted and silently ignored

Exit codes:
  0  all checks OK
  1  one or more FAIL
  2  only WARN (no FAIL)

Dynamic download hosts (ARU patch file URLs, gold image hosts) are not
listed here.  To discover them: set AUTOUPGRADE_DEBUG_SSL=true in
autoupgrade.env and grep the AutoUpgrade log for server_name.
HELP
    exit 0
}

# Emit a formatted result line.  [OK] lines are suppressed with --quiet.
# Usage: au_emit <OK|WARN|FAIL> <check-name> <detail>
au_emit() {
    local level="$1" check="$2" detail="$3"
    case "${level}" in
        FAIL) _FAIL_COUNT=$(( _FAIL_COUNT + 1 )) ;;
        WARN) _WARN_COUNT=$(( _WARN_COUNT + 1 )) ;;
    esac
    if [[ "${QUIET}" == true && "${level}" == "OK" ]]; then
        return 0
    fi
    printf '[%s] %s: %s\n' "${level}" "${check}" "${detail}"
}

# Return portable octal permission bits for a path.
_file_perms() {
    # GNU stat: -c '%a'; BSD/macOS stat: -f '%Lp'
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo "unknown"
}

# Map curl exit code to a human-readable reason.
_curl_rc_reason() {
    case "$1" in
        6)  echo "DNS resolution failed" ;;
        7)  echo "connection refused or unreachable" ;;
        28) echo "timeout" ;;
        35) echo "TLS handshake error" ;;
        56) echo "proxy CONNECT refused (proxy denied tunnel)" ;;
        60) echo "TLS certificate error (PKIX / untrusted CA)" ;;
        *)  echo "curl error code $1" ;;
    esac
}

# Return 0 if the O= value of the issuer DN matches a known public CA.
# Extracts the O= field from the issuer DN, trims whitespace, and does a
# case-insensitive exact match against AU_PUBLIC_CA_PATTERNS.
# Returns 1 when no O= field is present (cannot confirm public CA).
_is_public_ca() {
    local issuer="$1"
    # curl prints the DN as "C=US; O=Entrust, Inc.; CN=..." - fields are
    # separated by ";" (commas may appear inside values); fall back to ","
    local sep=','
    [[ "${issuer}" == *';'* ]] && sep=';'

    local -a fields
    local field org org_lc pattern_lc found=false matched
    IFS="${sep}" read -ra fields <<< "${issuer}"
    for field in "${fields[@]}"; do
        # Trim leading/trailing whitespace; only a field that starts with O= counts
        field="${field#"${field%%[![:space:]]*}"}"
        field="${field%"${field##*[![:space:]]}"}"
        [[ "${field}" == O=* ]] || continue
        org="${field#O=}"
        org_lc="$(printf '%s' "${org}" | tr '[:upper:]' '[:lower:]')"
        matched=false
        for pattern_lc in "${AU_PUBLIC_CA_PATTERNS_LC[@]}"; do
            [[ "${org_lc}" == "${pattern_lc}" ]] && matched=true && break
        done
        # Every O= field must be a known public CA organisation
        [[ "${matched}" == true ]] || return 1
        found=true
    done
    [[ "${found}" == true ]]  # no O= field -> cannot confirm public CA
}

# Build a temp PEM bundle from the truststore for curl --cacert.
# Sets _CURL_CACERT_ARGS=("--cacert" "<path>") when successful.
# Emits a WARN when curl and Java cannot be aligned (no keytool / no truststore).
au_build_truststore_pem() {
    local keytool_bin="${JAVA_BIN%/*}/keytool"

    if [[ -z "${TRUSTSTORE_INFO}" ]]; then
        echo "WARN: curl uses the OS CA bundle, Java uses JDK default cacerts - TLS results may differ" >&2
        return 0
    fi

    if [[ ! -x "${keytool_bin}" ]]; then
        echo "WARN: curl uses the OS CA bundle, Java uses ${TRUSTSTORE_INFO} - TLS results may differ (keytool not available)" >&2
        return 0
    fi

    TRUSTSTORE_PEM="$(mktemp "${TMPDIR:-/tmp}/au_ts_pem_XXXXXX")"

    local _keytool_rc=0
    export AUTOUPGRADE_TRUSTSTORE_PASS="${AUTOUPGRADE_TRUSTSTORE_PASS:-changeit}"
    "${keytool_bin}" -list -rfc -keystore "${TRUSTSTORE_INFO}" \
        -storepass:env AUTOUPGRADE_TRUSTSTORE_PASS 2>/dev/null \
        | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' \
        > "${TRUSTSTORE_PEM}" || _keytool_rc=$?

    if [[ "${_keytool_rc}" -ne 0 || ! -s "${TRUSTSTORE_PEM}" ]]; then
        rm -f "${TRUSTSTORE_PEM}"
        TRUSTSTORE_PEM=""
        echo "WARN: curl uses the OS CA bundle, Java uses ${TRUSTSTORE_INFO} - TLS results may differ (keytool PEM export failed)" >&2
        return 0
    fi

    _CURL_CACERT_ARGS=("--cacert" "${TRUSTSTORE_PEM}")
    echo "TLS verified against ${TRUSTSTORE_INFO}" >&2
}

# Check one endpoint via curl.
# Usage: au_check_endpoint <host> <url> <purpose>
au_check_endpoint() {
    local host="$1" url="$2" purpose="$3"
    local verbose_tmp http_code curl_rc check_name
    check_name="${host} (${purpose})"

    verbose_tmp="$(mktemp "${TMPDIR:-/tmp}/au_conn_XXXXXX")"
    # Ensure verbose_tmp is removed when this function returns or on EXIT
    # (EXIT trap covers the PEM; use a local trap override for the verbose file)

    # Build curl proxy args from PROXY_INFO (set by au_build_proxy_opts)
    local -a curl_args=()
    if [[ -n "${PROXY_INFO}" ]]; then
        curl_args+=("--proxy" "http://${PROXY_INFO}")
        # Pass no_proxy as-is to curl; curl handles wildcard patterns natively
        local np="${no_proxy:-${NO_PROXY:-}}"
        if [[ -n "${np}" ]]; then
            curl_args+=("--noproxy" "${np}")
        fi
    fi

    # Add --cacert if a PEM bundle was built from the truststore
    if [[ "${#_CURL_CACERT_ARGS[@]}" -gt 0 ]]; then
        curl_args+=("${_CURL_CACERT_ARGS[@]}")
    fi

    http_code=""
    curl_rc=0
    # -s: no progress bar; -v: verbose TLS info to stderr;
    # -L: follow redirects; -w: write HTTP code to stdout;
    # -o /dev/null: discard response body; --max-time: combined timeout
    http_code=$(curl -sv -L -w '%{http_code}' -o /dev/null \
        --max-time "${TIMEOUT}" \
        "${curl_args[@]}" \
        "${url}" 2>"${verbose_tmp}") || curl_rc=$?

    # Parse ALL issuers from verbose stderr across all redirect hops.
    # curl -v emits lines like:  * issuer: CN=...; O=DigiCert Inc; C=US
    # or (newer curl):            *  issuer: ...
    local -a hop_issuers=()
    local _ln _iss
    while IFS= read -r _ln; do
        _ln="${_ln%$'\r'}"
        if [[ "${_ln}" == *'issuer:'* ]]; then
            _iss="${_ln#*issuer: }"
            _iss="${_iss#*issuer:}"
            _iss="${_iss# }"
            [[ -n "${_iss}" ]] && hop_issuers+=("${_iss}")
        fi
    done < <(grep -i 'issuer:' "${verbose_tmp}" 2>/dev/null || true)

    rm -f "${verbose_tmp}"

    if [[ "${curl_rc}" -ne 0 ]]; then
        au_emit "FAIL" "${check_name}" "$(_curl_rc_reason "${curl_rc}")"
        _FLAGGED_HOSTS+=("${host}")
        return 0
    fi

    # Any HTTP answer after a successful TLS handshake proves reachability; the
    # probe URLs are not valid API calls (e.g. 405 on the OAuth token endpoint,
    # 404 on the Object Storage root). Only proxy-side answers are problems.
    case "${http_code}" in
        407)
            au_emit "FAIL" "${check_name}" "HTTP 407 proxy authentication required"
            _FLAGGED_HOSTS+=("${host}")
            return 0
            ;;
        5[0-9][0-9])
            au_emit "WARN" "${check_name}" "HTTP ${http_code} - server or proxy error, retry or check proxy"
            _FLAGGED_HOSTS+=("${host}")
            return 0
            ;;
        [1-4][0-9][0-9]) ;;
        *)
            au_emit "FAIL" "${check_name}" "no HTTP status (${http_code:-empty})"
            _FLAGGED_HOSTS+=("${host}")
            return 0
            ;;
    esac

    if [[ "${#hop_issuers[@]}" -gt 0 ]]; then
        # Check ALL hops: if any has a non-public O= -> WARN (possible TLS inspection)
        local any_non_public=false
        local _hi
        for _hi in "${hop_issuers[@]}"; do
            if ! _is_public_ca "${_hi}"; then
                any_non_public=true
                break
            fi
        done

        if [[ "${any_non_public}" == true ]]; then
            # Build a semicolon-separated list of all issuers for display
            local _issuers_str="${hop_issuers[0]}"
            local _j
            for (( _j=1; _j<${#hop_issuers[@]}; _j++ )); do
                _issuers_str="${_issuers_str}; ${hop_issuers[_j]}"
            done
            au_emit "WARN" "${check_name}" \
                "HTTP ${http_code} non-public issuer - TLS inspection? issuers: ${_issuers_str}"
            _FLAGGED_HOSTS+=("${host}")
        else
            au_emit "OK" "${check_name}" "HTTP ${http_code} issuer: ${hop_issuers[0]}"
        fi
    else
        au_emit "OK" "${check_name}" "HTTP ${http_code} (issuer unknown - no TLS info)"
    fi
}

# Check truststore entry count via keytool.
# Uses -storepass:env (JDK 9+) to avoid passing the password on the command line.
# FAILS when keytool returns a non-zero exit code or when there are 0 trusted
# cert entries (empty truststore or wrong password).
au_check_truststore() {
    local keytool_bin
    keytool_bin="${JAVA_BIN%/*}/keytool"

    if [[ ! -x "${keytool_bin}" ]]; then
        au_emit "WARN" "truststore" \
            "keytool not found at ${keytool_bin}; cannot count entries"
        return 0
    fi

    if [[ -n "${TRUSTSTORE_INFO}" ]]; then
        local ts_output keytool_rc count
        keytool_rc=0
        export AUTOUPGRADE_TRUSTSTORE_PASS="${AUTOUPGRADE_TRUSTSTORE_PASS:-changeit}"
        # Capture keytool output separately so grep -c (which exits 1 on 0 matches)
        # is not confused with a keytool error exit.
        ts_output=$("${keytool_bin}" -list -keystore "${TRUSTSTORE_INFO}" \
            -storepass:env AUTOUPGRADE_TRUSTSTORE_PASS \
            2>/dev/null) || keytool_rc=$?
        if [[ "${keytool_rc}" -ne 0 ]]; then
            au_emit "FAIL" "truststore" \
                "keytool failed (rc=${keytool_rc}) for ${TRUSTSTORE_INFO} (wrong password or corrupt file?)"
            return 0
        fi
        count=0
        count=$(printf '%s\n' "${ts_output}" | grep -c 'trustedCertEntry' || true)
        if [[ "${count}" -eq 0 ]]; then
            au_emit "FAIL" "truststore" \
                "${TRUSTSTORE_INFO}: 0 trusted cert entries (empty truststore or wrong password?)"
            return 0
        fi
        au_emit "OK" "truststore" "${TRUSTSTORE_INFO} (${count} trusted cert entries)"
    else
        au_emit "WARN" "truststore" \
            "using JDK default cacerts - configure AUTOUPGRADE_TRUSTSTORE to the OS truststore"
    fi
}

# Check AutoUpgrade JAR: presence, version, and file date.
au_check_jar() {
    if [[ ! -f "${JAR_FILE}" ]]; then
        au_emit "FAIL" "autoupgrade.jar" "not found at ${JAR_FILE}"
        return 0
    fi
    local version file_date
    version=$(unzip -p "${JAR_FILE}" META-INF/MANIFEST.MF 2>/dev/null \
        | grep -i 'Implementation-Version' \
        | cut -d: -f2 | tr -d ' \r\n') || true
    version="${version:-unknown}"
    file_date=$(stat -c '%y' "${JAR_FILE}" 2>/dev/null | cut -d' ' -f1) \
        || file_date=$(stat -f '%Sm' -t '%Y-%m-%d' "${JAR_FILE}" 2>/dev/null) \
        || file_date="unknown"
    au_emit "OK" "autoupgrade.jar" "version ${version} (${file_date})"
}

# Best-effort keypair check using mkstore.
# AutoUpgrade checks wallet aliases PKEY1 (public) and PKEY2 (private).
# If mkstore is unavailable: emit WARN with manual command.
# The auto-login keystore (cwallet.sso) is host-bound; a copy from another
# host fails at runtime with "Loading auto-login keystore failed" (TDE104).
# auto-login mode: YES = local (host+OS user bound), SHARED = portable, NO = pwd only.
au_keystore_keypair_check() {
    local ks_dir="$1"
    local cwallet="${ks_dir}/cwallet.sso"
    local mkstore_bin manual_cmd
    manual_cmd="orapki wallet display -wallet '${ks_dir}'"

    # Locate mkstore: prefer ORACLE_HOME, then PATH
    if [[ -n "${ORACLE_HOME:-}" && -x "${ORACLE_HOME}/bin/mkstore" ]]; then
        mkstore_bin="${ORACLE_HOME}/bin/mkstore"
    elif command -v mkstore >/dev/null 2>&1; then
        mkstore_bin="$(command -v mkstore)"
    else
        au_emit "WARN" "keystore keypair" \
            "mkstore not found; cannot verify key pair - run: ${manual_cmd}"
        return 0
    fi

    if [[ ! -f "${cwallet}" ]]; then
        au_emit "WARN" "keystore keypair" \
            "cwallet.sso not found; cannot verify key pair"
        return 0
    fi

    local list_output mkstore_rc
    mkstore_rc=0
    # Run mkstore with stdin from /dev/null; use timeout if available
    if command -v timeout >/dev/null 2>&1; then
        list_output=$(timeout 10s "${mkstore_bin}" -wrl "${ks_dir}" -list \
            </dev/null 2>&1) || mkstore_rc=$?
    else
        list_output=$("${mkstore_bin}" -wrl "${ks_dir}" -list \
            </dev/null 2>&1) || mkstore_rc=$?
    fi

    if [[ "${mkstore_rc}" -ne 0 ]]; then
        au_emit "WARN" "keystore keypair" \
            "mkstore -list failed (rc=${mkstore_rc}); run: ${manual_cmd}"
        return 0
    fi

    local has_pkey1=false has_pkey2=false
    [[ "${list_output}" == *"PKEY1"* ]] && has_pkey1=true
    [[ "${list_output}" == *"PKEY2"* ]] && has_pkey2=true

    if [[ "${has_pkey1}" == true && "${has_pkey2}" == true ]]; then
        au_emit "OK" "keystore keypair" "PKEY1 and PKEY2 present"
    else
        au_emit "FAIL" "keystore keypair" \
            "PKEY1/PKEY2 not found - create with: au_run.sh -config <cfg> -patch -load_password, then in console: group mos / add -user <mos-user> / save"
    fi
}

# Check the keystore directory, required files, permissions, and subdirectory.
au_check_keystore() {
    local ks_dir="$1"

    if [[ ! -d "${ks_dir}" ]]; then
        au_emit "FAIL" "keystore" "directory not found: ${ks_dir}"
        return 0
    fi

    local dir_perms
    dir_perms="$(_file_perms "${ks_dir}")"
    au_emit "OK" "keystore dir" "${ks_dir} (perms: ${dir_perms})"

    # Check .autoupgrade subdir: must not be a symlink and not group/world-writable
    local au_subdir="${ks_dir}/.autoupgrade"
    if [[ -e "${au_subdir}" ]]; then
        if [[ -L "${au_subdir}" ]]; then
            au_emit "FAIL" "keystore/.autoupgrade" \
                "is a symlink - AutoUpgrade refuses symlinked wallet subdirs"
        else
            local sub_perms
            sub_perms="$(_file_perms "${au_subdir}")"
            # Group/world-writable: last two digits have write bit (2 or 6 or 7 or 3)
            local sub_last="${sub_perms: -2}"
            local group_bit="${sub_last:0:1}" world_bit="${sub_last:1:1}"
            if [[ "${group_bit}" =~ [2367] || "${world_bit}" =~ [2367] ]]; then
                au_emit "FAIL" "keystore/.autoupgrade" \
                    "group/world-writable (perms ${sub_perms}) - AutoUpgrade refuses it"
            else
                au_emit "OK" "keystore/.autoupgrade" "perms ${sub_perms}"
            fi
        fi
    fi

    # Required wallet files
    local f perms
    for f in ewallet.p12 cwallet.sso; do
        local fpath="${ks_dir}/${f}"
        if [[ ! -f "${fpath}" ]]; then
            au_emit "FAIL" "keystore/${f}" "not found"
            continue
        fi
        if [[ ! -r "${fpath}" ]]; then
            au_emit "FAIL" "keystore/${f}" "not readable by $(id -un)"
            continue
        fi
        perms="$(_file_perms "${fpath}")"
        if [[ "${perms}" == "600" || "${perms}" == "0600" ]]; then
            au_emit "OK" "keystore/${f}" "present, perms ${perms}"
        else
            au_emit "WARN" "keystore/${f}" "present but perms ${perms} (expected 0600)"
        fi
    done

    au_keystore_keypair_check "${ks_dir}"
}
# - EOF Functions --------------------------------------------------------------

# - Parse Parameters -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)   au_show_help ;;
        --keystore)
            [[ $# -lt 2 ]] && { echo "ERROR: --keystore requires a value" >&2; exit 1; }
            KEYSTORE_DIR="$2"; shift 2 ;;
        --endpoints)
            [[ $# -lt 2 ]] && { echo "ERROR: --endpoints requires a value" >&2; exit 1; }
            ENDPOINTS_FILE="$2"; shift 2 ;;
        --timeout)
            [[ $# -lt 2 ]] && { echo "ERROR: --timeout requires a value" >&2; exit 1; }
            TIMEOUT="$2"; shift 2 ;;
        --quiet)    QUIET=true; shift ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --yes|--delete)
            # Accepted and silently ignored (no destructive operations)
            shift ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            echo "       Run ${SCRIPT_NAME} --help for usage." >&2
            exit 1 ;;
    esac
done
# - EOF Parse Parameters -------------------------------------------------------

# - Main -----------------------------------------------------------------------

# Resolve Java, proxy, and truststore (same resolution as run_autoupgrade.sh).
# A missing or unsupported Java is reported as FAIL; the network checks still run.
JAVA_OK=true
JAVA_ERROR=""
# au_resolve_java exits on error: probe it in a subshell to capture the message,
# then call it again in this shell to set JAVA_BIN / JAVA_VERSION_FULL
if JAVA_ERROR="$( (au_resolve_java) 2>&1 )"; then
    au_resolve_java
else
    JAVA_OK=false
    JAVA_ERROR="${JAVA_ERROR#ERROR: }"
fi
au_build_proxy_opts
au_resolve_truststore

# Build temp PEM bundle from truststore for curl --cacert alignment
if [[ "${JAVA_OK}" == true ]]; then
    au_build_truststore_pem
fi

# Load optional endpoint override file
if [[ -n "${ENDPOINTS_FILE}" ]]; then
    [[ -f "${ENDPOINTS_FILE}" ]] \
        || { echo "ERROR: Endpoints file not found: ${ENDPOINTS_FILE}" >&2; exit 1; }
    AU_ENDPOINTS=()
    while IFS= read -r _line; do
        [[ -z "${_line}" || "${_line}" == \#* ]] && continue
        AU_ENDPOINTS+=("${_line}")
    done < "${ENDPOINTS_FILE}"
fi

# Print resolved configuration
if [[ "${JAVA_OK}" == true ]]; then
    printf 'Java.......: %s (%s)\n' "${JAVA_BIN}" "${JAVA_VERSION_FULL}" >&2
else
    printf 'Java.......: %s\n' "${JAVA_ERROR}" >&2
fi
printf 'Proxy......: %s\n' "${PROXY_INFO:-none}" >&2
printf 'Truststore.: %s\n' "${TRUSTSTORE_INFO:-JDK default cacerts}" >&2
printf 'Keystore...: %s\n' "${KEYSTORE_DIR}" >&2
printf 'Timeout....: %ss\n' "${TIMEOUT}" >&2

# Dry-run: list what would be checked and exit
if [[ "${DRY_RUN}" == true ]]; then
    printf '\n[DRY-RUN] Endpoints:\n'
    for _entry in "${AU_ENDPOINTS[@]}"; do
        IFS='|' read -r _h _u _p _s <<< "${_entry}"
        printf '  %s (%s)\n' "${_u}" "${_p}"
    done
    printf '[DRY-RUN] Keystore: %s\n' "${KEYSTORE_DIR}"
    exit 0
fi

# --- Endpoint connectivity checks ---
printf '\n=== Endpoint Checks ===\n'
for _entry in "${AU_ENDPOINTS[@]}"; do
    IFS='|' read -r _host _url _purpose _source <<< "${_entry}"
    au_check_endpoint "${_host}" "${_url}" "${_purpose}"
done

# --- Java / truststore checks ---
printf '\n=== Java / Truststore ===\n'
if [[ "${JAVA_OK}" == true ]]; then
    au_emit "OK" "java" "${JAVA_BIN} (${JAVA_VERSION_FULL})"
    au_check_truststore
else
    au_emit "FAIL" "java" "${JAVA_ERROR} - set AUTOUPGRADE_JAVA_HOME"
    au_emit "WARN" "truststore" "not checked (no usable Java)"
fi

# --- AutoUpgrade JAR check ---
printf '\n=== AutoUpgrade JAR ===\n'
au_check_jar

# --- Keystore check ---
printf '\n=== Keystore ===\n'
au_check_keystore "${KEYSTORE_DIR}"

# --- Summary ---
printf '\n=== Summary ===\n'
printf 'FAIL: %d   WARN: %d\n' "${_FAIL_COUNT}" "${_WARN_COUNT}"
if [[ "${#_FLAGGED_HOSTS[@]}" -gt 0 ]]; then
    printf '\nNetwork team - allow via proxy / exempt from TLS inspection:\n'
    for _h in "${_FLAGGED_HOSTS[@]}"; do
        printf '  %s\n' "${_h}"
    done
fi

# Exit code based on results
if [[ "${_FAIL_COUNT}" -gt 0 ]]; then
    exit 1
elif [[ "${_WARN_COUNT}" -gt 0 ]]; then
    exit 2
fi
exit 0
# - EOF ------------------------------------------------------------------------
