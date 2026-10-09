#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Name.......: au_run.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.10.09
# Version....: v0.6.0
# Purpose....: Wrapper script to run Oracle AutoUpgrade with proxy, truststore,
#              config rendering, and env-file support.
# Notes......: - AUTOUPGRADE_BASE derived from script location (never from env).
#              - Configuration loaded via au_load_config (7-level precedence).
#              - -config: resolved as absolute, CWD-relative, or
#                AUTOUPGRADE_BASE/etc-relative; env vars expanded via au_render_cfg.
#              - --dry-run or AUTOUPGRADE_DRY_RUN=true: print command, exit 0.
#              - AutoUpgrade exit code is propagated (never swallowed by set -e).
#              - Deprecation WARN when old config basenames are used.
#              - After -mode download: VDGI_*/GOLD_IMAGE scan via au_log_scan.
#
# Reference..: https://github.com/oehrlis/odb_autoupgrade
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2025.06.17 oehrli - added AUTOUPGRADE_BASE env variable
# 2026.10.08 oehrli - port ref/run_autoupgrade_v0.5.0
# 2026.10.09 oehrli - main(), au_load_config, --dry-run flag,
#                     mode parsing, deprecation WARN, au_check_cfg_mode,
#                     au_render_cfg, au_log_scan
# ------------------------------------------------------------------------------

set -euo pipefail

# =============================================================================
# BOOTSTRAP
# =============================================================================

SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")
SCRIPT_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SCRIPT_BASE="$(dirname "${SCRIPT_BIN_DIR}")"
# AUTOUPGRADE_BASE is always derived from script location; any env override
# is ignored and reported.
if [[ -n "${AUTOUPGRADE_BASE:-}" && "${AUTOUPGRADE_BASE}" != "${SCRIPT_BASE}" ]]; then
    echo "WARN: AUTOUPGRADE_BASE env var ignored (derived from script location: ${SCRIPT_BASE})" >&2
fi
export AUTOUPGRADE_BASE="${SCRIPT_BASE}"

# Load all libraries via the loader
# shellcheck source=lib/au_lib.sh
. "${SCRIPT_BIN_DIR}/../lib/au_lib.sh"

# =============================================================================
# SCRIPT DEFAULTS
# =============================================================================

SCRIPT_JAR_DIR="${AUTOUPGRADE_BASE}/jar"
JAR_FILE="${SCRIPT_JAR_DIR}/autoupgrade.jar"
TMP_CFG=""
JAVA_OPTS=()
PROXY_INFO=""
TRUSTSTORE_INFO=""
JAVA_BIN=""
JAVA_VERSION_FULL=""
DRY_RUN=false

# Deprecated config names 
_AU_DEPRECATED_CFGS=("au_download.cfg" "au_create_home.cfg" "au_deploy.cfg")

# =============================================================================
# FUNCTIONS
# =============================================================================

# ------------------------------------------------------------------------------
# Function: cleanup
# Purpose.: Remove temporary config on exit. Invoked via trap (see main).
# ------------------------------------------------------------------------------
# shellcheck disable=SC2329
cleanup() {
    if [[ -n "${TMP_CFG}" && -f "${TMP_CFG}" ]]; then
        rm -f "${TMP_CFG}"
    fi
    # The script trap replaces the library EXIT trap - purge renderer temp files here
    if declare -F _au_purge_tmpfiles >/dev/null; then
        _au_purge_tmpfiles
    fi
}

# ------------------------------------------------------------------------------
# Function: show_help
# Purpose.: Print usage information and exit 0.
# ------------------------------------------------------------------------------
show_help() {
    cat >&2 <<HELP
Usage: ${SCRIPT_NAME} [--help] [--dry-run] [-config <file>] [<autoupgrade-args>...]

Wrapper for Oracle AutoUpgrade (jar/autoupgrade.jar). All arguments are passed
directly to AutoUpgrade; only --help, --dry-run, and -config are intercepted.

Wrapper-only options:
  --help        Show this message and exit (AutoUpgrade uses -help with one dash)
  --dry-run     Print the java command line (secrets masked) and exit 0

Environment variables:
  AUTOUPGRADE_PROXY            Proxy URL; overrides https_proxy / http_proxy.
                               "none" disables proxy.
  AUTOUPGRADE_TRUSTSTORE       Truststore path. "none" uses the JDK default.
  AUTOUPGRADE_TRUSTSTORE_PASS  Truststore password (only passed when set).
  AUTOUPGRADE_JAVA_HOME        JDK home to use instead of PATH / ORACLE_HOME.
  AUTOUPGRADE_JAVA_OPTS        Additional JVM options (word-split on spaces).
  AUTOUPGRADE_DEBUG_SSL        true = add -Djavax.net.debug=ssl:handshake.
  AUTOUPGRADE_DRY_RUN          true = print java command line, exit 0.
  AUTOUPGRADE_ENV_FILE         Path to a custom env file (level-3 override).
  ORADBA_CONFIG_DIR            Site config dir for autoupgrade.env (level-4).

Config file lookup order:
  1. Absolute path
  2. Relative to current working directory
  3. Relative to \${AUTOUPGRADE_BASE}/etc/
HELP
    exit 0
}

# ------------------------------------------------------------------------------
# Function: _warn_if_cfg_unsafe
# Purpose.: log_warn if a resolved config file or its directory is
#           group/world-writable or not owned by the current user or root.
# Args....: $1 - resolved file path
# Returns.: 0 (non-fatal per design - config is not sourced)
# ------------------------------------------------------------------------------
_warn_if_cfg_unsafe() {
    local _p="$1"
    local _cur_uid _file_uid _dir_uid
    _cur_uid=$(id -u 2>/dev/null || true)
    _file_uid=$(stat -c '%u' "${_p}" 2>/dev/null || stat -f '%u' "${_p}" 2>/dev/null || true)
    if [[ -n "${_file_uid}" && -n "${_cur_uid}" \
          && "${_file_uid}" != "0" && "${_file_uid}" != "${_cur_uid}" ]]; then
        log_warn "Config file '${_p}' not owned by current user or root (uid=${_file_uid})"
    fi
    if [[ -n "$(find "${_p}" -maxdepth 0 \( -perm -g+w -o -perm -o+w \) 2>/dev/null || true)" ]]; then
        log_warn "Config file '${_p}' is group/world-writable"
    fi
    local _dir="${_p%/*}"
    [[ "${_dir}" == "${_p}" || -z "${_dir}" ]] && _dir="."
    _dir_uid=$(stat -c '%u' "${_dir}" 2>/dev/null || stat -f '%u' "${_dir}" 2>/dev/null || true)
    if [[ -n "${_dir_uid}" && -n "${_cur_uid}" \
          && "${_dir_uid}" != "0" && "${_dir_uid}" != "${_cur_uid}" ]]; then
        log_warn "Directory '${_dir}' containing config is not owned by current user or root (uid=${_dir_uid})"
    fi
    if [[ -n "$(find "${_dir}" -maxdepth 0 \( -perm -g+w -o -perm -o+w \) 2>/dev/null || true)" ]]; then
        log_warn "Directory '${_dir}' containing config is group/world-writable"
    fi
}

# ------------------------------------------------------------------------------
# Function: resolve_config_path
# Purpose.: Resolve config path: absolute > CWD > AUTOUPGRADE_BASE/etc
# Args....: $1 - user-supplied config path
# Returns.: Prints resolved absolute path to stdout; exits 1 if not found
# Notes...: emits log_warn if file or its directory is unsafe (not fatal).
# ------------------------------------------------------------------------------
resolve_config_path() {
    local input_path="$1"
    local _resolved=""

    if [[ "${input_path}" = /* ]]; then
        [[ -f "${input_path}" ]] && _resolved="${input_path}"
    fi

    if [[ -z "${_resolved}" && -f "${PWD}/${input_path}" ]]; then
        _resolved="${PWD}/${input_path}"
    fi

    if [[ -z "${_resolved}" && -f "${AUTOUPGRADE_BASE}/etc/${input_path}" ]]; then
        _resolved="${AUTOUPGRADE_BASE}/etc/${input_path}"
    fi

    if [[ -z "${_resolved}" && -f "${AUTOUPGRADE_BASE}/etc/$(basename "${input_path}")" ]]; then
        _resolved="${AUTOUPGRADE_BASE}/etc/$(basename "${input_path}")"
    fi

    if [[ -z "${_resolved}" ]]; then
        log_error "Configuration file not found: ${input_path}"; exit 1
    fi

    # warn if config or its directory is unsafe (not fatal - cfg is not sourced)
    _warn_if_cfg_unsafe "${_resolved}"

    echo "${_resolved}"
}

# ------------------------------------------------------------------------------
# Function: mask_cmd
# Purpose.: Mask sensitive values in a command-line display string.
# Args....: "$@" - full command array
# Returns.: Prints masked string to stdout
# ------------------------------------------------------------------------------
mask_cmd() {
    local arg masked=""
    for arg in "$@"; do
        if [[ "${arg}" == *[Pp]assword=* || "${arg}" == *[Pp]ass=* ]]; then
            arg="${arg%%=*}=****"
        fi
        masked="${masked:+${masked} }${arg}"
    done
    echo "${masked}"
}

# ------------------------------------------------------------------------------
# Function: parse_mode_from_args
# Purpose.: Scan ARGS array for -mode <value>; normalise to lowercase.
# Args....: None (reads global ARGS)
# Returns.: Prints normalised mode to stdout; empty string if not found
# Notes...: rejects duplicate -mode; rejects missing value;
#           normalises mode to lowercase (AU modes are always lowercase).
# ------------------------------------------------------------------------------
parse_mode_from_args() {
    local _i _found="" _val=""
    for _i in "${!ARGS[@]}"; do
        if [[ "${ARGS[_i]}" == "-mode" ]]; then
            local _next=$(( _i + 1 ))
            if [[ "${_next}" -ge "${#ARGS[@]}" || "${ARGS[_next]}" == -* ]]; then
                log_error "-mode requires a value"; exit 1
            fi
            if [[ -n "${_found}" ]]; then
                log_error "-mode specified more than once (duplicate: '${ARGS[_next]}' vs '${_found}')"; exit 1
            fi
            _val="${ARGS[_next]}"
            # normalise to lowercase
            _found="${_val,,}"
        fi
    done
    echo "${_found}"
}

# ------------------------------------------------------------------------------
# Function: main
# Purpose.: Main entry point for the script.
# Args....: "$@" - all command-line arguments
# ------------------------------------------------------------------------------
main() {
    trap cleanup EXIT

    # -------------------------------------------------------------------------
    # Load configuration (7-level precedence)
    # -------------------------------------------------------------------------
    au_load_config

    # -------------------------------------------------------------------------
    # Parse wrapper arguments
    # -------------------------------------------------------------------------
    local ARGS=()
    local CONFIG_FILE=""
    local RESOLVE_CONFIG=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                show_help
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -config)
                [[ $# -lt 2 ]] && { log_error "-config requires a value"; exit 1; }
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

    # Also honour legacy env var for dry-run
    [[ "${AUTOUPGRADE_DRY_RUN:-false}" == "true" ]] && DRY_RUN=true

    # -------------------------------------------------------------------------
    # Deprecation WARN for old config file names 
    # -------------------------------------------------------------------------
    if [[ "${RESOLVE_CONFIG}" == true && -n "${CONFIG_FILE}" ]]; then
        local _cfg_base
        _cfg_base=$(basename "${CONFIG_FILE}")
        local _dep
        for _dep in "${_AU_DEPRECATED_CFGS[@]}"; do
            if [[ "${_cfg_base}" == "${_dep}" ]]; then
                log_warn "Config file '${_cfg_base}' is deprecated; use etc/au_patch.cfg instead"
                break
            fi
        done
    fi

    # -------------------------------------------------------------------------
    # Parse AutoUpgrade -mode for mode-specific logic
    # -------------------------------------------------------------------------
    local AU_MODE
    AU_MODE="$(parse_mode_from_args)"

    # Per-mode mandatory variable checks
    au_check_cfg_mode "${AU_MODE}"

    # -------------------------------------------------------------------------
    # Resolve Java and JVM options
    # -------------------------------------------------------------------------
    au_resolve_java
    au_build_jvm_opts

    # -------------------------------------------------------------------------
    # Verify JAR exists
    # -------------------------------------------------------------------------
    [[ -f "${JAR_FILE}" ]] || { log_error "AutoUpgrade JAR not found at ${JAR_FILE}"; exit 1; }

    # -------------------------------------------------------------------------
    # Print summary info
    # -------------------------------------------------------------------------
    log_info "Java.......: ${JAVA_BIN} (${JAVA_VERSION_FULL})"
    log_info "Proxy......: ${PROXY_INFO:-none}"
    log_info "Truststore.: ${TRUSTSTORE_INFO:-JDK default cacerts}"

    # -------------------------------------------------------------------------
    # Resolve -config via au_render_cfg 
    # -------------------------------------------------------------------------
    local -a FULL_CMD
    if [[ "${RESOLVE_CONFIG}" == true ]]; then
        au_check_cfg_vars "${CONFIG_FILE}"
        TMP_CFG="$(mktemp "${TMPDIR:-/tmp}/autoupgrade_resolved_XXXXXX")"
        log_info "Rendering config: ${CONFIG_FILE}"
        au_render_cfg "${CONFIG_FILE}" "${AU_MODE}" "${TMP_CFG}"
        [[ -f "${TMP_CFG}" ]] || { log_error "Rendered config not created: ${TMP_CFG}"; exit 1; }
        FULL_CMD=("${JAVA_BIN}" "${JAVA_OPTS[@]+"${JAVA_OPTS[@]}"}" -jar "${JAR_FILE}" -config "${TMP_CFG}" "${ARGS[@]+"${ARGS[@]}"}")
    else
        FULL_CMD=("${JAVA_BIN}" "${JAVA_OPTS[@]+"${JAVA_OPTS[@]}"}" -jar "${JAR_FILE}" "${ARGS[@]+"${ARGS[@]}"}")
    fi

    # -------------------------------------------------------------------------
    # Dry-run: print masked command line and exit
    # -------------------------------------------------------------------------
    if [[ "${DRY_RUN}" == true ]]; then
        echo "DRY-RUN: $(mask_cmd "${FULL_CMD[@]}")" >&2
        exit 0
    fi

    # -------------------------------------------------------------------------
    # Run AutoUpgrade; propagate exit code
    # -------------------------------------------------------------------------
    local rc=0
    "${FULL_CMD[@]}" || rc=$?

    # Post-download VDGI scan 
    if [[ "${AU_MODE}" == "download" ]]; then
        au_log_scan "${AU_LOG_DIR}" "download"
    fi

    exit "${rc}"
}

main "$@"
# - EOF ------------------------------------------------------------------------
