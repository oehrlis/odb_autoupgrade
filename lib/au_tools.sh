#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Module.....: au_tools.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.10.09
# Version....: v0.6.0
# Purpose....: JAR manifest helpers, keystore state query, patches_info.json
#              access, log scanning. Provides au_jar_version, au_keystore_state,
#              au_patches_info_ru, au_log_scan.
# Notes......: WP1 scaffolding; au_patches_info_* and full keystore state
#              implemented in WP5/WP6.
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------

# Guard on function existence (au_jar_version is defined in this module).
declare -F au_jar_version >/dev/null 2>&1 && return 0

# ------------------------------------------------------------------------------
# Function: au_jar_version
# Purpose.: Extract Implementation-Version from the AutoUpgrade JAR manifest
# Args....: $1 - path to autoupgrade.jar
# Returns.: 0 on success; prints version string to stdout; empty on failure
# Notes...: Requires unzip on PATH; silently returns empty if unavailable.
#           WP5 extends this with a version-compare and downgrade guard.
# ------------------------------------------------------------------------------
au_jar_version() {
    local jar="$1"
    local ver=""
    if [[ -f "${jar}" ]] && command -v unzip >/dev/null 2>&1; then
        ver=$(unzip -p "${jar}" META-INF/MANIFEST.MF 2>/dev/null \
            | grep -i -m1 'Implementation-Version') || true
        ver="${ver#*:}"
        ver="${ver//[[:space:]]/}"
    fi
    printf '%s' "${ver:-}"
}

# ------------------------------------------------------------------------------
# Function: au_keystore_state
# Purpose.: Return a one-word state for the AutoUpgrade patching keystore
# Args....: $1 - keystore directory
# Returns.: 0; prints one of: OK MISSING UNREADABLE INSECURE UNKNOWN to stdout
# Notes...: Full key-pair check (PKEY1/PKEY2) implemented in WP6.
#           Current check: directory + wallet files existence + permissions.
# ------------------------------------------------------------------------------
au_keystore_state() {
    local ks_dir="$1"
    if [[ ! -d "${ks_dir}" ]]; then
        echo "MISSING"
        return 0
    fi
    local f
    for f in ewallet.p12 cwallet.sso; do
        if [[ ! -f "${ks_dir}/${f}" ]]; then
            echo "MISSING"
            return 0
        fi
        if [[ ! -r "${ks_dir}/${f}" ]]; then
            echo "UNREADABLE"
            return 0
        fi
    done
    echo "OK"
}

# ------------------------------------------------------------------------------
# Function: au_log_scan
# Purpose.: Print VDGI_* and GOLD_IMAGE= lines from autoupgrade_patching.log
# Args....: $1 - global_log_dir (AU_LOG_DIR)
#           $2 - mode (only runs for "download")
# Returns.: 0; prints matching lines to stderr via log_info
# Notes...: Called by au_run.sh after a -mode download run.
#           Prints a named WARN if the log is not found (no silent skip).
# ------------------------------------------------------------------------------
au_log_scan() {
    local log_dir="${1:-}"
    local mode="${2:-}"

    [[ "${mode}" != "download" ]] && return 0

    local logfile="${log_dir}/cfgtoollogs/patch/auto/autoupgrade_patching.log"
    if [[ ! -f "${logfile}" ]]; then
        log_warn "Post-download VDGI scan: log not found at ${logfile} (run with a real jar to populate)"
        return 0
    fi

    local _vdgi_count=0
    local _line
    while IFS= read -r _line; do
        log_info "  post-download: ${_line}"
        _vdgi_count=$(( _vdgi_count + 1 ))
    done < <(grep -E '(VDGI_|GOLD_IMAGE=)' "${logfile}" 2>/dev/null | tail -20 || true)

    if [[ "${_vdgi_count}" -eq 0 ]]; then
        log_info "Post-download: no VDGI_* or GOLD_IMAGE= lines found in ${logfile}"
    else
        log_info "Post-download: ${_vdgi_count} VDGI/gold-image line(s) found in ${logfile}"
    fi
}
