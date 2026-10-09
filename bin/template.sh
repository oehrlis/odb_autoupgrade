#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Script.....: template.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.10.09
# Version....: v0.6.0
# Purpose....: Template for new AutoUpgrade wrapper scripts using OraDBA patterns.
#              Copy this file and replace all TODO sections.
# Usage......: Copy, rename, fill in TODO sections.
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------

set -euo pipefail

# =============================================================================
# BOOTSTRAP
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

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
. "${LIB_DIR}/au_lib.sh"

# =============================================================================
# SCRIPT DEFAULTS
# =============================================================================

# TODO: add script-specific default variables here
: "${DRY_RUN:=false}"

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
  TODO: describe what this script does.

Options:
  -h, --help        Show this help message
  -V, --version     Show version
  -v, --verbose     Enable verbose output (DEBUG level)
  -d, --debug       Enable debug output (TRACE level)
  -q, --quiet       Quiet mode (WARN level only)
  -n, --dry-run     Dry-run mode (show what would be done)

TODO: Add script-specific options here.

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
    # First parse common options (sets LOG_LEVEL, etc.)
    parse_common_opts "$@"

    # Parse script-specific options from remaining ARGS
    local -a remaining=()
    set -- "${ARGS[@]-}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            # TODO: add script-specific options
            -n | --dry-run)
                DRY_RUN=true
                shift
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
# Purpose.: Validate required inputs.
# Returns.: 0 on success; exits on error
# ------------------------------------------------------------------------------
validate_inputs() {
    log_debug "Validating inputs"
    # TODO: add validation logic
    # require_var SOME_REQUIRED_VAR
    # require_cmd some_required_command
}

# ------------------------------------------------------------------------------
# Function: do_work
# Purpose.: Main work function. TODO: implement your logic here.
# Returns.: 0 on success; exits on error
# ------------------------------------------------------------------------------
do_work() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "DRY-RUN MODE: No changes will be made"
    fi

    # TODO: implement work logic
    log_info "Work completed successfully"
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

    # Load configuration (7-level precedence)
    au_load_config

    parse_args "$@"

    validate_inputs

    do_work

    log_info "${SCRIPT_NAME} completed successfully"
}

main "$@"
# - EOF ------------------------------------------------------------------------
