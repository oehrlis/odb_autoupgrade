#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Script.....: au_log_cleanup.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.10.09
# Version....: v0.6.0
# Purpose....: Safe cleanup of AutoUpgrade global_log_dir.
#              Default: list what would be removed and what is kept (with reason).
#              --delete removes files; requires --yes or interactive confirmation.
#              Never touches the keep-set (request_id_cache.json, aru/*.csd,
#              .ap_build, lock/). Refuses dangerous AU_LOG_DIR values.
# Usage......: au_log_cleanup.sh [OPTIONS]
# Notes......: Reads AU_LOG_DIR from env or config (7-level precedence via
#              au_lib.sh). Run with --help for full option list.
# Reference..: https://github.com/oehrlis/odb_autoupgrade
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.09 oehrli - initial version (WP8)
# ------------------------------------------------------------------------------

set -euo pipefail

# =============================================================================
# BOOTSTRAP
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_VERSION="v0.6.0"
readonly SCRIPT_VERSION

SCRIPT_BASE="$(dirname "${SCRIPT_DIR}")"
if [[ -n "${AUTOUPGRADE_BASE:-}" && "${AUTOUPGRADE_BASE}" != "${SCRIPT_BASE}" ]]; then
    echo "WARN: AUTOUPGRADE_BASE env var ignored (derived from script location: ${SCRIPT_BASE})" >&2
fi
export AUTOUPGRADE_BASE="${SCRIPT_BASE}"

if [[ ! -f "${LIB_DIR}/au_lib.sh" ]]; then
    echo "ERROR: Cannot find au_lib.sh in ${LIB_DIR}" >&2
    exit 1
fi
# shellcheck source=lib/au_lib.sh
# shellcheck disable=SC1091
. "${LIB_DIR}/au_lib.sh"

# Load log-cleanup helpers (sourced after au_lib.sh so common.sh is already loaded)
if [[ ! -f "${LIB_DIR}/au_logs.sh" ]]; then
    echo "ERROR: Cannot find au_logs.sh in ${LIB_DIR}" >&2
    exit 1
fi
# shellcheck source=lib/au_logs.sh
. "${LIB_DIR}/au_logs.sh"

# =============================================================================
# SCRIPT DEFAULTS
# =============================================================================

: "${DRY_RUN:=false}"
: "${DO_DELETE:=false}"
: "${DO_YES:=false}"
: "${OLDER_THAN:=30}"
: "${KEEP_JOBS:=3}"

# =============================================================================
# FUNCTIONS
# =============================================================================

# ------------------------------------------------------------------------------
# Function: usage
# Purpose.: Display usage information and exit 0.
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Description:
  Safe cleanup of AutoUpgrade global_log_dir (AU_LOG_DIR).

  Default mode (listing): shows what would be deleted and what is kept,
  with the reason for every kept file. No files are removed.

  --delete removes files; requires --yes or interactive confirmation.

  The following paths are never deleted (keep-set):
    cfgtoollogs/patch/auto/aru/request_id_cache.json
    cfgtoollogs/patch/auto/aru/*.csd
    cfgtoollogs/patch/auto/lock/  (and subtree)
    .ap_build

  The N newest job directories (containing status.json or progress.json)
  are always kept regardless of age.

Options:
  -h, --help              Show this help message
  -V, --version           Show version
  -v, --verbose           Enable verbose output (INFO level)
  -d, --debug             Enable debug output (TRACE level)
  -q, --quiet             Quiet mode (WARN level only)
  -n, --dry-run           Dry-run (same as default listing; no deletions)
      --delete            Actually remove files (requires --yes or confirmation)
      --yes               Skip interactive confirmation (use with --delete)
      --older-than DAYS   Only delete files older than DAYS days (default: 30)
      --keep-jobs N       Keep the N newest job directories (default: 3)
      --log-dir DIR       Override AU_LOG_DIR
      --log-file FILE     Also write log output to FILE
      --no-color          Disable color output

EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Function: parse_args
# Purpose.: Parse command-line arguments.
# Args....: "$@" - All command-line arguments
# Returns.: 0 on success; exits on invalid args
# ------------------------------------------------------------------------------
parse_args() {
    parse_common_opts "$@"

    local -a remaining=()
    set -- "${ARGS[@]-}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n | --dry-run)
                DRY_RUN=true
                shift
                ;;
            --delete)
                DO_DELETE=true
                shift
                ;;
            --yes)
                DO_YES=true
                shift
                ;;
            --older-than)
                need_val "$1" "${2:-}"
                OLDER_THAN="$2"
                shift 2
                ;;
            --keep-jobs)
                need_val "$1" "${2:-}"
                KEEP_JOBS="$2"
                shift 2
                ;;
            --log-dir)
                need_val "$1" "${2:-}"
                AU_LOG_DIR="$2"
                export AU_LOG_DIR
                shift 2
                ;;
            -*)
                die "Unknown option: $1 (use --help for usage)"
                ;;
            *)
                remaining+=("$1")
                shift
                ;;
        esac
    done
    ARGS=("${remaining[@]+"${remaining[@]}"}")
}

# ------------------------------------------------------------------------------
# Function: validate_inputs
# Purpose.: Validate required inputs and refuse unsafe configurations.
# Returns.: 0 on success; exits on error
# ------------------------------------------------------------------------------
validate_inputs() {
    log_debug "Validating inputs"

    # Validate OLDER_THAN is a non-negative integer
    if ! [[ "${OLDER_THAN}" =~ ^[0-9]+$ ]]; then
        die "--older-than requires a non-negative integer (got: ${OLDER_THAN})"
    fi

    # Validate KEEP_JOBS is a non-negative integer
    if ! [[ "${KEEP_JOBS}" =~ ^[0-9]+$ ]]; then
        die "--keep-jobs requires a non-negative integer (got: ${KEEP_JOBS})"
    fi

    # Validate the log directory
    au_logs_validate_dir

    # Refuse to run while AutoUpgrade is active (lock/ and recovery data at risk)
    if au_logs_is_au_running; then
        die "AutoUpgrade appears to be running for user '$(id -un)'. Refusing cleanup while AU holds lock/."
    fi
}

# ------------------------------------------------------------------------------
# Function: do_work
# Purpose.: Run the cleanup (list or delete).
# Returns.: 0 on success; exits on error or user abort
# ------------------------------------------------------------------------------
do_work() {
    local action="list"

    # --dry-run equals default listing; never deletes
    if [[ "${DO_DELETE}" == "true" && "${DRY_RUN}" == "false" ]]; then
        action="delete"
    elif [[ "${DO_DELETE}" == "true" && "${DRY_RUN}" == "true" ]]; then
        log_warn "--dry-run overrides --delete; running in list mode only"
    fi

    log_info "${SCRIPT_NAME} ${SCRIPT_VERSION}: ${action} mode"
    log_info "  AU_LOG_DIR:   ${AU_LOG_DIR}"
    log_info "  --older-than: ${OLDER_THAN} days"
    log_info "  --keep-jobs:  ${KEEP_JOBS}"

    # Interactive confirmation when deleting without --yes
    if [[ "${action}" == "delete" && "${DO_YES}" == "false" ]]; then
        echo ""
        echo "WARNING: This will permanently delete files from:"
        echo "  ${AU_LOG_DIR}"
        echo "  (files older than ${OLDER_THAN} days, keeping ${KEEP_JOBS} newest job dirs)"
        echo ""
        if ! confirm "Proceed with deletion?"; then
            log_warn "Aborted by user."
            exit 0
        fi
    fi

    local do_delete_flag="false"
    [[ "${action}" == "delete" ]] && do_delete_flag="true"

    au_logs_do_cleanup "${AU_LOG_DIR}" "${OLDER_THAN}" "${KEEP_JOBS}" "${do_delete_flag}"

    echo ""
    log_info "Summary: ${AU_LOGS_DELETED} ${action}d, ${AU_LOGS_KEPT} kept, ${AU_LOGS_SKIPPED} skipped"
}

# ------------------------------------------------------------------------------
# Function: cleanup
# Purpose.: Cleanup function called on EXIT trap.
# Returns.: 0
# ------------------------------------------------------------------------------
cleanup() {
    log_debug "Cleanup completed"
}

# =============================================================================
# MAIN
# =============================================================================

# ------------------------------------------------------------------------------
# Function: main
# Purpose.: Main entry point.
# Args....: "$@" - All command-line arguments
# Returns.: 0 on success; 1 on error
# ------------------------------------------------------------------------------
main() {
    setup_error_handling

    au_load_config

    parse_args "$@"

    validate_inputs

    do_work

    log_info "${SCRIPT_NAME} completed successfully"
}

main "$@"
# - EOF ------------------------------------------------------------------------
