#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Script.....: au_goldimage.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.10.09
# Version....: v0.6.0
# Purpose....: Self-built gold image: create, verify checksum, and install.
#
#              --create --home <OH> --dest <dir>
#                Wraps <OH>/runInstaller -silent -createGoldImage
#                -destinationLocation <dir>. Writes <zip>.sha256 and a manifest
#                with opatch lspatches and binary option listing next to the zip.
#
#              --verify <zip>
#                Verifies the zip against its .sha256 file.
#
#              --install <zip> --target <OH>
#                Manual fallback: verify checksum, unzip into empty target home,
#                run runInstaller -silent software-only. Prints the root.sh
#                command; never runs it.
#
#              --dry-run prints every command that would be executed.
#
# Usage......: au_goldimage.sh --create --home <OH> --dest <dir> [OPTIONS]
#              au_goldimage.sh --verify <zip>
#              au_goldimage.sh --install <zip> --target <OH> [OPTIONS]
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.09 oehrli - initial version for WP10
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

# Load home inspection helpers (WP9/WP10)
if [[ ! -f "${LIB_DIR}/au_home.sh" ]]; then
    echo "ERROR: Cannot find au_home.sh in ${LIB_DIR}" >&2
    exit 1
fi
# shellcheck source=lib/au_home.sh
. "${LIB_DIR}/au_home.sh"

# =============================================================================
# SCRIPT DEFAULTS
# =============================================================================

export SCRIPT_VERSION="v0.6.0"

# Operation mode (exactly one must be set)
MODE_CREATE=false
MODE_VERIFY=false
MODE_INSTALL=false

: "${DRY_RUN:=false}"

OPT_HOME=""
OPT_DEST=""
OPT_ZIP=""
OPT_TARGET=""
OPT_EXCL_FILES=""
OPT_ORACLE_BASE=""
OPT_EDITION=""
OPT_INVENTORY=""
OPT_INVENTORY_GROUP=""
OPT_RESPONSE_FILE=""

# Temp files registered for cleanup
_GI_TMPFILES=()

# =============================================================================
# FUNCTIONS
# =============================================================================

# ------------------------------------------------------------------------------
# Function: usage
# Purpose.: Display usage information and exit 0.
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage:
  ${SCRIPT_NAME} --create --home <OH> --dest <dir> [OPTIONS]
  ${SCRIPT_NAME} --verify <zip>
  ${SCRIPT_NAME} --install <zip> --target <OH> [OPTIONS]

Description:
  Manage self-built Oracle gold images.

  --create:  Build a gold image from a patched home using runInstaller
             -createGoldImage. Writes <zip>.sha256 and a manifest alongside.

  --verify:  Verify a gold image zip against its <zip>.sha256 checksum file.

  --install: Manual fallback install: verify checksum, unzip into target home,
             run runInstaller -silent software-only. Prints the root.sh command
             but never runs it. root.sh must be run separately as root.

Options (create):
  --home <path>          Patched Oracle Home to create image from. Required.
  --dest <dir>           Destination directory for the gold image zip. Required.
  --excl-files <list>    Comma-separated files to exclude (e.g. dbs/,network/admin/)

Options (install):
  --target <path>        Target Oracle Home directory (must not exist or be empty). Required.
  --oracle-base <path>   ORACLE_BASE for runInstaller (or AU_ORACLE_BASE env var).
  --edition <EE|SE2>     Oracle edition (or AU_EDITION env var).
  --inventory <path>     Oracle inventory location (or AU_INVENTORY_LOCATION).
  --inventory-group <g>  Inventory group (or AU_INVENTORY_GROUP).
  --response <file>      Path for the generated response file (default: temp file).

Common options:
  -h, --help             Show this help message
  -V, --version          Show version
  -v, --verbose          Enable verbose output
  -d, --debug            Enable debug output
  -q, --quiet            Quiet mode
  -n, --dry-run          Print commands without executing them

Examples:
  # Create a gold image from a patched home:
  ${SCRIPT_NAME} --create --home /u01/app/oracle/product/19.32.0.0 \\
    --dest /opt/autoupgrade/images

  # Verify the checksum:
  ${SCRIPT_NAME} --verify /opt/autoupgrade/images/db_goldimage_19.32.0.0.zip

  # Install on a new host (manual fallback):
  ${SCRIPT_NAME} --install /opt/autoupgrade/images/db_goldimage_19.32.0.0.zip \\
    --target /u01/app/oracle/product/19.32.0.0 \\
    --oracle-base /u01/app/oracle --edition EE

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
            --create)
                MODE_CREATE=true
                shift
                ;;
            --verify)
                MODE_VERIFY=true
                need_val "$1" "${2:-}"
                OPT_ZIP="$2"
                shift 2
                ;;
            --install)
                MODE_INSTALL=true
                need_val "$1" "${2:-}"
                OPT_ZIP="$2"
                shift 2
                ;;
            --home)
                need_val "$1" "${2:-}"
                OPT_HOME="$2"
                shift 2
                ;;
            --dest)
                need_val "$1" "${2:-}"
                OPT_DEST="$2"
                shift 2
                ;;
            --target)
                need_val "$1" "${2:-}"
                OPT_TARGET="$2"
                shift 2
                ;;
            --excl-files)
                need_val "$1" "${2:-}"
                OPT_EXCL_FILES="$2"
                shift 2
                ;;
            --oracle-base)
                need_val "$1" "${2:-}"
                OPT_ORACLE_BASE="$2"
                shift 2
                ;;
            --edition)
                need_val "$1" "${2:-}"
                OPT_EDITION="$2"
                shift 2
                ;;
            --inventory)
                need_val "$1" "${2:-}"
                OPT_INVENTORY="$2"
                shift 2
                ;;
            --inventory-group)
                need_val "$1" "${2:-}"
                OPT_INVENTORY_GROUP="$2"
                shift 2
                ;;
            --response)
                need_val "$1" "${2:-}"
                OPT_RESPONSE_FILE="$2"
                shift 2
                ;;
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
# Purpose.: Validate required inputs per mode.
# Returns.: 0 on success; exits on error
# ------------------------------------------------------------------------------
validate_inputs() {
    local _modes=0
    [[ "${MODE_CREATE}"  == "true" ]] && _modes=$(( _modes + 1 ))
    [[ "${MODE_VERIFY}"  == "true" ]] && _modes=$(( _modes + 1 ))
    [[ "${MODE_INSTALL}" == "true" ]] && _modes=$(( _modes + 1 ))

    [[ "${_modes}" -eq 1 ]] || die "Exactly one of --create, --verify, --install is required"

    if [[ "${MODE_CREATE}" == "true" ]]; then
        [[ -n "${OPT_HOME}" ]] || die "--home is required for --create"
        [[ -d "${OPT_HOME}" ]] || die "--home not a directory: ${OPT_HOME}"
        [[ -n "${OPT_DEST}" ]] || die "--dest is required for --create"
        [[ -d "${OPT_DEST}" ]] || die "--dest not a directory: ${OPT_DEST}"
        [[ -x "${OPT_HOME}/runInstaller" ]] || die "runInstaller not found: ${OPT_HOME}/runInstaller"
    fi

    if [[ "${MODE_VERIFY}" == "true" ]]; then
        [[ -n "${OPT_ZIP}" ]] || die "--verify requires a zip file path"
        [[ -f "${OPT_ZIP}" ]] || die "Zip file not found: ${OPT_ZIP}"
        [[ -f "${OPT_ZIP}.sha256" ]] || die "Checksum file not found: ${OPT_ZIP}.sha256"
    fi

    if [[ "${MODE_INSTALL}" == "true" ]]; then
        [[ -n "${OPT_ZIP}" ]]    || die "--install requires a zip file path"
        [[ -f "${OPT_ZIP}" ]]    || die "Zip file not found: ${OPT_ZIP}"
        [[ -n "${OPT_TARGET}" ]] || die "--target is required for --install"

        local _obase="${OPT_ORACLE_BASE:-${AU_ORACLE_BASE:-}}"
        [[ -n "${_obase}" ]] || die "--oracle-base or AU_ORACLE_BASE required for --install"
    fi
}

# ------------------------------------------------------------------------------
# Function: _sha256_file
# Purpose.: Compute SHA-256 of a file; portable on macOS (shasum) and Linux.
# Args....: $1 - file path
# Returns.: 0; prints hex hash to stdout
# ------------------------------------------------------------------------------
_sha256_file() {
    local _f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${_f}" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${_f}" | cut -d' ' -f1
    else
        echo "ERROR: Neither sha256sum nor shasum found on PATH" >&2
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Function: _run_cmd
# Purpose.: Execute a command or print it in dry-run mode.
# Args....: "$@" - command and arguments
# Returns.: 0 (dry-run) or exit code of command
# ------------------------------------------------------------------------------
_run_cmd() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        printf 'DRY-RUN: %s\n' "$*" >&2
        return 0
    fi
    "$@"
}

# ------------------------------------------------------------------------------
# Function: _gi_cleanup
# Purpose.: Remove temp files registered in _GI_TMPFILES.
# Returns.: 0
# ------------------------------------------------------------------------------
_gi_cleanup() {
    local _f
    for _f in "${_GI_TMPFILES[@]+"${_GI_TMPFILES[@]}"}"; do
        rm -f "${_f}" 2>/dev/null || true
    done
    _GI_TMPFILES=()
}

# ------------------------------------------------------------------------------
# Function: do_create
# Purpose.: Create a gold image using runInstaller -createGoldImage.
#           Writes <zip>.sha256 and a manifest with opatch lspatches
#           and binary option listing next to the zip.
# Returns.: 0 on success; exits on error
# ------------------------------------------------------------------------------
do_create() {
    log_info "Creating gold image from: ${OPT_HOME}"
    log_info "Destination directory: ${OPT_DEST}"

    local _runinstaller_bin="${OPT_HOME}/runInstaller"
    _au_check_binary_trust "${_runinstaller_bin}" "runInstaller"

    local -a _cmd=(
        "${OPT_HOME}/runInstaller"
        -silent
        -createGoldImage
        "-destinationLocation" "${OPT_DEST}"
    )

    if [[ -n "${OPT_EXCL_FILES}" ]]; then
        _cmd+=("-exclFiles" "${OPT_EXCL_FILES}")
        log_info "Excluding files: ${OPT_EXCL_FILES}"
    fi

    log_info "Running: ${_cmd[*]}"
    _run_cmd "${_cmd[@]}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "DRY-RUN: skipping sha256 and manifest creation"
        return 0
    fi

    # Find the zip that was just created (newest .zip in dest)
    local _zip
    _zip=$(find "${OPT_DEST}" -maxdepth 1 -name '*.zip' -newer "${OPT_DEST}" \
        2>/dev/null | sort | tail -1 || true)

    if [[ -z "${_zip}" ]]; then
        # Fallback: find the newest zip in dest using find -newer dest itself
        # (dest mtime may not help if already modified; pick newest by find default)
        while IFS= read -r -d '' _candidate; do
            _zip="${_candidate}"
        done < <(find "${OPT_DEST}" -maxdepth 1 -name '*.zip' -print0 2>/dev/null | \
            sort -z | tail -z -n1 2>/dev/null || \
            find "${OPT_DEST}" -maxdepth 1 -name '*.zip' -print0 2>/dev/null)
    fi

    if [[ -z "${_zip}" ]]; then
        die "Gold image zip not found in ${OPT_DEST} after runInstaller"
    fi

    log_info "Gold image created: ${_zip}"

    # Write sha256
    local _sha
    _sha=$(_sha256_file "${_zip}")
    printf '%s  %s\n' "${_sha}" "${_zip##*/}" > "${_zip}.sha256"
    log_info "Checksum written: ${_zip}.sha256 (SHA-256: ${_sha})"

    # Write manifest
    local _manifest="${_zip}.manifest"
    {
        printf '# Gold image manifest\n'
        printf '# Created: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '# Source home: %s\n' "${OPT_HOME}"
        printf '# Zip: %s\n' "${_zip##*/}"
        printf '# SHA-256: %s\n' "${_sha}"
        printf '\n## OPatch lspatches\n'
        if [[ -x "${OPT_HOME}/OPatch/opatch" ]]; then
            "${OPT_HOME}/OPatch/opatch" lspatches 2>/dev/null || true
        else
            printf '# OPatch not found at %s/OPatch/opatch\n' "${OPT_HOME}"
        fi
        printf '\n## Binary options (ar -t rdbms/lib/libknlopt.a)\n'
        if command -v ar >/dev/null 2>&1; then
            au_home_list_binopts "${OPT_HOME}" 2>/dev/null || true
        else
            printf '# ar not found on PATH\n'
        fi
    } > "${_manifest}"

    log_info "Manifest written: ${_manifest}"
    log_info "Gold image creation complete"
}

# ------------------------------------------------------------------------------
# Function: do_verify
# Purpose.: Verify a gold image zip against its .sha256 file.
# Returns.: 0 on success; exits 1 on mismatch
# ------------------------------------------------------------------------------
do_verify() {
    log_info "Verifying: ${OPT_ZIP}"

    local _expected_line _expected_hash _zip_name
    _expected_line=$(cat "${OPT_ZIP}.sha256")
    _expected_hash="${_expected_line%% *}"

    log_info "Expected SHA-256: ${_expected_hash}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        printf 'DRY-RUN: sha256 check of %s against %s\n' "${OPT_ZIP}" "${OPT_ZIP}.sha256" >&2
        return 0
    fi

    local _actual_hash
    _actual_hash=$(_sha256_file "${OPT_ZIP}")
    log_info "Actual  SHA-256: ${_actual_hash}"

    if [[ "${_expected_hash}" == "${_actual_hash}" ]]; then
        log_info "Checksum OK: ${OPT_ZIP}"
    else
        die "Checksum MISMATCH for ${OPT_ZIP}"
    fi
}

# ------------------------------------------------------------------------------
# Function: do_install
# Purpose.: Manual fallback install from a gold image zip:
#           1. Verify checksum
#           2. Unzip into target home
#           3. Run runInstaller -silent software-only with response file
#           4. Print root.sh command (never run it)
# Returns.: 0 on success; exits on error
# ------------------------------------------------------------------------------
do_install() {
    log_info "Installing gold image: ${OPT_ZIP}"
    log_info "Target home: ${OPT_TARGET}"

    # Step 1: Verify checksum
    do_verify

    # Step 2: Check target home
    if [[ -d "${OPT_TARGET}" ]]; then
        local _contents
        _contents=$(find "${OPT_TARGET}" -maxdepth 1 -mindepth 1 2>/dev/null | head -1 || true)
        if [[ -n "${_contents}" ]]; then
            die "Target home exists and is not empty: ${OPT_TARGET}"
        fi
    fi

    # Resolve install parameters
    local _obase="${OPT_ORACLE_BASE:-${AU_ORACLE_BASE:-}}"
    local _edition="${OPT_EDITION:-${AU_EDITION:-EE}}"
    local _inv_loc="${OPT_INVENTORY:-${AU_INVENTORY_LOCATION:-}}"
    local _inv_grp="${OPT_INVENTORY_GROUP:-${AU_INVENTORY_GROUP:-}}"

    # Read from /etc/oraInst.loc if not set
    if [[ -z "${_inv_loc}" || -z "${_inv_grp}" ]] && [[ -f "/etc/oraInst.loc" ]]; then
        local _line _key _val
        while IFS= read -r _line; do
            _key="${_line%%=*}"
            _val="${_line#*=}"
            case "${_key}" in
                inventory_loc) [[ -z "${_inv_loc}" ]] && _inv_loc="${_val}" ;;
                inst_group)    [[ -z "${_inv_grp}" ]] && _inv_grp="${_val}" ;;
            esac
        done < "/etc/oraInst.loc"
    fi

    log_info "ORACLE_BASE: ${_obase}"
    log_info "Edition: ${_edition}"
    [[ -n "${_inv_loc}" ]] && log_info "Inventory: ${_inv_loc}"
    [[ -n "${_inv_grp}" ]] && log_info "Inventory group: ${_inv_grp}"

    # Step 3: Create target directory
    _run_cmd mkdir -p "${OPT_TARGET}"

    # Step 4: Zip-slip check before unzip
    log_info "Checking zip entries for path traversal..."
    _au_check_zip_slip "${OPT_ZIP}"

    # Unzip into target home
    log_info "Unzipping gold image into target home..."
    _run_cmd unzip -q "${OPT_ZIP}" -d "${OPT_TARGET}"

    # Step 5: Build response file
    local _rsp_file="${OPT_RESPONSE_FILE:-}"
    local _rsp_tmp=false
    if [[ -z "${_rsp_file}" ]]; then
        _rsp_file=$(mktemp "${TMPDIR:-/tmp}/au_goldimage_rsp_XXXXXX.rsp")
        _GI_TMPFILES+=("${_rsp_file}")
        _rsp_tmp=true
    fi

    if [[ "${DRY_RUN}" != "true" ]]; then
        {
            printf '[GENERAL]\n'
            printf 'DECLINE_SECURITY_UPDATES=true\n'
            printf '\n[ORACLE_HOME]\n'
            printf 'oracle.install.option=INSTALL_DB_SWONLY\n'
            printf 'ORACLE_HOSTNAME=%s\n' "$(hostname -f 2>/dev/null || hostname)"
            printf 'ORACLE_HOME=%s\n' "${OPT_TARGET}"
            printf 'ORACLE_BASE=%s\n' "${_obase}"
            printf 'oracle.install.db.InstallEdition=%s\n' "${_edition}"
            [[ -n "${_inv_loc}" ]] && printf 'INVENTORY_LOCATION=%s\n' "${_inv_loc}"
            [[ -n "${_inv_grp}" ]] && printf 'oracle.install.db.inventory_group=%s\n' "${_inv_grp}"
            printf 'oracle.install.db.OSDBA_GROUP=%s\n' "${AU_GROUP_OSDBA:-dba}"
            [[ -n "${AU_GROUP_OSOPER:-}" ]] && printf 'oracle.install.db.OSOPER_GROUP=%s\n' "${AU_GROUP_OSOPER}"
            [[ -n "${AU_GROUP_OSBACKUPDBA:-}" ]] && printf 'oracle.install.db.OSBACKUPDBA_GROUP=%s\n' "${AU_GROUP_OSBACKUPDBA}"
            [[ -n "${AU_GROUP_OSDGDBA:-}" ]] && printf 'oracle.install.db.OSDGDBA_GROUP=%s\n' "${AU_GROUP_OSDGDBA}"
            [[ -n "${AU_GROUP_OSKMDBA:-}" ]] && printf 'oracle.install.db.OSKMDBA_GROUP=%s\n' "${AU_GROUP_OSKMDBA}"
            [[ -n "${AU_GROUP_OSRACDBA:-}" ]] && printf 'oracle.install.db.OSRACDBA_GROUP=%s\n' "${AU_GROUP_OSRACDBA}"
        } > "${_rsp_file}"
        chmod 0600 "${_rsp_file}"
        log_debug "Response file written: ${_rsp_file}"
    fi

    # Step 6: Run runInstaller (trust check before execution; skipped in dry-run)
    local _runinstaller="${OPT_TARGET}/runInstaller"
    [[ -x "${_runinstaller}" ]] || _runinstaller="${OPT_TARGET}/oui/bin/runInstaller"
    if [[ "${DRY_RUN}" != "true" ]]; then
        _au_check_binary_trust "${_runinstaller}" "runInstaller (install)"
    fi

    local -a _ri_cmd=(
        "${_runinstaller}"
        -silent
        -responseFile "${_rsp_file}"
        -ignorePrereq
        -waitForCompletion
    )

    log_info "Running: ${_ri_cmd[*]}"
    _run_cmd "${_ri_cmd[@]}"

    # Step 7: Print root.sh command (never run)
    printf '\n'
    printf '==> Run the following as root to complete the installation:\n'
    printf '    %s/root.sh\n' "${OPT_TARGET}"
    printf '\n'
    log_info "root.sh must be run as root (not executed by this script)"
}

# ------------------------------------------------------------------------------
# Function: cleanup
# Purpose.: Cleanup function called on EXIT trap.
# Returns.: 0
# ------------------------------------------------------------------------------
cleanup() {
    _gi_cleanup
    log_debug "Cleanup completed"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    setup_error_handling

    au_load_config

    parse_args "$@"

    validate_inputs

    if [[ "${MODE_CREATE}" == "true" ]]; then
        do_create
    elif [[ "${MODE_VERIFY}" == "true" ]]; then
        do_verify
    elif [[ "${MODE_INSTALL}" == "true" ]]; then
        do_install
    fi

    log_info "${SCRIPT_NAME} completed successfully"
}

main "$@"
# - EOF ------------------------------------------------------------------------
