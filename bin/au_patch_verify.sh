#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Name.......: au_patch_verify.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.10.09
# Version....: v0.6.0
# Purpose....: Verify a download folder against patches_info.json.
#              Checks SHA-256 and size of every listed file; names missing,
#              extra, and unlisted files. Also verifies that the required JSON
#              metadata files exist (bug-map.json / aru-bug-map.json,
#              patches_info.json).
# Notes......: - SHA-256: sha256sum (Linux) or shasum -a 256 (macOS/BSD).
#              - SHA-256 field name: "SHA-256" or "checksum-256" (both accepted).
#              - Files in the folder not listed in patches_info.json are named
#                (no silent skip); au_patch.env and JSON metadata files are
#                excluded from the "unlisted" check.
#              - Exit 0: all checks pass. Exit 1: any failure.
#              - WP7 implementation.
# Reference..: https://github.com/oehrlis/odb_autoupgrade
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.09 oehrli - initial implementation (WP7)
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

FOLDER=""
_VERIFY_FAIL=false

# Files that are always expected in a download folder (metadata)
_AU_METADATA_FILES=("patches_info.json")
# At least one of the bug-map variants must be present
_AU_BUGMAP_VARIANTS=("bug-map.json" "aru-bug-map.json")
# Files to exclude from "unlisted" check
_AU_KNOWN_EXTRAS=("au_patch.env" "patches_info.json" "bug-map.json" "aru-bug-map.json")

# =============================================================================
# FUNCTIONS
# =============================================================================

show_help() {
    cat <<HELP
Usage: ${SCRIPT_NAME} [OPTIONS] [<download-folder>]

Verify a download folder against patches_info.json (size and SHA-256).

OPTIONS:
  -h | --help     Show this message and exit
  -V | --version  Show version and exit
  -v | --verbose  Enable verbose output
  -d | --debug    Enable debug output
  -q | --quiet    Suppress informational output

ARGUMENTS:
  <download-folder>   Path to the download folder. Default: AU_DOWNLOAD_FOLDER.

EXIT CODES:
  0  All checks passed
  1  One or more checks failed

NOTE: Hashes come from the same patches_info.json file; they prove transfer integrity, not authenticity.
HELP
    exit 0
}

# ------------------------------------------------------------------------------
# Function: _au_sha256sum
# Purpose.: Compute SHA-256 of a file; portable BSD/Linux.
# Args....: $1 - file path
# Returns.: 0; prints hex digest to stdout
# ------------------------------------------------------------------------------
_au_sha256sum() {
    local _f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${_f}" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${_f}" | cut -d' ' -f1
    else
        log_error "No SHA-256 tool available (sha256sum or shasum)"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Function: _au_parse_patches_info
# Purpose.: Parse patches_info.json, emit one line per file entry:
#           <filename>|<expected-sha256>|<expected-size>
#           Uses jq or python3 -I.
# Args....: $1 - path to patches_info.json
# Returns.: 0; prints records to stdout
# ------------------------------------------------------------------------------
_au_parse_patches_info() {
    local _json="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r '
            .patches[].files[]? |
            [
                .name,
                (if .["SHA-256"] != null then .["SHA-256"]
                 elif .["checksum-256"] != null then .["checksum-256"]
                 else "" end),
                (.size | tostring)
            ] | join("|")
        ' "${_json}"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -I -c "
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
for patch in d.get('patches', []):
    for f in patch.get('files', []):
        name = f.get('name', '')
        sha256 = f.get('SHA-256') or f.get('checksum-256') or ''
        size = str(f.get('size', ''))
        print('|'.join([name, sha256, size]))
" "${_json}"
    else
        log_error "Neither jq nor python3 available; cannot parse patches_info.json"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Function: _au_is_known_extra
# Purpose.: Return 0 if the filename is in the known-extras exclusion list.
# Args....: $1 - filename (basename)
# ------------------------------------------------------------------------------
_au_is_known_extra() {
    local _name="$1"
    local _k
    for _k in "${_AU_KNOWN_EXTRAS[@]}"; do
        [[ "${_name}" == "${_k}" ]] && return 0
    done
    return 1
}

# ------------------------------------------------------------------------------
# Function: verify_folder
# Purpose.: Main verification logic.
# Args....: $1 - download folder path
# ------------------------------------------------------------------------------
verify_folder() {
    local _folder="$1"

    [[ -d "${_folder}" ]] || { log_error "Download folder not found: ${_folder}"; exit 1; }

    local _json="${_folder}/patches_info.json"
    [[ -f "${_json}" ]] || { log_error "patches_info.json not found in ${_folder}"; exit 1; }

    # -------------------------------------------------------------------------
    # Check required metadata files
    # -------------------------------------------------------------------------
    log_info "Checking metadata files..."
    local _bugmap_found=false _bm
    for _bm in "${_AU_BUGMAP_VARIANTS[@]}"; do
        if [[ -f "${_folder}/${_bm}" ]]; then
            log_info "  OK  ${_bm}"
            _bugmap_found=true
        else
            log_debug "  --  ${_bm} (not found, checking next variant)"
        fi
    done
    if [[ "${_bugmap_found}" == false ]]; then
        log_error "Missing: bug-map.json or aru-bug-map.json (required by AutoUpgrade)"
        _VERIFY_FAIL=true
    fi

    # -------------------------------------------------------------------------
    # Parse patches_info.json - fail hard if parser fails
    # -------------------------------------------------------------------------
    local _parse_output=""
    _parse_output="$(_au_parse_patches_info "${_json}")" || {
        log_error "Failed to parse patches_info.json (parser error): ${_json}"
        exit 1
    }

    # Count file entries; fail if none found
    local _entry_count=0
    local _l
    while IFS= read -r _l; do
        [[ -n "${_l}" ]] && _entry_count=$(( _entry_count + 1 ))
    done <<< "${_parse_output}"

    if [[ "${_entry_count}" -eq 0 ]]; then
        log_error "No file entries found in patches_info.json: ${_json}"
        exit 1
    fi

    # -------------------------------------------------------------------------
    # Verify each listed file
    # -------------------------------------------------------------------------
    local -a _expected_names=()
    local _name _sha256_exp _size_exp

    log_info "Verifying files listed in patches_info.json..."
    while IFS='|' read -r _name _sha256_exp _size_exp; do
        [[ -z "${_name}" ]] && continue

        # --- Name safety check: reject injection-prone names ---
        if [[ -z "${_name}" ]] || \
           [[ "${_name}" == */* ]] || \
           [[ "${_name}" == .* ]] || \
           [[ "${_name}" == *'|'* ]] || \
           [[ "${_name}" == *$'\n'* ]]; then
            log_error "  INVALID NAME in patches_info.json: '${_name}' (must be a plain basename with no /, leading dot, or control chars)"
            _VERIFY_FAIL=true
            continue
        fi

        _expected_names+=("${_name}")

        local _filepath="${_folder}/${_name}"

        # Symlinks are refused for listed files
        if [[ -L "${_filepath}" ]]; then
            log_error "  SYMLINK: '${_name}' is a symlink; a regular file is required"
            _VERIFY_FAIL=true
            continue
        fi

        if [[ ! -f "${_filepath}" ]]; then
            log_error "  MISSING: ${_name}"
            _VERIFY_FAIL=true
            continue
        fi

        # Size check
        local _actual_size=""
        _actual_size=$(stat -c '%s' "${_filepath}" 2>/dev/null \
            || stat -f '%z' "${_filepath}" 2>/dev/null \
            || true)
        if [[ -n "${_size_exp}" && -n "${_actual_size}" && "${_actual_size}" != "${_size_exp}" ]]; then
            log_error "  SIZE MISMATCH: ${_name} (expected=${_size_exp}, actual=${_actual_size})"
            _VERIFY_FAIL=true
        else
            log_debug "  size OK: ${_name} (${_actual_size:-?} bytes)"
        fi

        # SHA-256 check - both fields absent is an error, not a warning
        if [[ -z "${_sha256_exp}" ]]; then
            log_error "  NO-CHECKSUM: '${_name}' - entry has neither SHA-256 nor checksum-256 in patches_info.json"
            _VERIFY_FAIL=true
        else
            local _actual_sha256=""
            _actual_sha256="$(_au_sha256sum "${_filepath}")"
            # Case-insensitive comparison (some tools emit uppercase)
            local _exp_lc _act_lc
            _exp_lc="${_sha256_exp,,}"
            _act_lc="${_actual_sha256,,}"
            if [[ "${_act_lc}" != "${_exp_lc}" ]]; then
                log_error "  SHA-256 MISMATCH: ${_name}"
                log_error "    expected: ${_sha256_exp}"
                log_error "    actual:   ${_actual_sha256}"
                _VERIFY_FAIL=true
            else
                log_info "  OK  ${_name}"
            fi
        fi
    done <<< "${_parse_output}"

    # -------------------------------------------------------------------------
    # Check for extra files in the folder not listed in patches_info.json.
    # Include symlinks so they are named rather than silently skipped.
    # -------------------------------------------------------------------------
    log_info "Checking for unlisted files..."
    local _any_unlisted=false
    while IFS= read -r _filepath; do
        local _basename
        _basename="${_filepath##*/}"
        # Skip known extras (metadata, pin file)
        _au_is_known_extra "${_basename}" && continue
        # Skip if it is in the expected list
        local _known=false _en
        for _en in "${_expected_names[@]+"${_expected_names[@]}"}"; do
            [[ "${_en}" == "${_basename}" ]] && _known=true && break
        done
        if [[ "${_known}" == false ]]; then
            log_warn "  UNLISTED: ${_basename} (not in patches_info.json)"
            _any_unlisted=true
        fi
    done < <(find "${_folder}" -maxdepth 1 \( -type f -o -type l \) 2>/dev/null)

    if [[ "${_any_unlisted}" == false ]]; then
        log_info "No unlisted files found."
    fi

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    if [[ "${_VERIFY_FAIL}" == true ]]; then
        log_error "Verification FAILED for ${_folder}"
        return 1
    else
        log_info "Verification PASSED for ${_folder}"
        return 0
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)    show_help ;;
            -V|--version) echo "${SCRIPT_NAME} v0.6.0"; exit 0 ;;
            -v|--verbose) export LOG_LEVEL=2; shift ;;
            -d|--debug)   export LOG_LEVEL=1; shift ;;
            -q|--quiet)   export LOG_LEVEL=4; shift ;;
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

    # Load configuration to resolve AU_DOWNLOAD_FOLDER if no folder given
    if [[ -z "${FOLDER}" ]]; then
        au_load_config
        FOLDER="${AU_DOWNLOAD_FOLDER}"
    fi

    verify_folder "${FOLDER}"
}

main "$@"
# - EOF ------------------------------------------------------------------------
