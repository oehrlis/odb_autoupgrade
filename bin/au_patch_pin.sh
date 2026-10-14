#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Name.......: au_patch_pin.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.10.09
# Version....: v0.6.1
# Purpose....: Write the AU_PATCH pin file (au_patch.env) from patches_info.json
#              after a successful -mode download. Pinning ensures that
#              create_home and deploy use exactly the same patch set.
# Notes......: - JSON parsed with jq (if available), python3 -I (fallback),
#                or WARN with the manual command (Decision 10).
#              - RECOMMENDED becomes RECOMMENDED:<x.y>.
#              - Unversioned RU in a list becomes RU:<x.y>,...
#              - An existing pin with a different value is never silently
#                overwritten: WARN and refuse unless --force / --yes.
#              - --resolve-mrp: additionally resolves MRP to its plain patch
#                number (patchId from patches_info.json); WARN when the file
#                has no MRP entry (measured downloads have none).
#              - Pin file: au_patch.env in the download folder, mode 0600.
#              - WP7 implementation.
# Reference..: https://github.com/oehrlis/odb_autoupgrade
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.09 oehrli - initial implementation (WP7)
# 2026.10.14 oehrli - --resolve-mrp warns when no MRP entry is found (F15)
# ------------------------------------------------------------------------------

set -euo pipefail

# =============================================================================
# BOOTSTRAP
# =============================================================================

SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")
SCRIPT_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SCRIPT_BASE="$(dirname "${SCRIPT_BIN_DIR}")"

export AUTOUPGRADE_BASE="${SCRIPT_BASE}"

# shellcheck source=lib/au_lib.sh
. "${SCRIPT_BIN_DIR}/../lib/au_lib.sh"

# =============================================================================
# SCRIPT DEFAULTS
# =============================================================================

FORCE=false
YES=false
RESOLVE_MRP=false
DRY_RUN=false
FOLDER=""

# Allow-list regex copied from lib/au_env.sh au_read_pin - do NOT edit lib to sync
readonly _AU_PATCH_ALLOWLIST_RE='^[A-Za-z0-9_.,:-]+$'
# Known keyword base names (optional :version suffix allowed for RU/RECOMMENDED/OJVM)
readonly _AU_PATCH_KEYWORD_RE='^(RU|RECOMMENDED|OPATCH|OJVM|DPBP|MRP|CSPU|JDK|OCW|AU|GI)(:[0-9]+(\.[0-9]+){0,4})?$'
readonly _AU_PATCH_NUMBER_RE='^[0-9]+$'
readonly _AU_RELUPDATE_RE='^[0-9]+(\.[0-9]+){1,4}$'
readonly _AU_PATCHID_RE='^[0-9]+$'

# =============================================================================
# FUNCTIONS
# =============================================================================

# ------------------------------------------------------------------------------
# Function: show_help
# Purpose.: Print usage and exit 0.
# ------------------------------------------------------------------------------
show_help() {
    cat <<HELP
Usage: ${SCRIPT_NAME} [OPTIONS] [<download-folder>]

Write AU_PATCH pin file (au_patch.env) from patches_info.json after download.

OPTIONS:
  -h | --help         Show this message and exit
  -V | --version      Show version and exit
  -v | --verbose      Enable verbose output
  -d | --debug        Enable debug output
  -q | --quiet        Suppress informational output
  -n | --dry-run      Print what would be written; do not write the pin file
       --force        Overwrite an existing pin file with a different value
       --yes          Same as --force (non-interactive)
       --resolve-mrp  Resolve MRP keyword to its plain patch number from
                      patches_info.json (patchId of the MRP entry). Downloads
                      measured so far carry no MRP entry: then MRP is kept
                      and a WARN is printed

ARGUMENTS:
  <download-folder>   Path to the download folder containing patches_info.json.
                      Default: AU_DOWNLOAD_FOLDER (from the environment or
                      built-in default: \${AUTOUPGRADE_BASE}/patches).

EXAMPLES:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} /opt/oracle/patches/recommended
  ${SCRIPT_NAME} --resolve-mrp --force /opt/oracle/patches/recommended

EXIT CODES:
  0  Pin file written (or already matches)
  1  Error
HELP
    exit 0
}

# ------------------------------------------------------------------------------
# Function: _au_json_query
# Purpose.: Execute a JSON query using jq or python3 -I fallback.
# Args....: $1 - jq filter (jq syntax)
#           $2 - python3 expression string (applied to json module variable 'd')
#           $3 - path to JSON file
# Returns.: 0; prints result to stdout; empty string on not-found.
# Notes...: If neither jq nor python3 is available, prints WARN and returns
#           empty. Caller must handle the empty result.
# ------------------------------------------------------------------------------
_au_json_query() {
    local _jq_filter="$1"
    local _py_expr="$2"
    local _json_file="$3"

    if command -v jq >/dev/null 2>&1; then
        jq -r "${_jq_filter}" "${_json_file}" 2>/dev/null || true
    elif command -v python3 >/dev/null 2>&1; then
        python3 -I -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
result = ${_py_expr}
if result is None:
    sys.exit(0)
if isinstance(result, list):
    for r in result:
        print(r if r is not None else '')
else:
    print(result)
" "${_json_file}" 2>/dev/null || true
    else
        log_warn "Neither jq nor python3 available; cannot parse patches_info.json"
        log_warn "Manual command: jq -r '${_jq_filter}' '${_json_file}'"
        echo ""
    fi
}

# ------------------------------------------------------------------------------
# Function: _au_version_short
# Purpose.: Convert a full release string to the short AU_PATCH form.
#           19.28.0.0.0 -> 19.28
#           23.26.1.0.0 -> 23.26.1  (21c/23ai: third component significant)
#           21.3.0.0.0  -> 21.3
# Args....: $1 - full version string (e.g. "19.28.0.0.0")
# Returns.: 0; prints short version to stdout
# ------------------------------------------------------------------------------
_au_version_short() {
    local _ver="$1"
    # Split on '.'
    local _p1 _p2 _p3 _rest
    _p1="${_ver%%.*}"; _rest="${_ver#*.}"
    _p2="${_rest%%.*}"; _rest="${_rest#*.}"
    _p3="${_rest%%.*}"

    # For 23ai and later, a non-zero third component is meaningful in AU syntax.
    # Convention: only include third component when it is non-zero.
    if [[ -n "${_p3}" && "${_p3}" != "0" ]]; then
        printf '%s.%s.%s' "${_p1}" "${_p2}" "${_p3}"
    else
        printf '%s.%s' "${_p1}" "${_p2}"
    fi
}

# ------------------------------------------------------------------------------
# Function: _au_read_patches_info
# Purpose.: Parse patches_info.json and populate module-level variables.
#           Sets: _PI_RU_VERSION (short form), _PI_MRP_PATCHID
# Args....: $1 - path to patches_info.json
# Returns.: 0 on success; exits 1 if file unreadable or no RU found.
# ------------------------------------------------------------------------------
_PI_RU_VERSION=""
_PI_MRP_PATCHID=""

_au_read_patches_info() {
    local _json_file="$1"
    [[ -f "${_json_file}" ]] || { log_error "patches_info.json not found: ${_json_file}"; exit 1; }

    # Extract releaseUpdate from the first patch that has it (the RU entry)
    local _ru_full=""
    _ru_full="$(_au_json_query \
        '.patches[] | select(.releaseUpdate != null and .releaseUpdate != "") | .releaseUpdate' \
        '[p["releaseUpdate"] for p in d["patches"] if p.get("releaseUpdate")][0] if [p for p in d["patches"] if p.get("releaseUpdate")] else None' \
        "${_json_file}" | head -1 || true)"

    if [[ -z "${_ru_full}" ]]; then
        log_error "No releaseUpdate found in patches_info.json: ${_json_file}"
        exit 1
    fi

    # Validate releaseUpdate to prevent injection (must be a dot-separated version)
    if [[ ! "${_ru_full}" =~ ${_AU_RELUPDATE_RE} ]]; then
        log_error "Invalid releaseUpdate value in patches_info.json (injection risk): '${_ru_full}'"
        exit 1
    fi

    _PI_RU_VERSION="$(_au_version_short "${_ru_full}")"
    log_debug "Parsed releaseUpdate: ${_ru_full} -> ${_PI_RU_VERSION}"

    # Extract MRP patchId: patch with description matching MRP (Monthly Recommended Patch)
    # MRP entries have "MRP" or "Monthly Recommended Patch" in their description
    # and no releaseUpdate field (or it is empty).
    local _mrp_id=""
    _mrp_id="$(_au_json_query \
        '.patches[] | select((.description // "" | ascii_downcase | contains("monthly recommended")) and (.releaseUpdate == null or .releaseUpdate == "")) | .patchId | tostring' \
        'next((str(p["patchId"]) for p in d["patches"] if "monthly recommended" in (p.get("description") or "").lower() and not p.get("releaseUpdate")), None)' \
        "${_json_file}" | head -1 || true)"

    # Validate MRP patchId to prevent injection (must be digits only)
    if [[ -n "${_mrp_id}" ]] && [[ ! "${_mrp_id}" =~ ${_AU_PATCHID_RE} ]]; then
        log_error "Invalid MRP patchId in patches_info.json (injection risk): '${_mrp_id}'"
        exit 1
    fi

    _PI_MRP_PATCHID="${_mrp_id}"
    [[ -n "${_PI_MRP_PATCHID}" ]] && log_debug "MRP patchId: ${_PI_MRP_PATCHID}"
    return 0
}

# ------------------------------------------------------------------------------
# Function: _au_build_pinned_value
# Purpose.: Compute the pinned AU_PATCH value from the current AU_PATCH and
#           the resolved RU version.
#           RECOMMENDED           -> RECOMMENDED:<x.y>
#           RECOMMENDED:<x.y>     -> RECOMMENDED:<x.y>  (already pinned)
#           RU:x.y,...            -> RU:x.y,...          (already versioned)
#           RU,...                -> RU:<x.y>,...        (add version)
# Args....: $1 - current AU_PATCH value
#           $2 - short RU version (e.g. "19.28")
#           $3 - MRP patchId (optional, used when --resolve-mrp)
# Returns.: 0; prints new pinned value to stdout
# ------------------------------------------------------------------------------
_au_build_pinned_value() {
    local _cur="$1"
    local _ver="$2"
    local _mrp_id="${3:-}"

    local _result=""

    # RECOMMENDED (with or without existing version)
    if [[ "${_cur}" == "RECOMMENDED" ]]; then
        _result="RECOMMENDED:${_ver}"
    elif [[ "${_cur}" == RECOMMENDED:* ]]; then
        # Already pinned; normalise to the resolved version
        _result="RECOMMENDED:${_ver}"
    else
        # List form: process each comma-separated token
        local _new_list="" _token
        local _saved_IFS="${IFS}"
        IFS=',' read -ra _tokens <<< "${_cur}"
        IFS="${_saved_IFS}"
        for _token in "${_tokens[@]}"; do
            # Strip whitespace
            _token="${_token#"${_token%%[![:space:]]*}"}"
            _token="${_token%"${_token##*[![:space:]]}"}"
            case "${_token}" in
                RU)
                    # Bare RU: add version
                    _token="RU:${_ver}"
                    ;;
                RU:*)
                    # Already versioned; keep
                    ;;
                MRP)
                    # Replace MRP with plain patch number if --resolve-mrp and id known
                    if [[ "${RESOLVE_MRP}" == true && -n "${_mrp_id}" ]]; then
                        _token="${_mrp_id}"
                    fi
                    ;;
                *)
                    # OJVM:x.y, OPATCH, DPBP, CSPU, plain numbers: keep as-is
                    ;;
            esac
            _new_list="${_new_list:+${_new_list},}${_token}"
        done
        _result="${_new_list}"
    fi

    printf '%s' "${_result}"
}

# ------------------------------------------------------------------------------
# Function: _au_validate_pin_value
# Purpose.: Validate the final AU_PATCH value before writing.
#           Applies the allow-list regex from lib/au_env.sh au_read_pin and
#           checks every comma-separated element is a known keyword or plain number.
# Args....: $1 - AU_PATCH value to validate
# Returns.: 0 if valid; exits 1 naming the bad value
# ------------------------------------------------------------------------------
_au_validate_pin_value() {
    local _val="$1"

    # Allow-list from lib/au_env.sh au_read_pin (copied constant; do not edit lib)
    if [[ ! "${_val}" =~ ${_AU_PATCH_ALLOWLIST_RE} ]]; then
        log_error "AU_PATCH value '${_val}' fails allow-list check (^[A-Za-z0-9_.,:-]+$)"
        exit 1
    fi

    # Per-element: must be a known keyword (with optional :version) or plain number
    local _saved_IFS="${IFS}"
    IFS=',' read -ra _elems <<< "${_val}"
    IFS="${_saved_IFS}"
    local _elem
    for _elem in "${_elems[@]}"; do
        if [[ "${_elem}" =~ ${_AU_PATCH_KEYWORD_RE} ]] || \
           [[ "${_elem}" =~ ${_AU_PATCH_NUMBER_RE} ]]; then
            continue
        fi
        log_error "AU_PATCH element '${_elem}' is neither a known keyword nor a plain patch number"
        log_error "  Known keywords: RU, RECOMMENDED, OPATCH, OJVM, DPBP, MRP, CSPU, JDK, OCW, AU, GI"
        log_error "  Keywords may carry a version suffix: KEYWORD:x.y (RU, RECOMMENDED, OJVM)"
        log_error "  Full AU_PATCH value: '${_val}'"
        exit 1
    done
}

# ------------------------------------------------------------------------------
# Function: _au_write_pin
# Purpose.: Write (or check) the pin file.
# Args....: $1 - pin file path
#           $2 - new AU_PATCH value
# Returns.: 0 on success; exits 1 on conflict without --force
# ------------------------------------------------------------------------------
_au_write_pin() {
    local _pin_file="$1"
    local _new_val="$2"

    # Refuse to overwrite a symlink at any path position
    if [[ -L "${_pin_file}" ]]; then
        log_error "Pin file is a symlink; refusing to overwrite: ${_pin_file}"
        exit 1
    fi

    # Conflict check
    if [[ -f "${_pin_file}" ]]; then
        local _existing=""
        # Read current pin value (same parser as au_read_pin)
        local _line _trim _val
        while IFS= read -r _line || [[ -n "${_line}" ]]; do
            _trim="${_line#"${_line%%[![:space:]]*}"}"
            _trim="${_trim%"${_trim##*[![:space:]]}"}"
            [[ -z "${_trim}" || "${_trim}" == '#'* ]] && continue
            if [[ "${_trim}" == AU_PATCH=* ]]; then
                _val="${_trim#AU_PATCH=}"
                if [[ "${_val}" == '"'*'"' ]]; then
                    _val="${_val#\"}"; _val="${_val%\"}"
                elif [[ "${_val}" == "'"*"'" ]]; then
                    _val="${_val#\'}"; _val="${_val%\'}"
                fi
                _existing="${_val}"
            fi
        done < "${_pin_file}"

        if [[ -n "${_existing}" && "${_existing}" != "${_new_val}" ]]; then
            if [[ "${FORCE}" == false && "${YES}" == false ]]; then
                log_warn "Existing pin conflicts:"
                log_warn "  current : AU_PATCH=${_existing}"
                log_warn "  new     : AU_PATCH=${_new_val}"
                log_warn "Use --force to overwrite. Pin file unchanged: ${_pin_file}"
                exit 1
            else
                log_warn "Overwriting conflicting pin (--force): ${_existing} -> ${_new_val}"
            fi
        elif [[ "${_existing}" == "${_new_val}" ]]; then
            log_info "Pin file already matches (${_new_val}): ${_pin_file}"
            return 0
        fi
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "DRY-RUN: would write: AU_PATCH=${_new_val}"
        log_info "DRY-RUN: to file: ${_pin_file}"
        return 0
    fi

    # Write the pin file atomically via a temp file.
    # Register _tmp in _AU_TMPFILES so _au_purge_tmpfiles (library EXIT cleanup)
    # removes it on failure. Never set a script-level trap with an interpolated
    # path: a folder named p'$(cmd)'q would execute code.
    local _tmp=""
    _tmp="$(mktemp "${_pin_file}.XXXXXX")"
    _AU_TMPFILES+=("${_tmp}")
    cat > "${_tmp}" <<PINFILE
# au_patch.env - AutoUpgrade patch pin file
# Written by au_patch_pin.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# This file is parsed, never sourced. Only AU_PATCH= is honoured.
AU_PATCH=${_new_val}
PINFILE
    chmod 0600 "${_tmp}"
    mv "${_tmp}" "${_pin_file}"
    # mv succeeded: remove _tmp from cleanup list (path no longer exists)
    local -a _au_tf_new=()
    local _au_tf_e
    for _au_tf_e in "${_AU_TMPFILES[@]+"${_AU_TMPFILES[@]}"}"; do
        [[ "${_au_tf_e}" == "${_tmp}" ]] || _au_tf_new+=("${_au_tf_e}")
    done
    _AU_TMPFILES=("${_au_tf_new[@]+"${_au_tf_new[@]}"}")
    log_info "Pin file written: AU_PATCH=${_new_val}"
    log_info "Pin file: ${_pin_file}"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)    show_help ;;
            -V|--version) echo "${SCRIPT_NAME} v0.6.1"; exit 0 ;;
            -v|--verbose) export LOG_LEVEL=2; shift ;;
            -d|--debug)   export LOG_LEVEL=1; shift ;;
            -q|--quiet)   export LOG_LEVEL=4; shift ;;
            -n|--dry-run) DRY_RUN=true; shift ;;
            --force)      FORCE=true; shift ;;
            --yes)        YES=true; shift ;;
            --resolve-mrp) RESOLVE_MRP=true; shift ;;
            -*)
                log_error "Unknown option: $1"
                echo "Run ${SCRIPT_NAME} --help for usage." >&2
                exit 1
                ;;
            *)
                if [[ -z "${FOLDER}" ]]; then
                    FOLDER="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Load configuration to resolve AU_DOWNLOAD_FOLDER
    au_load_config

    # Determine folder
    if [[ -z "${FOLDER}" ]]; then
        FOLDER="${AU_DOWNLOAD_FOLDER}"
    fi

    local _json_file="${FOLDER}/patches_info.json"
    local _pin_file="${FOLDER}/au_patch.env"

    log_info "Download folder: ${FOLDER}"

    # Read patches_info.json
    _au_read_patches_info "${_json_file}"

    # Determine current AU_PATCH source for the new value
    local _current_patch="${AU_PATCH:-RECOMMENDED}"

    # Build new pinned value
    local _new_pin
    _new_pin="$(_au_build_pinned_value "${_current_patch}" "${_PI_RU_VERSION}" "${_PI_MRP_PATCHID:-}")"

    # Validate the final value before writing
    _au_validate_pin_value "${_new_pin}"

    log_info "AU_PATCH (before): ${_current_patch}"
    log_info "RU version:        ${_PI_RU_VERSION}"
    [[ -n "${_PI_MRP_PATCHID}" ]] && log_info "MRP patchId:       ${_PI_MRP_PATCHID}"
    log_info "AU_PATCH (pinned): ${_new_pin}"
    if [[ "${RESOLVE_MRP}" == true && -z "${_PI_MRP_PATCHID}" && ",${_current_patch// /}," == *,MRP,* ]]; then
        log_warn "--resolve-mrp: no MRP entry in patches_info.json - MRP keyword kept;" \
            "record the MOS patch number in the profile header instead (doc/patch-profiles.md)"
    fi

    # Write pin file
    _au_write_pin "${_pin_file}" "${_new_pin}"
}

main "$@"
# - EOF ------------------------------------------------------------------------
