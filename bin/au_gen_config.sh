#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Script.....: au_gen_config.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.10.09
# Version....: v0.6.1
# Purpose....: Generate a per-host create_home config rendered from au_patch.cfg.
#              With --source-home: AutoUpgrade derives groups/base/edition; the
#              generator fills target home, SID, folders and reports what AU will
#              derive. Without --source-home: reads groups from config.c, resolves
#              inventory, and writes all home_settings.* keys explicitly.
#              Target home is named per decision 9: product/<RU 4-parts> with
#              _2/_3 suffix when the path already exists.
# Usage......: au_gen_config.sh [OPTIONS] --ru <RU>
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.09 oehrli - initial version for WP9
# 2026.10.14 oehrli - --groups-standard applies the AU_GROUP_* defaults (#7)
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

# Load home inspection helpers (WP9; not yet in au_lib.sh loader)
if [[ ! -f "${LIB_DIR}/au_home.sh" ]]; then
    echo "ERROR: Cannot find au_home.sh in ${LIB_DIR}" >&2
    exit 1
fi
# shellcheck source=lib/au_home.sh
. "${LIB_DIR}/au_home.sh"

# =============================================================================
# SCRIPT DEFAULTS
# =============================================================================

: "${DRY_RUN:=false}"
export SCRIPT_VERSION="v0.6.1"

# Script-specific options
OPT_RU=""
OPT_SOURCE_HOME=""
OPT_ORACLE_BASE=""
OPT_INVENTORY=""
OPT_INVENTORY_GROUP=""
OPT_EDITION=""
OPT_GROUPS_FROM=""
OPT_GROUPS_STANDARD=false
OPT_OUTPUT=""
OPT_FORCE=false
OPT_SKIP_GROUP_CHECK=false

# =============================================================================
# FUNCTIONS
# =============================================================================

# ------------------------------------------------------------------------------
# Function: usage
# Purpose.: Display usage information and exit 0.
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} --ru <RU> [OPTIONS]

Description:
  Generate a per-host create_home config rendered from etc/au_patch.cfg.

  With --source-home: AutoUpgrade derives groups, ORACLE_BASE, and edition from
  the source home natively. The generator only sets target home, SID, and folders.

  Without --source-home: groups are read from --groups-from <home|config.c> or
  from AU_GROUP_* env vars (--groups-standard); ORACLE_BASE, inventory, and
  edition must be provided explicitly or via env vars.

Options:
  -h, --help              Show this help message
  -V, --version           Show version
  -v, --verbose           Enable verbose output (DEBUG level)
  -d, --debug             Enable debug output (TRACE level)
  -q, --quiet             Quiet mode (WARN level only)
  -n, --dry-run           Dry-run mode: print derived config and derivation, no file

  --ru <version>          Release Update version, two-part (19.32) or four-part
                          (19.32.0.0). Required.
  --source-home <path>    Existing Oracle Home. AutoUpgrade derives groups,
                          ORACLE_BASE, and edition from it. Sets AU_SOURCE_HOME.
  --oracle-base <path>    ORACLE_BASE for the new home (required without source home)
  --edition <EE|SE2>      Oracle edition (required without source home unless set
                          in env as AU_EDITION)
  --inventory <path>      Oracle inventory location (default: from /etc/oraInst.loc)
  --inventory-group <grp> Inventory group (default: from /etc/oraInst.loc)
  --groups-from <home>    Read OS groups from <home>/rdbms/lib/config.c
  --groups-standard       Use AU_GROUP_* env vars (site config); unset ones
                          default to the preinstall names (dba, oper, ...)
  --skip-group-check      Skip membership check (for dev/test without Oracle groups)
  --output <file>         Write config to FILE (mode 0600). Implies --force to
                          allow re-generation; use --force explicitly to overwrite.
  --force                 Overwrite existing output file

Examples:
  # With source home (groups/base/edition derived by AutoUpgrade):
  ${SCRIPT_NAME} --ru 19.32 --source-home /u01/app/oracle/product/19.28.0.0

  # Without source home (all values explicit):
  ${SCRIPT_NAME} --ru 19.32 --oracle-base /u00/app/oracle --edition EE \\
    --groups-from /u01/app/oracle/product/19.28.0.0 \\
    --output /etc/autoupgrade/create_home_19.32.0.0.cfg

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
            --ru)
                need_val "$1" "${2:-}"
                OPT_RU="$2"
                shift 2
                ;;
            --source-home)
                need_val "$1" "${2:-}"
                OPT_SOURCE_HOME="$2"
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
            --groups-from)
                need_val "$1" "${2:-}"
                OPT_GROUPS_FROM="$2"
                shift 2
                ;;
            --groups-standard)
                OPT_GROUPS_STANDARD=true
                shift
                ;;
            --skip-group-check)
                OPT_SKIP_GROUP_CHECK=true
                shift
                ;;
            --output)
                need_val "$1" "${2:-}"
                OPT_OUTPUT="$2"
                shift 2
                ;;
            --force)
                OPT_FORCE=true
                shift
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
# Function: _read_orainst_loc
# Purpose.: Read inventory_loc and inst_group from /etc/oraInst.loc if present.
# Returns.: 0; sets _ORAINST_LOC and _ORAINST_GROUP
# ------------------------------------------------------------------------------
_read_orainst_loc() {
    _ORAINST_LOC=""
    _ORAINST_GROUP=""

    local _locfile="/etc/oraInst.loc"
    [[ -f "${_locfile}" ]] || return 0

    local _line _key _val
    while IFS= read -r _line; do
        _key="${_line%%=*}"
        _val="${_line#*=}"
        case "${_key}" in
            inventory_loc) _ORAINST_LOC="${_val}" ;;
            inst_group)    _ORAINST_GROUP="${_val}" ;;
        esac
    done < "${_locfile}"
}

# ------------------------------------------------------------------------------
# Function: validate_inputs
# Purpose.: Validate required inputs.
# Returns.: 0 on success; exits on error
# ------------------------------------------------------------------------------
validate_inputs() {
    log_debug "Validating inputs"

    [[ -n "${OPT_RU}" ]] || die "--ru <version> is required"

    # Validate RU format: x.y or x.y.z.w
    case "${OPT_RU}" in
        [0-9]*.[0-9]* | [0-9]*.[0-9]*.[0-9]*.[0-9]*)
            ;;
        *)
            die "--ru value must be x.y or x.y.z.w (e.g. 19.32 or 19.32.0.0)"
            ;;
    esac

    if [[ -n "${OPT_SOURCE_HOME}" && ! -d "${OPT_SOURCE_HOME}" ]]; then
        die "--source-home not a directory: ${OPT_SOURCE_HOME}"
    fi

    if [[ -z "${OPT_SOURCE_HOME}" ]]; then
        # Without source home: oracle_base is required
        if [[ -z "${OPT_ORACLE_BASE:-}" && -z "${AU_ORACLE_BASE:-}" ]]; then
            die "--oracle-base required when --source-home is not set"
        fi

        # Mutually exclusive group sources
        if [[ -n "${OPT_GROUPS_FROM}" && "${OPT_GROUPS_STANDARD}" == "true" ]]; then
            die "--groups-from and --groups-standard are mutually exclusive"
        fi

        if [[ -n "${OPT_GROUPS_FROM}" && ! -d "${OPT_GROUPS_FROM}" && ! -f "${OPT_GROUPS_FROM}" ]]; then
            die "--groups-from path not found: ${OPT_GROUPS_FROM}"
        fi
    fi

    if [[ -n "${OPT_OUTPUT}" && -f "${OPT_OUTPUT}" && "${OPT_FORCE}" != "true" && "${DRY_RUN}" != "true" ]]; then
        die "Output file exists: ${OPT_OUTPUT} (use --force to overwrite)"
    fi
}

# ------------------------------------------------------------------------------
# Function: _derive_groups_from_home
# Purpose.: Read groups from a home or config.c path, print derivation summary.
# Args....: $1 - home or config.c path
#           $2 - source label for log messages
# Returns.: 0; populates AU_GROUP_* variables
# ------------------------------------------------------------------------------
_derive_groups_from_home() {
    local _path="$1"
    local _label="$2"
    local _grp_line _key _val

    log_info "Reading OS groups from ${_label}: ${_path}"

    while IFS= read -r _grp_line; do
        _key="${_grp_line%%=*}"
        _val="${_grp_line#*=}"
        case "${_key}" in
            osdba_group)        AU_GROUP_OSDBA="${_val}" ;;
            osoper_group)       AU_GROUP_OSOPER="${_val}" ;;
            osbackupdba_group)  AU_GROUP_OSBACKUPDBA="${_val}" ;;
            osdgdba_group)      AU_GROUP_OSDGDBA="${_val}" ;;
            oskmdba_group)      AU_GROUP_OSKMDBA="${_val}" ;;
            osracdba_group)     AU_GROUP_OSRACDBA="${_val}" ;;
        esac
    done < <(au_home_read_groups "${_path}")

    export AU_GROUP_OSDBA AU_GROUP_OSOPER AU_GROUP_OSBACKUPDBA \
           AU_GROUP_OSDGDBA AU_GROUP_OSKMDBA AU_GROUP_OSRACDBA
}

# ------------------------------------------------------------------------------
# Function: _check_group_membership
# Purpose.: Verify current user is member of every resolved group.
#           Logs per-group result; fails fast if any group fails.
# Returns.: 0 if all ok; exits 1 with named missing groups
# ------------------------------------------------------------------------------
_check_group_membership() {
    local _groups=()
    local _user_groups
    _user_groups=$(id -nG 2>/dev/null || true)

    local _fail=false
    local _grp _var
    for _grp_var in \
        "AU_GROUP_OSDBA:osdba" \
        "AU_GROUP_OSOPER:osoper" \
        "AU_GROUP_OSBACKUPDBA:osbackupdba" \
        "AU_GROUP_OSDGDBA:osdgdba" \
        "AU_GROUP_OSKMDBA:oskmdba" \
        "AU_GROUP_OSRACDBA:osracdba"
    do
        _var="${_grp_var%%:*}"
        _grp="${!_var:-}"
        [[ -z "${_grp}" ]] && continue

        if printf ' %s ' "${_user_groups}" | grep -qF " ${_grp} " 2>/dev/null; then
            log_debug "Group membership OK: ${_grp} (${_var})"
        else
            log_warn "IS_SOURCE_OH_GROUP_FAIL: current user not in group '${_grp}' (${_var})"
            _fail=true
        fi
    done

    [[ "${_fail}" == "true" ]] && die "Current user is not member of one or more required groups (see WARN above)"
    return 0
}

# ------------------------------------------------------------------------------
# Function: do_work
# Purpose.: Main work: derive values, render config, write or print.
# Returns.: 0 on success; exits on error
# ------------------------------------------------------------------------------
do_work() {
    # Load config for default AU_* variables
    au_load_config

    # --- Apply CLI overrides --------------------------------------------------

    # RU: expand to four parts
    local _ru4
    case "${OPT_RU}" in
        *.*.*.*)
            _ru4="${OPT_RU}"
            ;;
        *.*)
            _ru4="${OPT_RU}.0.0"
            ;;
    esac

    # Oracle base
    if [[ -n "${OPT_ORACLE_BASE}" ]]; then
        AU_ORACLE_BASE="${OPT_ORACLE_BASE}"
        export AU_ORACLE_BASE
    fi

    # Edition
    if [[ -n "${OPT_EDITION}" ]]; then
        AU_EDITION="${OPT_EDITION}"
        export AU_EDITION
    fi

    # Inventory
    _read_orainst_loc
    if [[ -n "${OPT_INVENTORY}" ]]; then
        AU_INVENTORY_LOCATION="${OPT_INVENTORY}"
    elif [[ -z "${AU_INVENTORY_LOCATION:-}" && -n "${_ORAINST_LOC}" ]]; then
        AU_INVENTORY_LOCATION="${_ORAINST_LOC}"
        log_info "Inventory location: ${AU_INVENTORY_LOCATION} (from /etc/oraInst.loc)"
    fi
    export AU_INVENTORY_LOCATION

    if [[ -n "${OPT_INVENTORY_GROUP}" ]]; then
        AU_INVENTORY_GROUP="${OPT_INVENTORY_GROUP}"
    elif [[ -z "${AU_INVENTORY_GROUP:-}" && -n "${_ORAINST_GROUP}" ]]; then
        AU_INVENTORY_GROUP="${_ORAINST_GROUP}"
        log_info "Inventory group: ${AU_INVENTORY_GROUP} (from /etc/oraInst.loc)"
    fi
    export AU_INVENTORY_GROUP

    # Source home
    if [[ -n "${OPT_SOURCE_HOME}" ]]; then
        AU_SOURCE_HOME="${OPT_SOURCE_HOME}"
        export AU_SOURCE_HOME
        log_info "Source home: ${AU_SOURCE_HOME}"
        log_info "  AutoUpgrade will derive ORACLE_BASE, edition, OS groups, and binary options"
    fi

    # Groups (no-source-home path)
    if [[ -z "${OPT_SOURCE_HOME}" ]]; then
        if [[ -n "${OPT_GROUPS_FROM}" ]]; then
            _derive_groups_from_home "${OPT_GROUPS_FROM}" "--groups-from"
        elif [[ "${OPT_GROUPS_STANDARD}" == "true" ]]; then
            # unset AU_GROUP_* -> preinstall RPM names (dba, oper, ...); set ones are kept
            au_set_group_defaults
            log_info "Using AU_GROUP_* from environment, unset ones from preinstall defaults (--groups-standard)"
        else
            log_warn "No group source specified; using AU_GROUP_* from environment (may be empty -> AU defaults to 'dba')"
        fi

        # Validate all group names at every entry point (env or config.c derived).
        # Prevents names like "dba x;y=$z" from reaching the generated config.
        local _gv _gval
        for _gv in AU_GROUP_OSDBA AU_GROUP_OSOPER AU_GROUP_OSBACKUPDBA \
                   AU_GROUP_OSDGDBA AU_GROUP_OSKMDBA AU_GROUP_OSRACDBA; do
            _gval="${!_gv:-}"
            [[ -z "${_gval}" ]] && continue
            au_home_validate_group "${_gval}" "${_gv}"
        done

        if [[ "${OPT_SKIP_GROUP_CHECK}" == "true" ]]; then
            log_warn "Skipping group membership check (--skip-group-check)"
        else
            _check_group_membership
        fi
    fi

    # Target home (decision 9)
    local _oracle_base_for_name="${AU_SOURCE_HOME:+}"
    if [[ -n "${OPT_SOURCE_HOME}" && -x "${OPT_SOURCE_HOME}/bin/orabase" ]]; then
        _au_check_binary_trust "${OPT_SOURCE_HOME}/bin/orabase" "orabase"
        _oracle_base_for_name=$("${OPT_SOURCE_HOME}/bin/orabase" 2>/dev/null || true)
        [[ -n "${_oracle_base_for_name}" ]] || \
            log_warn "orabase returned empty; falling back to AU_ORACLE_BASE for home naming"
    fi
    local _base_for_path="${_oracle_base_for_name:-${AU_ORACLE_BASE:-}}"
    [[ -n "${_base_for_path}" ]] || die "ORACLE_BASE unknown: set --oracle-base or AU_ORACLE_BASE"

    # Build existing homes list from ${_base_for_path}/product/
    local _existing_homes=""
    if [[ -d "${_base_for_path}/product" ]]; then
        _existing_homes=$(find "${_base_for_path}/product" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort || true)
    fi

    local _target_home
    _target_home=$(au_home_target_name "${_base_for_path}" "${_ru4}" "${_existing_homes}")
    AU_TARGET_HOME="${_target_home}"
    export AU_TARGET_HOME

    log_info "Target home: ${AU_TARGET_HOME}"
    log_info "  RU: ${_ru4}"
    if [[ -d "${AU_TARGET_HOME}" ]]; then
        log_warn "Target home already exists: ${AU_TARGET_HOME}"
    fi

    # --- Render config -------------------------------------------------------
    local _cfg_src="${AUTOUPGRADE_BASE}/etc/au_patch.cfg"
    [[ -f "${_cfg_src}" ]] || die "Template not found: ${_cfg_src}"

    # Ensure optional au_patch.cfg variables are at least exported as empty so
    # au_check_cfg_vars (which requires all referenced vars to be set, even
    # empty) does not abort. The renderer drops empty lines.
    : "${AU_SOURCE_HOME:=}"; export AU_SOURCE_HOME
    : "${AU_SID:=}"; export AU_SID
    : "${AU_GOLD_IMAGE:=NO}"; export AU_GOLD_IMAGE
    : "${AU_KEYSTORE:=}"; export AU_KEYSTORE

    # Populate AU_CFG_VARS from the template
    au_check_cfg_vars "${_cfg_src}"

    local _out_file
    local _is_tmp=false
    if [[ "${DRY_RUN}" == "true" ]]; then
        _out_file=$(mktemp "${TMPDIR:-/tmp}/au_gen_config_XXXXXX.cfg")
        _is_tmp=true
    elif [[ -n "${OPT_OUTPUT}" ]]; then
        _out_file="${OPT_OUTPUT}"
    else
        die "Specify --output <file> or use --dry-run"
    fi

    au_render_cfg "${_cfg_src}" "create_home" "${_out_file}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "DRY-RUN: rendered config (not written to disk):"
        cat "${_out_file}" >&2
        rm -f "${_out_file}"
    else
        chmod 0600 "${_out_file}"
        log_info "Config written: ${_out_file} (mode 0600)"
    fi
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

main() {
    setup_error_handling

    parse_args "$@"

    validate_inputs

    do_work

    log_info "${SCRIPT_NAME} completed successfully"
}

main "$@"
# - EOF ------------------------------------------------------------------------
