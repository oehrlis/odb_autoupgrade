#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Script.....: au_home_verify.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.10.09
# Version....: v0.6.1
# Purpose....: Verify an Oracle Home against expected values:
#                - OPatch patch list vs patches_info.json patch numbers
#                - Binary options (ar -t libknlopt.a) vs source home or expected
#                - OS groups (config.c SS_*_GRP) vs source home or expected values
#                - Edition check (if --edition given)
#              Exits 0 if all checks pass, 1 if any mismatch found.
# Usage......: au_home_verify.sh --home <OH> [OPTIONS]
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.09 oehrli - initial version for WP9
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

# Load home inspection helpers (WP9)
if [[ ! -f "${LIB_DIR}/au_home.sh" ]]; then
    echo "ERROR: Cannot find au_home.sh in ${LIB_DIR}" >&2
    exit 1
fi
# shellcheck source=lib/au_home.sh
. "${LIB_DIR}/au_home.sh"

# =============================================================================
# SCRIPT DEFAULTS
# =============================================================================

export SCRIPT_VERSION="v0.6.1"

OPT_HOME=""
OPT_SOURCE_HOME=""
OPT_DOWNLOAD_FOLDER=""
OPT_EDITION=""
OPT_PATCHES_JSON=""

# Check flags
CHECK_PATCHES=true
CHECK_BINOPTS=true
CHECK_GROUPS=true

# Counters
_FAIL_COUNT=0
_PASS_COUNT=0

# =============================================================================
# FUNCTIONS
# =============================================================================

# ------------------------------------------------------------------------------
# Function: usage
# Purpose.: Display usage information and exit 0.
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} --home <OH> [OPTIONS]

Description:
  Verify an Oracle Home against expected values. Compares:
    - OPatch lspatches vs patch numbers from patches_info.json
    - Binary options (ar -t rdbms/lib/libknlopt.a) vs source home
    - OS groups (rdbms/lib/config.c) vs source home or expected values
    - Edition (if --edition given)

  Exits 0 if all enabled checks pass; exits 1 if any mismatch is found.
  Each mismatch is printed with a named diff to stdout.

Options:
  -h, --help                 Show this help message
  -V, --version              Show version
  -v, --verbose              Enable verbose output (DEBUG level)
  -d, --debug                Enable debug output (TRACE level)
  -q, --quiet                Quiet mode (WARN level only)

  --home <path>              Oracle Home to verify. Required.
  --source-home <path>       Reference home for binary options and group comparison.
  --download-folder <path>   Folder containing patches_info.json (default: AU_DOWNLOAD_FOLDER)
  --patches-json <file>      Direct path to patches_info.json (overrides --download-folder)
  --edition <EE|SE2>         Expected Oracle edition.
  --no-patches               Skip patch list check.
  --no-binopts               Skip binary option check.
  --no-groups                Skip OS group check.

Examples:
  # Full check against source home and download folder:
  ${SCRIPT_NAME} --home /u01/app/oracle/product/19.32.0.0 \\
    --source-home /u01/app/oracle/product/19.28.0.0 \\
    --download-folder /opt/autoupgrade/patches

  # Groups and patches only (no source home):
  ${SCRIPT_NAME} --home /u01/app/oracle/product/19.32.0.0 \\
    --patches-json /opt/autoupgrade/patches/patches_info.json \\
    --no-binopts

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
            --home)
                need_val "$1" "${2:-}"
                OPT_HOME="$2"
                shift 2
                ;;
            --source-home)
                need_val "$1" "${2:-}"
                OPT_SOURCE_HOME="$2"
                shift 2
                ;;
            --download-folder)
                need_val "$1" "${2:-}"
                OPT_DOWNLOAD_FOLDER="$2"
                shift 2
                ;;
            --patches-json)
                need_val "$1" "${2:-}"
                OPT_PATCHES_JSON="$2"
                shift 2
                ;;
            --edition)
                need_val "$1" "${2:-}"
                OPT_EDITION="$2"
                shift 2
                ;;
            --no-patches)
                CHECK_PATCHES=false
                shift
                ;;
            --no-binopts)
                CHECK_BINOPTS=false
                shift
                ;;
            --no-groups)
                CHECK_GROUPS=false
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
    [[ -n "${OPT_HOME}" ]] || die "--home is required"
    [[ -d "${OPT_HOME}" ]] || die "--home not a directory: ${OPT_HOME}"

    if [[ -n "${OPT_SOURCE_HOME}" && ! -d "${OPT_SOURCE_HOME}" ]]; then
        die "--source-home not a directory: ${OPT_SOURCE_HOME}"
    fi

    if [[ "${CHECK_BINOPTS}" == "true" && -z "${OPT_SOURCE_HOME}" ]]; then
        log_warn "Binary option check requires --source-home; skipping (--no-binopts to suppress this warning)"
        CHECK_BINOPTS=false
    fi
}

# ------------------------------------------------------------------------------
# Function: _pass
# Purpose.: Record a passing check.
# Args....: $1 - check name and description
# ------------------------------------------------------------------------------
_pass() {
    log_info "PASS: $1"
    _PASS_COUNT=$(( _PASS_COUNT + 1 ))
}

# ------------------------------------------------------------------------------
# Function: _fail
# Purpose.: Record a failing check; prints named diff to stdout.
# Args....: $1 - check name
#           $2 - expected value / description
#           $3 - actual value / description
# ------------------------------------------------------------------------------
_fail() {
    local _check="$1"
    local _expected="$2"
    local _actual="$3"
    log_warn "FAIL: ${_check}"
    printf 'DIFF [%s]\n  expected: %s\n  actual:   %s\n' "${_check}" "${_expected}" "${_actual}"
    _FAIL_COUNT=$(( _FAIL_COUNT + 1 ))
}

# ------------------------------------------------------------------------------
# Function: _check_patches
# Purpose.: Compare OPatch lspatches output vs patch IDs in patches_info.json.
# Returns.: 0; increments _FAIL_COUNT on mismatch
# ------------------------------------------------------------------------------
_check_patches() {
    log_debug "Checking patches"

    # Resolve patches_info.json
    local _json="${OPT_PATCHES_JSON:-}"
    if [[ -z "${_json}" ]]; then
        local _folder="${OPT_DOWNLOAD_FOLDER:-${AU_DOWNLOAD_FOLDER:-}}"
        if [[ -n "${_folder}" ]]; then
            _json="${_folder}/patches_info.json"
        fi
    fi

    if [[ -z "${_json}" || ! -f "${_json}" ]]; then
        log_warn "patches_info.json not found; skipping patch check (provide --patches-json or --download-folder)"
        return 0
    fi

    # Read patch IDs from JSON (jq or python3 -I)
    local _expected_ids=""
    if command -v jq >/dev/null 2>&1; then
        _expected_ids=$(jq -r '.patches[].patchId // empty' "${_json}" 2>/dev/null | sort || true)
    elif command -v python3 >/dev/null 2>&1; then
        _expected_ids=$(python3 -I - "${_json}" <<'PYEOF' 2>/dev/null | sort || true
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
for p in data.get('patches', []):
    pid = p.get('patchId', '')
    if pid:
        print(pid)
PYEOF
        )
    else
        log_warn "Neither jq nor python3 found; cannot parse patches_info.json (patch check skipped)"
        return 0
    fi

    if [[ -z "${_expected_ids}" ]]; then
        log_warn "No patch IDs found in patches_info.json; skipping patch check"
        return 0
    fi

    # Read installed patches from OPatch
    local _opatch="${OPT_HOME}/OPatch/opatch"
    if [[ ! -x "${_opatch}" ]]; then
        log_warn "OPatch not found: ${_opatch}; skipping patch check"
        return 0
    fi
    _au_check_binary_trust "${_opatch}" "opatch"

    local _installed_ids
    _installed_ids=$("${_opatch}" lspatches 2>/dev/null | \
        grep -E '^[0-9]+;' | \
        sed -E 's/^([0-9]+);.*/\1/' | sort || true)

    # Compare: all expected IDs must appear in installed set
    local _missing=()
    local _id
    while IFS= read -r _id; do
        [[ -z "${_id}" ]] && continue
        if ! printf '%s\n' "${_installed_ids}" | grep -qxF "${_id}" 2>/dev/null; then
            _missing+=("${_id}")
        fi
    done <<< "${_expected_ids}"

    if [[ "${#_missing[@]}" -eq 0 ]]; then
        _pass "patch-list: all expected patches present in ${OPT_HOME}"
    else
        _fail "patch-list" \
            "all patches from patches_info.json installed" \
            "missing patch IDs: ${_missing[*]}"
    fi
}

# ------------------------------------------------------------------------------
# Function: _check_binopts
# Purpose.: Compare binary options of OPT_HOME vs OPT_SOURCE_HOME.
# Returns.: 0; increments _FAIL_COUNT on mismatch
# ------------------------------------------------------------------------------
_check_binopts() {
    log_debug "Checking binary options"

    if ! command -v ar >/dev/null 2>&1; then
        log_warn "ar not found; skipping binary option check"
        return 0
    fi

    local _src_opts _tgt_opts _pair _opt _src_val _tgt_val _mismatch=false

    local _src_out _tgt_out
    _src_out=$(au_home_list_binopts "${OPT_SOURCE_HOME}" 2>/dev/null || true)
    _tgt_out=$(au_home_list_binopts "${OPT_HOME}" 2>/dev/null || true)

    if [[ -z "${_src_out}" ]]; then
        log_warn "Could not read binary options from source home: ${OPT_SOURCE_HOME}"
        return 0
    fi
    if [[ -z "${_tgt_out}" ]]; then
        log_warn "Could not read binary options from target home: ${OPT_HOME}"
        return 0
    fi

    # Compare option by option
    while IFS= read -r _pair; do
        [[ -z "${_pair}" ]] && continue
        _opt="${_pair%%=*}"
        _src_val="${_pair#*=}"
        _tgt_val=$(printf '%s\n' "${_tgt_out}" | grep -E "^${_opt}=" | head -1 || true)
        _tgt_val="${_tgt_val#*=}"

        if [[ "${_src_val}" == "${_tgt_val}" ]]; then
            log_debug "Binary option ${_opt}: ${_src_val} (matches)"
        else
            _fail "binopt-${_opt}" \
                "${_opt}=${_src_val} (from source home)" \
                "${_opt}=${_tgt_val:-unknown} (in target home)"
            _mismatch=true
        fi
    done <<< "${_src_out}"

    [[ "${_mismatch}" == "false" ]] && \
        _pass "binary-options: target home matches source home"
}

# ------------------------------------------------------------------------------
# Function: _check_groups
# Purpose.: Compare OS groups of OPT_HOME vs OPT_SOURCE_HOME or expected values.
# Returns.: 0; increments _FAIL_COUNT on mismatch
# ------------------------------------------------------------------------------
_check_groups() {
    log_debug "Checking OS groups"

    local _tgt_out
    _tgt_out=$(au_home_read_groups "${OPT_HOME}" 2>/dev/null || true)

    if [[ -z "${_tgt_out}" ]]; then
        log_warn "Could not read OS groups from target home: ${OPT_HOME}"
        return 0
    fi

    if [[ -n "${OPT_SOURCE_HOME}" ]]; then
        local _src_out
        _src_out=$(au_home_read_groups "${OPT_SOURCE_HOME}" 2>/dev/null || true)

        if [[ -z "${_src_out}" ]]; then
            log_warn "Could not read OS groups from source home: ${OPT_SOURCE_HOME}"
            return 0
        fi

        local _pair _key _src_val _tgt_val _mismatch=false
        while IFS= read -r _pair; do
            [[ -z "${_pair}" ]] && continue
            _key="${_pair%%=*}"
            _src_val="${_pair#*=}"
            _tgt_val=$(printf '%s\n' "${_tgt_out}" | grep -E "^${_key}=" | head -1 || true)
            _tgt_val="${_tgt_val#*=}"

            if [[ "${_src_val}" == "${_tgt_val}" ]]; then
                log_debug "Group ${_key}: ${_src_val} (matches)"
            else
                _fail "group-${_key}" \
                    "${_key}=${_src_val} (from source home)" \
                    "${_key}=${_tgt_val:-not set} (in target home)"
                _mismatch=true
            fi
        done <<< "${_src_out}"

        [[ "${_mismatch}" == "false" ]] && \
            _pass "os-groups: target home matches source home"
    else
        # Compare against AU_GROUP_* env vars if set
        local _mismatch=false
        local _env_map=(
            "osdba_group:AU_GROUP_OSDBA"
            "osoper_group:AU_GROUP_OSOPER"
            "osbackupdba_group:AU_GROUP_OSBACKUPDBA"
            "osdgdba_group:AU_GROUP_OSDGDBA"
            "oskmdba_group:AU_GROUP_OSKMDBA"
            "osracdba_group:AU_GROUP_OSRACDBA"
        )
        local _pair _cfg_key _env_var _exp_val _act_val
        for _pair in "${_env_map[@]}"; do
            _cfg_key="${_pair%%:*}"
            _env_var="${_pair#*:}"
            _exp_val="${!_env_var:-}"
            [[ -z "${_exp_val}" ]] && continue

            _act_val=$(printf '%s\n' "${_tgt_out}" | grep -E "^${_cfg_key}=" | head -1 || true)
            _act_val="${_act_val#*=}"

            if [[ "${_exp_val}" == "${_act_val}" ]]; then
                log_debug "Group ${_cfg_key}: ${_act_val} (matches ${_env_var})"
            else
                _fail "group-${_cfg_key}" \
                    "${_cfg_key}=${_exp_val} (from ${_env_var})" \
                    "${_cfg_key}=${_act_val:-not set} (in target home)"
                _mismatch=true
            fi
        done

        [[ "${_mismatch}" == "false" ]] && \
            _pass "os-groups: target home matches expected values"
    fi
}

# ------------------------------------------------------------------------------
# Function: _check_edition
# Purpose.: Check Oracle edition of OPT_HOME.
# Returns.: 0; increments _FAIL_COUNT on mismatch
# ------------------------------------------------------------------------------
_check_edition() {
    log_debug "Checking edition"

    # AutoUpgrade reads edition from files; we use the release.dif or inventory
    local _inv_xml="${OPT_HOME}/inventory/ContentsXML/comps.xml"
    local _actual_edition="unknown"

    if [[ -f "${OPT_HOME}/bin/oracle" ]]; then
        # Check for SE2 marker file; fall back to EE assumption
        if [[ -f "${OPT_HOME}/rdbms/admin/catse2.sql" ]]; then
            _actual_edition="SE2"
        else
            _actual_edition="EE"
        fi
    fi

    if [[ "${OPT_EDITION}" == "${_actual_edition}" ]]; then
        _pass "edition: ${_actual_edition}"
    else
        _fail "edition" "${OPT_EDITION}" "${_actual_edition}"
    fi
}

# ------------------------------------------------------------------------------
# Function: do_work
# Purpose.: Run all enabled verification checks.
# Returns.: 0 if all pass; exits 1 if any fail
# ------------------------------------------------------------------------------
do_work() {
    au_load_config

    log_info "Verifying Oracle Home: ${OPT_HOME}"
    [[ -n "${OPT_SOURCE_HOME}" ]] && log_info "Reference home: ${OPT_SOURCE_HOME}"

    [[ "${CHECK_PATCHES}" == "true" ]] && _check_patches
    [[ "${CHECK_BINOPTS}" == "true" ]] && _check_binopts
    [[ "${CHECK_GROUPS}"  == "true" ]] && _check_groups
    [[ -n "${OPT_EDITION}" ]]         && _check_edition

    log_info "Verification complete: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"

    if [[ "${_FAIL_COUNT}" -gt 0 ]]; then
        die "Verification failed: ${_FAIL_COUNT} check(s) did not pass" 1
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

    au_load_config

    parse_args "$@"

    validate_inputs

    do_work

    log_info "${SCRIPT_NAME} completed successfully"
}

main "$@"
# - EOF ------------------------------------------------------------------------
