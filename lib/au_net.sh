#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Module.....: au_net.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.10.09
# Version....: v0.6.0
# Purpose....: Java resolution, proxy, truststore and curl wrapper for
#              AutoUpgrade wrapper scripts. Functions moved from au_lib.sh .
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------

# Guard on function existence (au_resolve_java is defined in this module).
declare -F au_resolve_java >/dev/null 2>&1 && return 0

# Supported Java major versions.
# 8 and 11 are documented by Oracle; 17 and 21 work with jar 26.6 (tested).
# Java >21 is refused by AutoUpgrade (MAX_SUPPORTED_JAVA_VERSION=21).
: "${AUTOUPGRADE_JAVA_SUPPORTED:=8 11}"

# ------------------------------------------------------------------------------
# Function: au_resolve_java
# Purpose.: Resolve JAVA_BIN and JAVA_VERSION_FULL; validate major version.
# Args....: None
# Returns.: 0 on success; exits 1 on missing binary or unsupported version
# Globals.: Sets JAVA_BIN, JAVA_VERSION_FULL
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
        echo "ERROR: Unable to determine Java version from ${JAVA_BIN}" >&2
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
# Purpose.: Convert comma-separated no_proxy to Java nonProxyHosts format
# Args....: $1 - comma-separated no_proxy value
# Returns.: Pipe-separated string for -Dhttp.nonProxyHosts (stdout)
# Notes...: Leading dots become wildcards; CIDR entries skipped with WARN
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
# Purpose.: Derive Java proxy properties from environment; export https_proxy
# Args....: None
# Returns.: 0; appends to JAVA_OPTS; sets PROXY_INFO; exports https_proxy
# Priority: AUTOUPGRADE_PROXY > https_proxy > HTTPS_PROXY > http_proxy > HTTP_PROXY
# Notes...: "none" or empty: all proxy env vars are unset.
#           Credentials in URL are stripped with WARN.
#           After resolution: HTTP_PROXY and HTTPS_PROXY are always unset.
# ------------------------------------------------------------------------------
au_build_proxy_opts() {
    local proxy="${AUTOUPGRADE_PROXY:-${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}}"

    if [[ -z "${proxy}" || "${proxy}" == "none" ]]; then
        unset https_proxy HTTPS_PROXY http_proxy HTTP_PROXY
        return 0
    fi

    local scheme rest hostport host port
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
    # Strip userinfo: strip everything up to and including the last '@'
    if [[ "${rest}" == *@* ]]; then
        echo "WARN: Proxy credentials in URL are ignored (never passed to AutoUpgrade or curl)" >&2
        rest="${rest##*@}"
    fi
    hostport="${rest%%/*}"

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

    if [[ ! "${host}" =~ ^[A-Za-z0-9.-]+$ ]]; then
        echo "ERROR: Invalid proxy host: '${host}'" >&2
        exit 1
    fi

    if [[ ! "${port}" =~ ^[0-9]+$ ]] || [[ "${port}" -lt 1 || "${port}" -gt 65535 ]]; then
        echo "ERROR: Invalid proxy port: '${port}' (must be numeric 1-65535)" >&2
        exit 1
    fi

    JAVA_OPTS+=("-Dhttps.proxyHost=${host}" "-Dhttps.proxyPort=${port}"
                "-Dhttp.proxyHost=${host}"  "-Dhttp.proxyPort=${port}")
    # shellcheck disable=SC2034
    PROXY_INFO="${host}:${port}"

    export https_proxy="${scheme}${host}:${port}"
    export http_proxy="${scheme}${host}:${port}"
    # replace credential-bearing AUTOUPGRADE_PROXY with sanitized URL so
    # downstream processes cannot inherit credentials from the environment.
    # NOTE: trustStorePassword is passed on the command line and visible in ps(1).
    # An empty truststore password works for OS cacerts (certs-only JKS on OL/RHEL).
    export AUTOUPGRADE_PROXY="${scheme}${host}:${port}"
    unset HTTPS_PROXY HTTP_PROXY

    local np="${no_proxy:-${NO_PROXY:-}}"
    if [[ -n "${np}" ]]; then
        local np_java
        np_java="$(au_convert_no_proxy "${np}")"
        [[ -n "${np_java}" ]] && JAVA_OPTS+=("-Dhttp.nonProxyHosts=${np_java}")
        export no_proxy="${np}"
    fi
}

# ------------------------------------------------------------------------------
# Function: au_resolve_truststore
# Purpose.: Resolve OS truststore and emit -Djavax.net.ssl.trustStore* opts
# Args....: None
# Returns.: 0; appends to JAVA_OPTS; sets TRUSTSTORE_INFO
# Notes...: "none" -> no opts.
#           AUTOUPGRADE_TRUSTSTORE -> explicit path.
#           Otherwise: first readable candidate (/etc/pki or /etc/ssl).
#           AUTOUPGRADE_TRUSTSTORE_PASS: only added when explicitly set.
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

    [[ -z "${ts}" ]] && return 0

    if [[ ! -r "${ts}" ]]; then
        echo "ERROR: Truststore not readable: ${ts}" >&2
        exit 1
    fi

    JAVA_OPTS+=("-Djavax.net.ssl.trustStore=${ts}")
    if [[ -n "${AUTOUPGRADE_TRUSTSTORE_PASS:-}" ]]; then
        JAVA_OPTS+=("-Djavax.net.ssl.trustStorePassword=${AUTOUPGRADE_TRUSTSTORE_PASS}")
    fi
    # shellcheck disable=SC2034
    TRUSTSTORE_INFO="${ts}"
}

# ------------------------------------------------------------------------------
# Function: au_build_jvm_opts
# Purpose.: Assemble all JVM options: proxy, truststore, user opts, debug
# Args....: None
# Returns.: 0; extends JAVA_OPTS
# Notes...: AUTOUPGRADE_JAVA_OPTS word-split intentionally (space-separated flags)
#           AUTOUPGRADE_DEBUG_SSL=true appends -Djavax.net.debug=ssl:handshake
# ------------------------------------------------------------------------------
au_build_jvm_opts() {
    au_build_proxy_opts
    au_resolve_truststore

    if [[ -n "${AUTOUPGRADE_JAVA_OPTS:-}" ]]; then
        local -a _extra
        read -ra _extra <<< "${AUTOUPGRADE_JAVA_OPTS}"
        JAVA_OPTS+=("${_extra[@]}")
    fi

    if [[ "${AUTOUPGRADE_DEBUG_SSL:-false}" == "true" ]]; then
        JAVA_OPTS+=("-Djavax.net.debug=ssl:handshake")
    fi
}
