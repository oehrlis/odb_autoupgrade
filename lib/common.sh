#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Module.....: common.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.10.09
# Version....: v0.6.0
# Purpose....: Generic utilities for bash scripts - logging, error handling,
#              argument parsing helpers. Designed to be reusable across projects.
#              Ported from odb_datasafe/lib/common.sh v0.19.1 (2026.03.02);
#              OCI-specific and Python-specific sections removed.
#              Source repo: github.com/oehrlis/odb_datasafe, commit ref v0.19.1
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------

# Guard on function existence, not an inheritable variable.
# Using declare -F prevents a caller from bypassing the bash 4.2 check below
# by pre-exporting COMMON_SH_LOADED=1 in the environment.
declare -F log_info >/dev/null 2>&1 && return 0

# bash 4.2+ required (OL 8/9; Homebrew bash on macOS).
# Requires declare -A (bash 4.0), nameref-safe arithmetic, [[ =~ ]] with groups.
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]] || \
   [[ "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -lt 2 ]]; then
    echo "ERROR: bash 4.2+ required (found ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

# Ensure ASCII collation for tr, sort, and other locale-sensitive operations.
export LC_COLLATE=C

# =============================================================================
# CONFIGURATION
# =============================================================================

# Log levels: 0=TRACE, 1=DEBUG, 2=INFO, 3=WARN, 4=ERROR, 5=FATAL
: "${LOG_LEVEL:=3}"     # Default: WARN (quiet by default)
: "${LOG_FILE:=}"       # Optional: log to file
: "${LOG_COLORS:=auto}" # auto|always|never

# Error handling
: "${SHOW_STACKTRACE:=true}" # Show stack trace on error
: "${CLEANUP_ON_EXIT:=true}" # Call cleanup function on exit

# Script metadata (set by script, not library)
: "${SCRIPT_NAME:=$(basename "${BASH_SOURCE[-1]}")}"
: "${SCRIPT_VERSION:=}"
: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[-1]}")" && pwd)}"
: "${SHOW_USAGE_ON_EMPTY_ARGS:=false}"

# Shared argument array used by parse_common_opts and script-specific parsers.
ARGS=()

# Accumulates paths of config files actually loaded by au_load_config/_au_source_file.
_AU_CONF_FILES=""

# =============================================================================
# COLOR SETUP
# =============================================================================

# ------------------------------------------------------------------------------
# Function: _init_colors
# Purpose.: Initialize ANSI color variables
# Args....: None
# Returns.: 0 on success
# ------------------------------------------------------------------------------
_init_colors() {
    if [[ "${LOG_COLORS}" == "never" ]]; then
        COLOR_RESET="" COLOR_RED="" COLOR_GREEN="" COLOR_YELLOW=""
        COLOR_BLUE="" COLOR_CYAN="" COLOR_GRAY=""
        return
    fi

    if [[ "${LOG_COLORS}" == "always" ]] || [[ -t 2 && "${LOG_COLORS}" == "auto" ]]; then
        COLOR_RESET='\033[0m'
        COLOR_RED='\033[0;31m'
        COLOR_GREEN='\033[0;32m'
        COLOR_YELLOW='\033[0;33m'
        COLOR_BLUE='\033[0;34m'
        COLOR_CYAN='\033[0;36m'
        COLOR_GRAY='\033[0;90m'
    else
        COLOR_RESET="" COLOR_RED="" COLOR_GREEN="" COLOR_YELLOW=""
        # shellcheck disable=SC2034
        COLOR_BLUE="" COLOR_CYAN="" COLOR_GRAY=""
    fi
}
_init_colors

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

# ------------------------------------------------------------------------------
# Function: _log_level_num
# Purpose.: Map log level string to numeric severity
# Args....: $1 - Log level string (TRACE|DEBUG|INFO|WARN|ERROR|FATAL)
# Returns.: 0; numeric level to stdout
# ------------------------------------------------------------------------------
_log_level_num() {
    case "${1^^}" in
        TRACE) echo 0 ;;
        DEBUG) echo 1 ;;
        INFO)  echo 2 ;;
        WARN)  echo 3 ;;
        ERROR) echo 4 ;;
        FATAL) echo 5 ;;
        *)     echo 2 ;;
    esac
}

# ------------------------------------------------------------------------------
# Function: log
# Purpose.: Generic logging function with levels and colors
# Args....: $1 - Log level (TRACE|DEBUG|INFO|WARN|ERROR|FATAL)
#           $@ - Message
# Returns.: 0 on success; exits 1 on FATAL
# Output..: Log line to stderr and optional log file
# ------------------------------------------------------------------------------
log() {
    local level="${1^^}"
    shift
    local msg="$*"

    local level_num current_level_num
    level_num=$(_log_level_num "$level")
    current_level_num=$(_log_level_num "${LOG_LEVEL}")

    [[ $level_num -lt $current_level_num ]] && return 0

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color="" reset="${COLOR_RESET}"

    case "$level" in
        TRACE) color="${COLOR_GRAY}"   ;;
        DEBUG) color="${COLOR_CYAN}"   ;;
        INFO)  color="${COLOR_GREEN}"  ;;
        WARN)  color="${COLOR_YELLOW}" ;;
        ERROR | FATAL) color="${COLOR_RED}" ;;
    esac

    # printf instead of echo -e; %b interprets \033 escape codes in color vars;
    # %s for message text avoids misinterpreting literal % characters in messages.
    printf '%b%s%b %s\n' "${color}" "[${timestamp}] [${level}]" "${reset}" "${msg}" >&2

    if [[ -n "${LOG_FILE}" ]]; then
        echo "[${timestamp}] [${level}] ${msg}" >> "${LOG_FILE}"
    fi

    [[ "$level" == "FATAL" ]] && exit 1
    return 0
}

# Convenience wrappers
# ------------------------------------------------------------------------------
# Function: log_trace / log_debug / log_info / log_warn / log_error / log_fatal
# Purpose.: Level-specific log wrappers
# Args....: $@ - Message
# Returns.: 0 on success (log_fatal exits)
# ------------------------------------------------------------------------------
log_trace() { log TRACE "$@"; }
log_debug() { log DEBUG "$@"; }
log_info()  { log INFO  "$@"; }
log_warn()  { log WARN  "$@"; }
log_error() { log ERROR "$@"; }
log_fatal() { log FATAL "$@"; }

# ------------------------------------------------------------------------------
# Function: die
# Purpose.: Exit with error message
# Args....: $1 - Error message
#           $2 - Exit code (optional, default: 1)
# Returns.: Exits with code
# ------------------------------------------------------------------------------
die() {
    local msg="$1"
    local code="${2:-1}"
    log_error "$msg"
    exit "$code"
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

# ------------------------------------------------------------------------------
# Function: stacktrace
# Purpose.: Print stack trace for debugging
# Args....: None
# Returns.: 0
# Output..: Stack trace to stderr
# ------------------------------------------------------------------------------
stacktrace() {
    local frame=0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Stack trace:" >&2
    while caller $frame; do
        (( frame++ )) || true
    done | while read -r line func file; do
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR]   at ${func}() in ${file}:${line}" >&2
    done
}

# ------------------------------------------------------------------------------
# Function: error_handler
# Purpose.: Global error trap handler
# Args....: None
# Returns.: Exits with error code
# Notes...: Disables ERR trap to prevent recursion
# ------------------------------------------------------------------------------
error_handler() {
    local exit_code=$?
    trap - ERR
    local line_num="${BASH_LINENO[0]}"
    local script="${BASH_SOURCE[1]}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Error in ${script} at line ${line_num} (exit code: ${exit_code})" >&2
    if [[ "${SHOW_STACKTRACE:-true}" == "true" ]]; then
        stacktrace
    fi
    exit "$exit_code"
}

# ------------------------------------------------------------------------------
# Function: cleanup
# Purpose.: Cleanup handler (override in scripts)
# Args....: None
# Returns.: 0
# Notes...: Scripts should define their own cleanup() if needed
# ------------------------------------------------------------------------------
cleanup() { :; }

# ------------------------------------------------------------------------------
# Function: setup_error_handling
# Purpose.: Initialize error handling with ERR/EXIT traps
# Args....: None
# Returns.: 0
# Notes...: called from main() in every bin script
# ------------------------------------------------------------------------------
setup_error_handling() {
    set -euo pipefail
    set -E  # ERR trap inherited by functions

    trap error_handler ERR

    if [[ "${CLEANUP_ON_EXIT}" == "true" ]]; then
        trap cleanup EXIT
    fi
}

# =============================================================================
# VALIDATION & REQUIREMENTS
# =============================================================================

# ------------------------------------------------------------------------------
# Function: require_cmd
# Purpose.: Check if required commands are available
# Args....: $@ - Command names
# Returns.: 0 on success; exits 1 on missing
# ------------------------------------------------------------------------------
require_cmd() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
    fi
}

# ------------------------------------------------------------------------------
# Function: require_var
# Purpose.: Check if required variables are non-empty
# Args....: $@ - Variable names
# Returns.: 0 on success; exits 1 on missing
# ------------------------------------------------------------------------------
require_var() {
    local missing=()
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required variables: ${missing[*]}"
    fi
}

# =============================================================================
# ARGUMENT PARSING HELPERS
# =============================================================================

# ------------------------------------------------------------------------------
# Function: need_val
# Purpose.: Ensure a flag has a non-empty, non-dash-prefixed value
# Args....: $1 - Flag name (for error message)
#           $2 - Value to check
# Returns.: 0 on success; exits 1 on failure
# ------------------------------------------------------------------------------
need_val() {
    local flag="$1"
    local val="${2:-}"
    if [[ -z "$val" || "$val" == -* ]]; then
        die "Option ${flag} requires a value"
    fi
}

# ------------------------------------------------------------------------------
# Function: parse_common_opts
# Purpose.: Parse common options shared by most scripts
# Args....: $@ - Arguments to parse
# Returns.: 0; sets ARGS array and LOG_LEVEL / DRY_RUN globals
# Notes...: Call FIRST, then parse script-specific args from ARGS
# ------------------------------------------------------------------------------
parse_common_opts() {
    LOG_LEVEL=WARN

    if [[ $# -eq 0 && "${SHOW_USAGE_ON_EMPTY_ARGS}" == "true" ]]; then
        if declare -f usage > /dev/null 2>&1; then
            usage
        else
            die "Help not available"
        fi
    fi

    ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                if declare -f usage > /dev/null 2>&1; then
                    usage
                else
                    die "Help not available"
                fi
                ;;
            -V | --version)
                echo "${SCRIPT_NAME} ${SCRIPT_VERSION:-unknown}"
                exit 0
                ;;
            -v | --verbose)
                LOG_LEVEL=INFO
                shift
                ;;
            -d | --debug)
                LOG_LEVEL=TRACE
                shift
                ;;
            -q | --quiet)
                LOG_LEVEL=WARN
                shift
                ;;
            -n | --dry-run)
                export DRY_RUN=true
                shift
                ;;
            --log-file)
                need_val "$1" "${2:-}"
                LOG_FILE="$2"
                shift 2
                ;;
            --no-color)
                LOG_COLORS=never
                _init_colors
                shift
                ;;
            --)
                shift
                ARGS+=("$@")
                break
                ;;
            *)
                ARGS+=("$1")
                shift
                ;;
        esac
    done
}

# =============================================================================
# UTILITIES
# =============================================================================

# ------------------------------------------------------------------------------
# Function: confirm
# Purpose.: Ask user for confirmation
# Args....: $1 - Prompt message (optional)
# Returns.: 0 if yes, 1 if no
# ------------------------------------------------------------------------------
confirm() {
    local prompt="${1:-Are you sure?}"
    local response
    read -r -p "${prompt} [y/N] " response
    case "$response" in
        [yY][eE][sS] | [yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# Function: trim_trailing_crlf
# Purpose.: Trim trailing CR/LF characters from a value
# Args....: $1 - Input value
# Returns.: 0; normalized value to stdout
# ------------------------------------------------------------------------------
trim_trailing_crlf() {
    local value="$1"
    while [[ "$value" == *$'\n' || "$value" == *$'\r' ]]; do
        value="${value%$'\n'}"
        value="${value%$'\r'}"
    done
    printf '%s' "$value"
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Auto-initialize error handling only when explicitly enabled
if [[ "${AUTO_ERROR_HANDLING:-false}" == "true" ]]; then
    setup_error_handling
fi

# common.sh loaded (v0.6.0 - ported from odb_datasafe v0.19.1)
