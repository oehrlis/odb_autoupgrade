#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Name.......: au_run.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Editor.....: Stefan Oehrli
# Date.......: 2026.10.08
# Version....: v0.5.0
# Purpose....: Wrapper script to run Oracle AutoUpgrade with proxy, truststore,
#              and envsubst support.
# Notes......: - AUTOUPGRADE_BASE derived from script location; the legacy
#                layout (bin/ etc/ jar/ keystore/ patches/ logs/) works in place.
#              - Sources ${AUTOUPGRADE_BASE}/etc/autoupgrade.env with set -a
#                when present; caller environment wins over the env file.
#              - Java: AUTOUPGRADE_JAVA_HOME > ORACLE_HOME/jdk/bin/java > PATH
#              - -config: resolved as absolute, CWD-relative, or
#                AUTOUPGRADE_BASE/etc-relative; env vars expanded via envsubst.
#              - AUTOUPGRADE_DRY_RUN=true prints the command line (secrets
#                masked) and exits 0 without running AutoUpgrade.
#              - AutoUpgrade exit code is propagated; never swallowed by set -e.
#
#              Environment variables (all optional; can be set in autoupgrade.env):
#                AUTOUPGRADE_PROXY           Proxy URL; "none" disables proxy
#                AUTOUPGRADE_TRUSTSTORE      Truststore path; "none" = JDK default
#                AUTOUPGRADE_TRUSTSTORE_PASS Truststore password (only passed when set)
#                AUTOUPGRADE_JAVA_HOME       JDK to use instead of PATH / ORACLE_HOME
#                AUTOUPGRADE_JAVA_OPTS       Additional JVM options (word-split)
#                AUTOUPGRADE_DEBUG_SSL       true = enable SSL handshake debug
#                AUTOUPGRADE_DRY_RUN         true = print java cmd, exit 0
#
# Reference..: https://github.com/oehrlis/odb_autoupgrade
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2025.06.17 oehrli - added AUTOUPGRADE_BASE env variable
# 2026.10.08 oehrli - port ref/run_autoupgrade_v0.5.0: set -euo pipefail,
#                     lib/au_lib.sh, BSD-safe mktemp/trap, dry-run,
#                     --help, remove legacy require_java_8_or_11 / emojis,
#                     propagate exit code with || rc=$?
# 2026.10.08 oehrli - renamed from run_autoupgrade.sh; added au_set_defaults
# ------------------------------------------------------------------------------

set -euo pipefail

# - Default Values -------------------------------------------------------------
SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")
SCRIPT_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SCRIPT_BASE="$(dirname "${SCRIPT_BIN_DIR}")"
export AUTOUPGRADE_BASE="${SCRIPT_BASE}"

SCRIPT_JAR_DIR="${AUTOUPGRADE_BASE}/jar"
JAR_FILE="${SCRIPT_JAR_DIR}/autoupgrade.jar"
AUTOUPGRADE_ENV_FILE="${AUTOUPGRADE_BASE}/etc/autoupgrade.env"
TMP_CFG=""
JAVA_OPTS=()
PROXY_INFO=""
TRUSTSTORE_INFO=""
JAVA_BIN=""
JAVA_VERSION_FULL=""
# - EOF Default Values ---------------------------------------------------------

# - Load Network Library -------------------------------------------------------
# shellcheck source=lib/au_lib.sh
. "${SCRIPT_BIN_DIR}/../lib/au_lib.sh"
# - EOF Load Network Library ---------------------------------------------------

# - Site Settings --------------------------------------------------------------
# Optional etc/autoupgrade.env; caller environment wins over the file
au_source_env_file "${AUTOUPGRADE_ENV_FILE}"
# Apply built-in defaults for AU_* variables not yet set
au_set_defaults
# - EOF Site Settings ----------------------------------------------------------

# - Functions ------------------------------------------------------------------

# Print usage and exit
function show_help {
    cat >&2 <<HELP
Usage: ${SCRIPT_NAME} [--help] [-config <file>] [<autoupgrade-args>...]

Wrapper for Oracle AutoUpgrade (jar/autoupgrade.jar). Passes all arguments
directly to AutoUpgrade; only -config is intercepted to resolve and expand
environment variables before passing the resolved copy to AutoUpgrade.

Wrapper-only options (must appear before AutoUpgrade args):
  --help        Show this message and exit (AutoUpgrade uses -help with one dash)

Environment variables:
  AUTOUPGRADE_PROXY            Proxy URL; overrides https_proxy / http_proxy.
                               "none" disables proxy.
  AUTOUPGRADE_TRUSTSTORE       Truststore path. "none" uses the JDK default.
  AUTOUPGRADE_TRUSTSTORE_PASS  Truststore password (only passed when set).
  AUTOUPGRADE_JAVA_HOME        JDK home to use instead of PATH / ORACLE_HOME.
  AUTOUPGRADE_JAVA_OPTS        Additional JVM options (word-split on spaces).
  AUTOUPGRADE_DEBUG_SSL        true = add -Djavax.net.debug=ssl:handshake.
  AUTOUPGRADE_DRY_RUN          true = print java command line, exit 0.

Config file is looked up in this order:
  1. Absolute path
  2. Relative to current working directory
  3. Relative to \${AUTOUPGRADE_BASE}/etc/
HELP
    exit 0
}

# Print error to stderr and exit 1
function error_exit {
    echo "ERROR: $1" >&2
    exit 1
}

# Remove temporary config on exit.
# Uses if/fi to ensure the function always returns 0; a bare
# [[ ... ]] && rm construct would exit 1 when the condition is false and
# (with set -e active) corrupt the script's exit code via the trap.
# shellcheck disable=SC2329  # invoked via trap
function cleanup {
    if [[ -n "${TMP_CFG}" && -f "${TMP_CFG}" ]]; then
        rm -f "${TMP_CFG}"
    fi
}

# Resolve config path: absolute > CWD > AUTOUPGRADE_BASE/etc
function resolve_config_path {
    local input_path="$1"

    if [[ "${input_path}" = /* ]]; then
        [[ -f "${input_path}" ]] && echo "${input_path}" && return
    fi

    if [[ -f "${PWD}/${input_path}" ]]; then
        echo "${PWD}/${input_path}" && return
    fi

    if [[ -f "${AUTOUPGRADE_BASE}/etc/${input_path}" ]]; then
        echo "${AUTOUPGRADE_BASE}/etc/${input_path}" && return
    fi

    if [[ -f "${AUTOUPGRADE_BASE}/etc/$(basename "${input_path}")" ]]; then
        echo "${AUTOUPGRADE_BASE}/etc/$(basename "${input_path}")" && return
    fi

    error_exit "Configuration file not found: ${input_path}"
}

# Expand environment variables in config using envsubst into a temp file.
# Restricts substitution to variables referenced in the config (AU_CFG_VARS,
# populated by au_check_cfg_vars). Rejects any referenced variable whose value
# contains a newline or carriage return to prevent header-injection attacks.
function resolve_config {
    local config_path="$1"
    command -v envsubst >/dev/null 2>&1 || error_exit "envsubst not found (install gettext)"
    # BSD mktemp has no --suffix; AutoUpgrade accepts any readable path
    TMP_CFG="$(mktemp "${TMPDIR:-/tmp}/autoupgrade_resolved_XXXXXX")"
    echo "Resolving environment variables in config: ${config_path}" >&2

    # Build restricted envsubst variable list from AU_CFG_VARS.
    # Reject variables whose values contain newline or carriage return.
    local _envsubst_vars="" _v _val
    for _v in "${AU_CFG_VARS[@]+"${AU_CFG_VARS[@]}"}"; do
        _val="${!_v:-}"
        if [[ "${_val}" == *$'\n'* || "${_val}" == *$'\r'* ]]; then
            error_exit "Variable ${_v} value contains a newline or carriage return (possible injection)"
        fi
        _envsubst_vars="${_envsubst_vars:+${_envsubst_vars} }\${${_v}}"
    done

    if [[ -n "${_envsubst_vars}" ]]; then
        envsubst "${_envsubst_vars}" < "${config_path}" > "${TMP_CFG}"
    else
        cp "${config_path}" "${TMP_CFG}"
    fi
}

# Mask sensitive values in a command-line display string.
# Masks any argument matching *[Pp]assword=* or *[Pp]ass=* by replacing
# the value (everything after the '=') with '****'.
function mask_cmd {
    local arg masked=""
    for arg in "$@"; do
        if [[ "${arg}" == *[Pp]assword=* || "${arg}" == *[Pp]ass=* ]]; then
            arg="${arg%%=*}=****"
        fi
        masked="${masked:+${masked} }${arg}"
    done
    echo "${masked}"
}
# - EOF Functions --------------------------------------------------------------

# - Parse Parameters -----------------------------------------------------------
ARGS=()
CONFIG_FILE=""
RESOLVE_CONFIG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            show_help
            ;;
        -config)
            [[ $# -lt 2 ]] && error_exit "-config requires a value"
            CONFIG_FILE="$(resolve_config_path "$2")"
            RESOLVE_CONFIG=true
            shift 2
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done
# - EOF Parse Parameters -------------------------------------------------------

# - Main Script Logic ----------------------------------------------------------
trap cleanup EXIT

# Resolve Java binary and validate version
au_resolve_java

# Verify AutoUpgrade JAR exists
[[ -f "${JAR_FILE}" ]] || error_exit "AutoUpgrade JAR not found at ${JAR_FILE}"

# Build all JVM options (proxy, truststore, user opts, debug)
au_build_jvm_opts

# Print info line to stderr
echo "Java.......: ${JAVA_BIN} (${JAVA_VERSION_FULL})" >&2
echo "Proxy......: ${PROXY_INFO:-none}" >&2
echo "Truststore.: ${TRUSTSTORE_INFO:-JDK default cacerts}" >&2

# Resolve config if -config was provided
if [[ "${RESOLVE_CONFIG}" == true ]]; then
    au_check_cfg_vars "${CONFIG_FILE}"
    resolve_config "${CONFIG_FILE}"
    [[ -f "${TMP_CFG}" ]] || error_exit "Resolved config file not created: ${TMP_CFG}"
    FULL_CMD=("${JAVA_BIN}" "${JAVA_OPTS[@]}" -jar "${JAR_FILE}" -config "${TMP_CFG}" "${ARGS[@]}")
else
    FULL_CMD=("${JAVA_BIN}" "${JAVA_OPTS[@]}" -jar "${JAR_FILE}" "${ARGS[@]}")
fi

# Dry-run: print masked command line and exit
if [[ "${AUTOUPGRADE_DRY_RUN:-false}" == "true" ]]; then
    echo "DRY-RUN: $(mask_cmd "${FULL_CMD[@]}")" >&2
    exit 0
fi

# Run AutoUpgrade; propagate exit code (|| prevents set -e from triggering)
rc=0
"${FULL_CMD[@]}" || rc=$?
exit "${rc}"
# - EOF ------------------------------------------------------------------------
