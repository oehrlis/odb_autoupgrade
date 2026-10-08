#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Module.....: au_lib.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Editor.....: Stefan Oehrli
# Date.......: 2026.10.08
# Version....: v0.5.0
# Purpose....: Sourceable library: Java, proxy, and truststore resolution for
#              AutoUpgrade wrapper scripts (bin/au_run.sh and
#              bin/au_check_connectivity.sh).
# Notes......: - Source this file from a wrapper script that has already
#                declared JAVA_OPTS=() and initialized PROXY_INFO / TRUSTSTORE_INFO
#              - Required files when deployed without the full repo:
#                  lib/au_lib.sh  (this file)
#                  bin/run_autoupgrade.sh
#                  jar/autoupgrade.jar
#              - Tested on macOS (BSD tools) and Linux
# Reference..: https://github.com/oehrlis/odb_autoupgrade
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.08 oehrli - initial version, extracted from bin/run_autoupgrade.sh
# 2026.10.08 oehrli - security: remove eval from au_source_env_file (CVE class)
#                     parse au_patch.env line-by-line (no source),
#                     fix proxy authority parsing (slash in password),
#                     expose AU_CFG_VARS from au_check_cfg_vars,
#                     pass trustStorePassword only when explicitly set
# ------------------------------------------------------------------------------

# Guard against multiple sourcing
[[ -n "${AU_LIB_SH_LOADED:-}" ]] && return 0
readonly AU_LIB_SH_LOADED=1

# Global array populated by au_check_cfg_vars; consumed by au_run.sh
# resolve_config to restrict envsubst to referenced variables only.
AU_CFG_VARS=()

# ------------------------------------------------------------------------------
# Function: au_set_defaults
# Purpose.: Apply built-in defaults for AU_* variables not yet set by the
#           caller environment or env file. Called from au_run.sh right after
#           au_source_env_file so precedence is:
#             caller env > env file > au_patch.env (for AU_PATCH) > built-in
# Args....: None
# Returns.: 0; exports AU_* variables only if not already set
# Globals.: Reads AUTOUPGRADE_BASE (must be set by caller before sourcing).
#           Sets/exports: AU_TARGET_VERSION, AU_PLATFORM, AU_PATCH,
#           AU_GOLD_IMAGE, AU_LOG_DIR, AU_KEYSTORE, AU_DOWNLOAD_FOLDER.
#           Never sets AU_SOURCE_HOME, AU_TARGET_HOME, AU_SID.
# Notes...: au_patch.env is read line-by-line (never sourced). Only the form
#           AU_PATCH=<value> is accepted; value must match ^[A-Za-z0-9_.,:-]+$
#           (optional single or double quotes stripped). Other lines are
#           ignored with a WARN naming the line number. The file is refused
#           (WARN, falls back to RECOMMENDED) if it is a symlink, not owned
#           by the current user ($EUID), or group/world-writable.
# ------------------------------------------------------------------------------
au_set_defaults() {
    : "${AU_TARGET_VERSION:=19}"; export AU_TARGET_VERSION
    : "${AU_PLATFORM:=LINUX.X64}"; export AU_PLATFORM
    : "${AU_GOLD_IMAGE:=NO}"; export AU_GOLD_IMAGE
    : "${AU_LOG_DIR:=${AUTOUPGRADE_BASE}/logs}"; export AU_LOG_DIR
    : "${AU_KEYSTORE:=${AUTOUPGRADE_BASE}/keystore}"; export AU_KEYSTORE
    : "${AU_DOWNLOAD_FOLDER:=${AUTOUPGRADE_BASE}/patches}"; export AU_DOWNLOAD_FOLDER

    # AU_PATCH: consult au_patch.env when not yet set by caller or env file
    local _au_patch_pinned=false
    if [[ -z "${AU_PATCH:-}" ]]; then
        local _patch_env="${AU_DOWNLOAD_FOLDER}/au_patch.env"
        if [[ -f "${_patch_env}" ]]; then
            # Security: refuse symlink
            if [[ -L "${_patch_env}" ]]; then
                echo "WARN: au_patch.env is a symlink, skipping (using RECOMMENDED)" >&2
            else
                # Security: ownership check
                local _pf_uid
                _pf_uid=$(stat -c '%u' "${_patch_env}" 2>/dev/null) \
                    || _pf_uid=$(stat -f '%u' "${_patch_env}" 2>/dev/null) \
                    || _pf_uid=""
                local _pf_ok=true
                if [[ -n "${_pf_uid}" && "${_pf_uid}" != "$(id -u)" ]]; then
                    echo "WARN: au_patch.env not owned by current user (owner=${_pf_uid}), skipping (using RECOMMENDED)" >&2
                    _pf_ok=false
                fi
                # Security: refuse group/world-writable
                if [[ "${_pf_ok}" == true ]]; then
                    local _pf_perms
                    _pf_perms=$(stat -c '%a' "${_patch_env}" 2>/dev/null) \
                        || _pf_perms=$(stat -f '%Lp' "${_patch_env}" 2>/dev/null) \
                        || _pf_perms=""
                    if [[ -n "${_pf_perms}" ]]; then
                        local _pf_last="${_pf_perms: -2}"
                        local _pf_g="${_pf_last:0:1}" _pf_w="${_pf_last:1:1}"
                        if [[ "${_pf_g}" =~ [2367] || "${_pf_w}" =~ [2367] ]]; then
                            echo "WARN: au_patch.env is group/world-writable (perms ${_pf_perms}), skipping (using RECOMMENDED)" >&2
                            _pf_ok=false
                        fi
                    fi
                fi
                # Parse line by line: only AU_PATCH=<value> accepted
                if [[ "${_pf_ok}" == true ]]; then
                    local _lineno=0 _line _val
                    while IFS= read -r _line || [[ -n "${_line}" ]]; do
                        _lineno=$(( _lineno + 1 ))
                        # Strip leading/trailing whitespace
                        local _trim="${_line#"${_line%%[![:space:]]*}"}"
                        _trim="${_trim%"${_trim##*[![:space:]]}"}"
                        [[ -z "${_trim}" || "${_trim}" == '#'* ]] && continue
                        if [[ "${_trim}" == AU_PATCH=* ]]; then
                            _val="${_trim#AU_PATCH=}"
                            # Strip optional surrounding quotes
                            if [[ "${_val}" == '"'*'"' ]]; then
                                _val="${_val#\"}"; _val="${_val%\"}"
                            elif [[ "${_val}" == "'"*"'" ]]; then
                                _val="${_val#\'}"; _val="${_val%\'}"
                            fi
                            # Validate: only safe characters, no command substitution
                            if [[ "${_val}" =~ ^[A-Za-z0-9_.,:-]+$ ]]; then
                                AU_PATCH="${_val}"
                                _au_patch_pinned=true
                            else
                                echo "WARN: au_patch.env line ${_lineno}: AU_PATCH value '${_val}' contains invalid characters, ignored" >&2
                            fi
                        else
                            echo "WARN: au_patch.env line ${_lineno}: ignored: ${_trim}" >&2
                        fi
                    done < "${_patch_env}"
                fi
            fi
        fi
    fi
    : "${AU_PATCH:=RECOMMENDED}"; export AU_PATCH

    if [[ "${_au_patch_pinned}" == true ]]; then
        echo "Patch list.: ${AU_PATCH} (pinned by ${AU_DOWNLOAD_FOLDER}/au_patch.env)" >&2
    else
        echo "Patch list.: ${AU_PATCH}" >&2
    fi
}

# Supported Java major versions for AutoUpgrade.
# Java 8 and 11 are confirmed by Oracle docs and validated against jar 26.6.
# Java 17 and 21 also work with jar 26.6 (tested); Java 25 is refused.
# Keep the default conservative ("8 11"); override with
# AUTOUPGRADE_JAVA_SUPPORTED="8 11 17 21" if your environment needs it.
: "${AUTOUPGRADE_JAVA_SUPPORTED:=8 11}"

# ------------------------------------------------------------------------------
# Function: au_resolve_java
# Purpose.: Resolve JAVA_BIN and JAVA_VERSION_FULL; validate major version.
# Args....: None
# Returns.: 0 on success; exits 1 on missing binary or unsupported version
# Globals.: Sets JAVA_BIN, JAVA_VERSION_FULL (both exported by caller)
# Priority: AUTOUPGRADE_JAVA_HOME > ORACLE_HOME/jdk/bin/java > PATH java
# ------------------------------------------------------------------------------
au_resolve_java() {
    if [[ -n "${AUTOUPGRADE_JAVA_HOME:-}" ]]; then
        JAVA_BIN="${AUTOUPGRADE_JAVA_HOME}/bin/java"
        if [[ ! -x "${JAVA_BIN}" ]]; then
            echo "ERROR: Java not found at ${JAVA_BIN} (AUTOUPGRADE_JAVA_HOME)" >&2
            exit 1
        fi
    elif [[ -n "${ORACLE_HOME:-}" && -x "${ORACLE_HOME}/jdk/bin/java" ]]; then
        JAVA_BIN="${ORACLE_HOME}/jdk/bin/java"
    else
        JAVA_BIN="$(command -v java 2>/dev/null)" || true
        if [[ -z "${JAVA_BIN}" ]]; then
            echo "ERROR: Java is not available or not in PATH." >&2
            exit 1
        fi
    fi

    JAVA_VERSION_FULL=$("${JAVA_BIN}" -version 2>&1 | awk -F '"' '/version/ {print $2}') || true
    if [[ -z "${JAVA_VERSION_FULL}" ]]; then
        echo "ERROR: Unable to determine Java version from ${JAVA_BIN} (no JDK installed?)" >&2
        exit 1
    fi

    local major="${JAVA_VERSION_FULL%%.*}"
    if [[ "${major}" == "1" ]]; then
        local _rest="${JAVA_VERSION_FULL#*.}"
        major="${_rest%%.*}"
    fi

    local _sm _found=false
    for _sm in ${AUTOUPGRADE_JAVA_SUPPORTED}; do
        [[ "${major}" == "${_sm}" ]] && _found=true && break
    done

    if [[ "${_found}" == false ]]; then
        echo "ERROR: Unsupported Java version: ${JAVA_VERSION_FULL}" >&2
        echo "       AutoUpgrade requires one of: ${AUTOUPGRADE_JAVA_SUPPORTED}" >&2
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Function: au_convert_no_proxy
# Purpose.: Convert a comma-separated no_proxy string to Java nonProxyHosts
# Args....: $1 - comma-separated no_proxy value
# Returns.: Pipe-separated string suitable for -Dhttp.nonProxyHosts (stdout)
# Notes...: Leading dots become wildcards: .example.com -> *.example.com
#           CIDR entries are skipped with a WARN to stderr (unsupported by Java)
#           Empty/whitespace entries are silently ignored
# ------------------------------------------------------------------------------
au_convert_no_proxy() {
    local np="$1"
    local entry list=""
    local -a entries
    IFS=',' read -ra entries <<< "${np}"
    for entry in "${entries[@]}"; do
        entry="${entry// /}"
        [[ -z "${entry}" ]] && continue
        if [[ "${entry}" == */* ]]; then
            echo "WARN: Skipping CIDR no_proxy entry '${entry}' (Java does not support CIDR in nonProxyHosts)" >&2
            continue
        fi
        [[ "${entry}" == .* ]] && entry="*${entry}"
        list="${list:+${list}|}${entry}"
    done
    echo "${list}"
}

# ------------------------------------------------------------------------------
# Function: au_build_proxy_opts
# Purpose.: Derive Java proxy system properties from proxy environment variables
#           and export https_proxy so AutoUpgrade's native proxy path and the
#           -D properties agree.
# Args....: None
# Returns.: 0; appends to JAVA_OPTS; sets PROXY_INFO; exports https_proxy
# Priority: AUTOUPGRADE_PROXY > https_proxy > HTTPS_PROXY > http_proxy > HTTP_PROXY
# Notes...: AutoUpgrade (jar 26.6) reads System.getenv("https_proxy") directly;
#           the -Dhttps.proxyHost/Port properties apply only when https_proxy
#           is unset. This function exports a sanitized lowercase https_proxy so
#           both paths use the same host:port without credentials.
#           "none" or empty: all proxy env vars are unset so AU cannot pick up
#           a proxy from the environment.
#           Default port when URL contains no port: 80.
#           Credentials in URL (user:pass@host) are stripped with WARN. Passwords
#           containing '/' are handled correctly by stripping up to the last '@'.
#           Port must be numeric 1-65535; host must match ^[A-Za-z0-9.-]+$.
#           IPv6 bracketed addresses are rejected with ERROR (not supported).
#           After resolution: HTTP_PROXY and HTTPS_PROXY are always unset to
#           prevent AutoUpgrade inheriting a competing (possibly credentialed) URL.
#           no_proxy is kept unchanged and re-exported; AU matches it itself.
#           Emits: -Dhttps.proxyHost/Port, -Dhttp.proxyHost/Port,
#                  -Dhttp.nonProxyHosts (from no_proxy / NO_PROXY)
# ------------------------------------------------------------------------------
au_build_proxy_opts() {
    local proxy="${AUTOUPGRADE_PROXY:-${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}}"

    if [[ -z "${proxy}" || "${proxy}" == "none" ]]; then
        # Ensure AutoUpgrade cannot inherit a proxy from the environment
        unset https_proxy HTTPS_PROXY http_proxy HTTP_PROXY
        return 0
    fi

    local scheme rest hostport host port
    # Preserve scheme for the exported https_proxy URL; bare host:port -> http
    if [[ "${proxy}" == *://* ]]; then
        scheme="${proxy%%://*}"
        rest="${proxy#*://}"
    else
        scheme="http"
        rest="${proxy}"
    fi
    case "${scheme}" in
        http|https) scheme="${scheme}://" ;;
        *)
            echo "ERROR: Unsupported proxy scheme '${scheme}' (http or https only)" >&2
            exit 1
            ;;
    esac
    # Strip userinfo: if '@' present, strip everything up to and including the last '@'.
    # Handles passwords containing '/' correctly (##*@ strips up to rightmost @).
    if [[ "${rest}" == *@* ]]; then
        echo "WARN: Proxy credentials in URL are ignored (never passed to AutoUpgrade or curl)" >&2
        rest="${rest##*@}"
    fi
    hostport="${rest%%/*}"  # strip path / trailing slash

    # Reject bracketed IPv6
    if [[ "${hostport}" == \[* ]]; then
        echo "ERROR: IPv6 proxy addresses are not supported: ${hostport}" >&2
        exit 1
    fi

    host="${hostport%%:*}"
    if [[ "${hostport}" == *:* ]]; then
        port="${hostport##*:}"
    else
        port="80"
    fi

    # Validate host
    if [[ ! "${host}" =~ ^[A-Za-z0-9.-]+$ ]]; then
        echo "ERROR: Invalid proxy host: '${host}'" >&2
        exit 1
    fi

    # Validate port: numeric and 1-65535
    if [[ ! "${port}" =~ ^[0-9]+$ ]] || [[ "${port}" -lt 1 || "${port}" -gt 65535 ]]; then
        echo "ERROR: Invalid proxy port: '${port}' (must be numeric 1-65535)" >&2
        exit 1
    fi

    JAVA_OPTS+=("-Dhttps.proxyHost=${host}" "-Dhttps.proxyPort=${port}"
                "-Dhttp.proxyHost=${host}"  "-Dhttp.proxyPort=${port}")
    # shellcheck disable=SC2034  # PROXY_INFO is read by the caller script
    PROXY_INFO="${host}:${port}"

    # Export sanitized lowercase https_proxy and http_proxy for AutoUpgrade's native path
    export https_proxy="${scheme}${host}:${port}"
    export http_proxy="${scheme}${host}:${port}"
    # Unset uppercase variants to prevent AutoUpgrade picking up a competing value
    unset HTTPS_PROXY HTTP_PROXY

    local np="${no_proxy:-${NO_PROXY:-}}"
    if [[ -n "${np}" ]]; then
        local np_java
        np_java="$(au_convert_no_proxy "${np}")"
        [[ -n "${np_java}" ]] && JAVA_OPTS+=("-Dhttp.nonProxyHosts=${np_java}")
        # Keep no_proxy exported for AutoUpgrade's own matching
        export no_proxy="${np}"
    fi
}

# ------------------------------------------------------------------------------
# Function: au_resolve_truststore
# Purpose.: Resolve OS truststore and emit -Djavax.net.ssl.trustStore* opts
# Args....: None
# Returns.: 0; appends to JAVA_OPTS; sets TRUSTSTORE_INFO
# Notes...: "none" -> no opts (use JDK bundled cacerts).
#           AUTOUPGRADE_TRUSTSTORE -> explicit path (must be readable).
#           Otherwise: first readable path from candidate list.
#           Candidates: AUTOUPGRADE_TRUSTSTORE_CANDIDATES (space-separated,
#             useful in tests) or the built-in defaults:
#               /etc/pki/ca-trust/extracted/java/cacerts  (OL / RHEL)
#               /etc/ssl/certs/java/cacerts                (Debian / Ubuntu / SLES)
#           If no candidate is found -> JDK default (no opts appended).
#           AUTOUPGRADE_TRUSTSTORE_PASS: password for the truststore.
#             - The -Djavax.net.ssl.trustStorePassword property is ONLY added
#               when AUTOUPGRADE_TRUSTSTORE_PASS is explicitly set.
#             - OS cacerts on OL/RHEL load without a password (certs-only JKS).
#             - For PKCS12 truststores that require a password, set
#               AUTOUPGRADE_TRUSTSTORE_PASS explicitly.
# ------------------------------------------------------------------------------
au_resolve_truststore() {
    local ts="${AUTOUPGRADE_TRUSTSTORE:-}"
    [[ "${ts}" == "none" ]] && return 0

    if [[ -z "${ts}" ]]; then
        local candidate
        if [[ -n "${AUTOUPGRADE_TRUSTSTORE_CANDIDATES:-}" ]]; then
            for candidate in ${AUTOUPGRADE_TRUSTSTORE_CANDIDATES}; do
                [[ -r "${candidate}" ]] && ts="${candidate}" && break
            done
        else
            for candidate in \
                "/etc/pki/ca-trust/extracted/java/cacerts" \
                "/etc/ssl/certs/java/cacerts"; do
                [[ -r "${candidate}" ]] && ts="${candidate}" && break
            done
        fi
    fi

    [[ -z "${ts}" ]] && return 0   # no candidate readable -> use JDK default

    if [[ ! -r "${ts}" ]]; then
        echo "ERROR: Truststore not readable: ${ts}" >&2
        exit 1
    fi

    JAVA_OPTS+=("-Djavax.net.ssl.trustStore=${ts}")
    # Only add the password property when explicitly configured.
    # OS cacerts on OL/RHEL are certs-only JKS and load without a password.
    if [[ -n "${AUTOUPGRADE_TRUSTSTORE_PASS:-}" ]]; then
        JAVA_OPTS+=("-Djavax.net.ssl.trustStorePassword=${AUTOUPGRADE_TRUSTSTORE_PASS}")
    fi
    # shellcheck disable=SC2034  # TRUSTSTORE_INFO is read by the caller script
    TRUSTSTORE_INFO="${ts}"
}

# ------------------------------------------------------------------------------
# Function: au_build_jvm_opts
# Purpose.: Assemble all JVM options: proxy, truststore, user opts, debug
# Args....: None
# Returns.: 0; extends JAVA_OPTS
# Notes...: AUTOUPGRADE_JAVA_OPTS is word-split intentionally (space-separated
#             JVM flags such as "-Xmx2g -XX:+UseG1GC").
#           AUTOUPGRADE_DEBUG_SSL=true appends -Djavax.net.debug=ssl:handshake
#           JVM options are passed directly on the command line; this function
#           never touches JAVA_TOOL_OPTIONS.
# ------------------------------------------------------------------------------
au_build_jvm_opts() {
    au_build_proxy_opts
    au_resolve_truststore

    if [[ -n "${AUTOUPGRADE_JAVA_OPTS:-}" ]]; then
        local -a _extra
        # Word split is intentional for AUTOUPGRADE_JAVA_OPTS
        read -ra _extra <<< "${AUTOUPGRADE_JAVA_OPTS}"
        JAVA_OPTS+=("${_extra[@]}")
    fi

    if [[ "${AUTOUPGRADE_DEBUG_SSL:-false}" == "true" ]]; then
        JAVA_OPTS+=("-Djavax.net.debug=ssl:handshake")
    fi
}

# ------------------------------------------------------------------------------
# Function: au_check_cfg_vars
# Purpose.: Verify all ${VAR} and $VAR references in a config file are set in
#           the environment. Exits 1 with a list of unset variable names if any
#           are missing. Empty-but-set variables are allowed.
#           Also populates the global AU_CFG_VARS array with all referenced
#           variable names (used by au_run.sh to restrict envsubst).
# Args....: $1 - path to the config file
# Returns.: 0 if all variables are set; exits 1 listing each unset name
# Globals.: Sets AU_CFG_VARS (global array of all referenced variable names)
# Notes...: Lines where the first non-whitespace character is # are skipped.
#           Uses ${!name+isset} indirect expansion which is safe under set -u
#           (the + form never raises nounset errors).
# ------------------------------------------------------------------------------
au_check_cfg_vars() {
    local cfg_file="$1"
    local -a var_names=()
    local var_name missing=""

    [[ -f "${cfg_file}" ]] || { echo "ERROR: Config file not found: ${cfg_file}" >&2; exit 1; }

    # Filter comment lines (first non-whitespace char is #), then collect all
    # referenced variable names from ${VAR} and bare $VAR forms, deduplicated.
    local filtered
    filtered="$(grep -vE '^[[:space:]]*#' "${cfg_file}" 2>/dev/null || true)"

    while IFS= read -r var_name; do
        [[ -n "${var_name}" ]] && var_names+=("${var_name}")
    done < <(
        {
            # ${VAR} form - character-class brackets avoid \{ / \} ERE ambiguity
            grep -oE '\$[{][A-Za-z_][A-Za-z0-9_]*[}]' <<< "${filtered}" \
                | sed -e 's/^\$[{]//' -e 's/[}]$//'
            # Bare $VAR form ($ followed directly by letter/underscore, not {)
            grep -oE '\$[A-Za-z_][A-Za-z0-9_]*' <<< "${filtered}" \
                | sed 's/^\$//'
        } 2>/dev/null | sort -u
    )

    # Expose collected names for envsubst restriction in au_run.sh.
    # AU_CFG_VARS is intentionally used by the calling script (au_run.sh);
    # it is not local to this function.
    # shellcheck disable=SC2034
    AU_CFG_VARS=("${var_names[@]+"${var_names[@]}"}")

    for var_name in "${var_names[@]+"${var_names[@]}"}"; do
        # ${!var_name+isset}: expands to "isset" if the variable named by
        # var_name is set (even to ""), otherwise expands to empty.
        # shellcheck disable=SC2016
        if [[ -z "${!var_name+isset}" ]]; then
            missing="${missing:+${missing}, }${var_name}"
        fi
    done

    if [[ -n "${missing}" ]]; then
        echo "ERROR: Config references unset variables: ${missing}" >&2
        exit 1
    fi

    return 0
}

# ------------------------------------------------------------------------------
# Function: au_source_env_file
# Purpose.: Source an optional site env file with set -a, but let variables
#           already exported by the caller win over values from the file.
# Args....: $1 - path to the env file (missing file is not an error)
# Returns.: 0; exits 1 on security violation (symlink / ownership / perms)
# Notes...: Precedence: caller environment > env file > built-in defaults.
#           Security checks before sourcing:
#             - Refuses symlinks (ERROR, exit 1)
#             - Refuses files not owned by $EUID (ERROR, exit 1)
#             - Refuses group/world-writable files (ERROR, exit 1)
#           Caller-exported variables are saved without eval (using compgen -e
#           and ${!name:-} indirect expansion) and restored after sourcing with
#           export "name=value", so no shell code in values is ever executed.
#           This eliminates the eval injection risk of the previous approach
#           (export -p | eval).
# ------------------------------------------------------------------------------
au_source_env_file() {
    local env_file="$1"
    [[ -f "${env_file}" ]] || return 0

    # Security: refuse symlink
    if [[ -L "${env_file}" ]]; then
        echo "ERROR: env file is a symlink, refusing to source: ${env_file}" >&2
        exit 1
    fi

    # Security: ownership check (portable: GNU stat -c %u / BSD stat -f %u)
    local _file_uid
    _file_uid=$(stat -c '%u' "${env_file}" 2>/dev/null) \
        || _file_uid=$(stat -f '%u' "${env_file}" 2>/dev/null) \
        || _file_uid=""
    if [[ -n "${_file_uid}" && "${_file_uid}" != "$(id -u)" ]]; then
        echo "ERROR: env file not owned by current user (owner=${_file_uid}, uid=$(id -u)): ${env_file}" >&2
        exit 1
    fi

    # Security: refuse group/world-writable
    local _file_perms
    _file_perms=$(stat -c '%a' "${env_file}" 2>/dev/null) \
        || _file_perms=$(stat -f '%Lp' "${env_file}" 2>/dev/null) \
        || _file_perms=""
    if [[ -n "${_file_perms}" ]]; then
        local _plast="${_file_perms: -2}"
        local _pg="${_plast:0:1}" _pw="${_plast:1:1}"
        if [[ "${_pg}" =~ [2367] || "${_pw}" =~ [2367] ]]; then
            echo "ERROR: env file is group/world-writable (perms ${_file_perms}), refusing: ${env_file}" >&2
            exit 1
        fi
    fi

    # Capture caller's exported variable names and values without eval.
    # compgen -e lists all currently exported variable names.
    # ${!_n:-} is safe under set -u (returns empty for unset; caller vars are set).
    local -a _caller_names=() _caller_values=()
    local _n
    while IFS= read -r _n; do
        [[ -n "${_n}" ]] || continue
        _caller_names+=("${_n}")
        _caller_values+=("${!_n:-}")
    done < <(compgen -e)

    set -a
    # shellcheck source=/dev/null
    . "${env_file}"
    set +a

    # Restore caller values: caller env wins over env file.
    # export "NAME=VALUE" is safe regardless of value content (no eval, no code
    # execution even when the value contains $(...) or backticks).
    # Only values the env file changed are restored; unchanged and readonly
    # variables (e.g. an exported SHELLOPTS) are never assigned, because an
    # assignment to a readonly variable aborts the script despite || true.
    local _i _n
    for _i in "${!_caller_names[@]}"; do
        _n="${_caller_names[_i]}"
        [[ "${!_n-}" == "${_caller_values[_i]}" ]] && continue
        export "${_n}=${_caller_values[_i]}"
    done

    echo "Env file...: ${env_file}" >&2
}
