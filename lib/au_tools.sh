#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Module.....: au_tools.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Editor.....: Stefan Oehrli
# Date.......: 2026.10.09
# Version....: v0.6.0
# Purpose....: JAR manifest helpers, keystore state/check/backup, patches_info
#              access, log scanning, SHA-256 and file stat helpers.
#              Provides: au_jar_version, au_jar_version_numeric, au_version_compare,
#              au_sha256, au_file_size, au_file_owner_uid, au_file_perms,
#              au_keystore_state, au_keystore_check, au_keystore_backup,
#              au_prune_backups, au_patches_info_ru, au_log_scan.
# Notes......: WP5/WP6 extended au_jar_version with version compare helpers
#              and added full au_keystore_check/au_keystore_backup.
#              au_keystore_state is retained for au_check_connectivity.sh.
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.09 oehrli - WP1 scaffolding: au_jar_version, au_keystore_state,
#                     au_patches_info_ru, au_log_scan
# 2026.10.09 oehrli - WP5/WP6: au_jar_version_numeric, au_version_compare,
#                     au_sha256, au_file_size, au_file_owner_uid, au_file_perms,
#                     au_keystore_check, au_keystore_backup, au_prune_backups
# ------------------------------------------------------------------------------

# Guard on function existence (au_jar_version is defined in this module).
declare -F au_jar_version >/dev/null 2>&1 && return 0

# ------------------------------------------------------------------------------
# Function: au_jar_version
# Purpose.: Extract Implementation-Version from the AutoUpgrade JAR manifest.
# Args....: $1 - path to autoupgrade.jar
# Stdout..: version string (e.g. "26.6.260925"), or empty string on failure
# Returns.: 0 on success (version printed), 1 if JAR not readable or absent
# Notes...: Requires unzip on PATH; silently returns empty if unavailable.
# ------------------------------------------------------------------------------
au_jar_version() {
    local jar="$1"
    local ver manifest_line
    [[ -f "${jar}" ]] || return 1
    if ! command -v unzip >/dev/null 2>&1; then return 1; fi
    manifest_line="$(unzip -p "${jar}" META-INF/MANIFEST.MF 2>/dev/null \
        | grep -i -m1 'Implementation-Version:' || true)"
    ver="${manifest_line#*:}"
    # Strip whitespace and carriage returns using bash built-ins
    ver="${ver#"${ver%%[![:space:]]*}"}"
    ver="${ver%"${ver##*[![:space:]]}"}"
    ver="${ver%$'\r'}"
    [[ -n "${ver}" ]] || return 1
    printf '%s\n' "${ver}"
}

# ------------------------------------------------------------------------------
# Function: au_jar_version_numeric
# Purpose.: Convert dotted version string to three space-separated integers.
#           "26.6.260925" -> "26 6 260925"
# Args....: $1 - version string from au_jar_version
# Stdout..: three space-separated integers
# Returns.: 0
# ------------------------------------------------------------------------------
au_jar_version_numeric() {
    local v="$1"
    local major minor build rest
    major="${v%%.*}"; rest="${v#*.}"
    minor="${rest%%.*}"; build="${rest#*.}"
    [[ "${build}" == "${minor}" ]] && build=0   # only two tokens
    printf '%s %s %s\n' "${major}" "${minor}" "${build}"
}

# ------------------------------------------------------------------------------
# Function: au_version_compare
# Purpose.: Compare two dotted version strings.
# Args....: $1 - version A, $2 - version B
# Returns.: 0 if A == B, 1 if A > B, 2 if A < B
# ------------------------------------------------------------------------------
au_version_compare() {
    local -a a b
    read -r -a a <<< "$(au_jar_version_numeric "$1")"
    read -r -a b <<< "$(au_jar_version_numeric "$2")"
    local i
    for i in 0 1 2; do
        local av="${a[$i]:-0}" bv="${b[$i]:-0}"
        if (( av > bv )); then return 1; fi
        if (( av < bv )); then return 2; fi
    done
    return 0
}

# ------------------------------------------------------------------------------
# Function: au_sha256
# Purpose.: Print SHA-256 hash of a file (hash only, no filename).
# Args....: $1 - file path
# Stdout..: 64-char hex string
# Returns.: 0 on success, 1 if no sha tool found
# ------------------------------------------------------------------------------
au_sha256() {
    local file="$1" out
    if command -v sha256sum >/dev/null 2>&1; then
        out="$(sha256sum "${file}")"
        printf '%s\n' "${out%% *}"
    elif command -v shasum >/dev/null 2>&1; then
        out="$(shasum -a 256 "${file}")"
        printf '%s\n' "${out%% *}"
    else
        log_warn "sha256sum / shasum not found; skipping checksum."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Function: au_file_size
# Purpose.: Portable file size in bytes (GNU stat -c / BSD stat -f).
# Args....: $1 - file path
# Stdout..: size in bytes (0 if stat unavailable)
# Returns.: 0
# ------------------------------------------------------------------------------
au_file_size() {
    local file="$1" size
    size="$(stat -c '%s' "${file}" 2>/dev/null)" \
        || size="$(stat -f '%z' "${file}" 2>/dev/null)" \
        || size=0
    printf '%s\n' "${size}"
}

# ------------------------------------------------------------------------------
# Function: au_file_owner_uid
# Purpose.: Portable file owner UID (GNU stat -c / BSD stat -f).
# Args....: $1 - file path
# Stdout..: UID number, or empty string on failure
# Returns.: 0
# ------------------------------------------------------------------------------
au_file_owner_uid() {
    local file="$1" uid
    uid="$(stat -c '%u' "${file}" 2>/dev/null)" \
        || uid="$(stat -f '%u' "${file}" 2>/dev/null)" \
        || uid=""
    printf '%s\n' "${uid}"
}

# ------------------------------------------------------------------------------
# Function: au_file_perms
# Purpose.: Portable file permission bits in octal (GNU stat -c / BSD stat -f).
# Args....: $1 - file path
# Stdout..: e.g. "600", "700", or empty string on failure
# Returns.: 0
# ------------------------------------------------------------------------------
au_file_perms() {
    local file="$1" perms
    perms="$(stat -c '%a' "${file}" 2>/dev/null)" \
        || perms="$(stat -f '%Lp' "${file}" 2>/dev/null)" \
        || perms=""
    printf '%s\n' "${perms}"
}

# ------------------------------------------------------------------------------
# Function: au_keystore_state
# Purpose.: Return a one-word state for the AutoUpgrade patching keystore.
# Args....: $1 - keystore directory
# Stdout..: one of: OK MISSING UNREADABLE INSECURE UNKNOWN
# Returns.: 0 always (state printed to stdout)
# Notes...: Used by au_check_connectivity.sh. Full check: au_keystore_check.
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
# Function: au_keystore_check
# Purpose.: Non-interactive permission/owner/symlink/key-pair check.
#           Used by au_keystore.sh --check and the connectivity check.
# Args....: $1 - keystore directory path
#           $2 - (optional) installed JAR path for age comparison
# Globals.: MKSTORE_TIMEOUT (default 15 s)
# Returns.: 0 all checks pass, 1 one or more failures
# Notes...: Key pair check (PKEY1/PKEY2 via mkstore) is best-effort (WARN).
#           Age check (keystore mtime vs JAR build date) is WARN only.
# ------------------------------------------------------------------------------
au_keystore_check() {
    local ks_dir="$1"
    local jar_file="${2:-}"
    local rc=0
    local ewallet cwallet perms uid

    # --- Directory ---
    if [[ ! -d "${ks_dir}" ]]; then
        log_error "Keystore directory not found: ${ks_dir}"
        return 1
    fi
    if [[ -L "${ks_dir}" ]]; then
        log_error "Keystore directory is a symlink: ${ks_dir}"
        rc=1
    fi
    perms="$(au_file_perms "${ks_dir}")"
    if [[ "${perms}" != "700" ]]; then
        log_warn "Keystore directory permissions are ${perms} (expected 700): ${ks_dir}"
        rc=1
    fi
    uid="$(au_file_owner_uid "${ks_dir}")"
    if [[ -n "${uid}" && "${uid}" != "$(id -u)" ]]; then
        log_warn "Keystore directory owner UID=${uid} != current user $(id -u): ${ks_dir}"
        rc=1
    fi

    # --- Wallet files ---
    ewallet="${ks_dir}/ewallet.p12"
    cwallet="${ks_dir}/cwallet.sso"

    if [[ -L "${ewallet}" ]]; then
        log_error "ewallet.p12 is a symlink: ${ewallet}"; rc=1
    elif [[ ! -f "${ewallet}" ]]; then
        log_error "ewallet.p12 not found: ${ewallet}"; rc=1
    else
        perms="$(au_file_perms "${ewallet}")"
        if [[ "${perms}" != "600" ]]; then
            log_warn "ewallet.p12 permissions are ${perms} (expected 600): ${ewallet}"; rc=1
        fi
        uid="$(au_file_owner_uid "${ewallet}")"
        if [[ -n "${uid}" && "${uid}" != "$(id -u)" ]]; then
            log_warn "ewallet.p12 owner UID=${uid} != current user $(id -u)"; rc=1
        fi
    fi

    if [[ -L "${cwallet}" ]]; then
        log_error "cwallet.sso is a symlink: ${cwallet}"; rc=1
    elif [[ ! -f "${cwallet}" ]]; then
        log_warn "cwallet.sso not found (auto-login disabled?): ${cwallet}"
    else
        perms="$(au_file_perms "${cwallet}")"
        if [[ "${perms}" != "600" ]]; then
            log_warn "cwallet.sso permissions are ${perms} (expected 600): ${cwallet}"; rc=1
        fi
        uid="$(au_file_owner_uid "${cwallet}")"
        if [[ -n "${uid}" && "${uid}" != "$(id -u)" ]]; then
            log_warn "cwallet.sso owner UID=${uid} != current user $(id -u)"; rc=1
        fi
    fi

    # --- .autoupgrade subdir ---
    local autoupgrade_sub="${ks_dir}/.autoupgrade"
    if [[ -d "${autoupgrade_sub}" ]]; then
        perms="$(au_file_perms "${autoupgrade_sub}")"
        local g_bit w_bit
        g_bit="${perms: -2:1}"
        w_bit="${perms: -1:1}"
        if [[ "${g_bit}" =~ [2367] || "${w_bit}" =~ [2367] ]]; then
            log_error ".autoupgrade subdir is group/world-writable (${perms}): ${autoupgrade_sub}"
            rc=1
        fi
    fi

    # --- Key pair (best effort via mkstore) ---
    local mkstore_timeout="${MKSTORE_TIMEOUT:-15}"
    if command -v mkstore >/dev/null 2>&1 && [[ -f "${ewallet}" ]]; then
        local mkstore_out
        mkstore_out="$(timeout "${mkstore_timeout}" mkstore -wrl "${ks_dir}" -list 2>/dev/null || true)"
        if [[ "${mkstore_out}" == *"PKEY1"* && "${mkstore_out}" == *"PKEY2"* ]]; then
            log_info "Key pair PKEY1/PKEY2 present in keystore."
        else
            log_warn "Key pair PKEY1/PKEY2 not confirmed (mkstore -list). Re-save: au_keystore.sh --resave"
        fi
    else
        log_warn "mkstore not available; PKEY1/PKEY2 unverified. Manual check: group mos -> list"
    fi

    # --- Age vs JAR build date ---
    if [[ -n "${jar_file}" && -f "${jar_file}" && -f "${ewallet}" ]]; then
        local jar_version jar_build_date ks_mtime
        jar_version="$(au_jar_version "${jar_file}" 2>/dev/null || true)"
        if [[ "${jar_version}" =~ ^[0-9]+\.[0-9]+\.([0-9]{6})$ ]]; then
            jar_build_date="${BASH_REMATCH[1]}"
            ks_mtime="$(date -r "${ewallet}" '+%y%m%d' 2>/dev/null || true)"
            if [[ -n "${ks_mtime}" && -n "${jar_build_date}" ]] \
                && (( ks_mtime < jar_build_date )); then
                log_warn "Keystore predates JAR build ${jar_build_date} (mtime ${ks_mtime}). Re-save: au_keystore.sh --resave"
            fi
        fi
    fi

    return "${rc}"
}

# ------------------------------------------------------------------------------
# Function: au_keystore_backup
# Purpose.: Create a 0600 tar.gz backup of the keystore directory in a 0700
#           backup directory outside logs/ and patches/.
# Args....: $1 - keystore directory path
#           $2 - (optional) backup root (default: <parent>/<name>_backup)
# Stdout..: path to created backup file
# Returns.: 0 on success, non-zero on failure
# ------------------------------------------------------------------------------
au_keystore_backup() {
    local ks_dir="$1"
    local backup_root="${2:-}"
    local ks_name ks_parent timestamp backup_file

    ks_name="${ks_dir##*/}"
    ks_parent="${ks_dir%/*}"
    [[ -z "${backup_root}" ]] && backup_root="${ks_parent}/${ks_name}_backup"

    umask 077
    if [[ ! -d "${backup_root}" ]]; then
        mkdir -p "${backup_root}" || { log_error "Cannot create backup dir: ${backup_root}"; return 1; }
        chmod 700 "${backup_root}"
    else
        chmod 700 "${backup_root}"
    fi

    timestamp="$(date '+%Y%m%d_%H%M%S')"
    backup_file="${backup_root}/${ks_name}_${timestamp}.tar.gz"

    tar -czf "${backup_file}" -C "${ks_parent}" "${ks_name}" 2>/dev/null \
        || { log_error "Backup creation failed: ${backup_file}"; return 1; }
    chmod 600 "${backup_file}"
    printf '%s\n' "${backup_file}"
}

# ------------------------------------------------------------------------------
# Function: au_prune_backups
# Purpose.: Keep only the N most recent backup *.tar.gz files by mtime.
# Args....: $1 - backup directory path
#           $2 - N (keep count; 0 = keep all)
# Returns.: 0
# ------------------------------------------------------------------------------
au_prune_backups() {
    local backup_dir="$1"
    local keep="${2:-3}"
    [[ "${keep}" -le 0 ]] && return 0
    [[ -d "${backup_dir}" ]] || return 0

    local count=0 file
    # shellcheck disable=SC2012
    while IFS= read -r file; do
        count=$(( count + 1 ))
    done < <(ls -1t "${backup_dir}"/*.tar.gz 2>/dev/null || true)

    local to_remove=$(( count - keep ))
    if (( to_remove <= 0 )); then return 0; fi

    local removed=0
    # shellcheck disable=SC2012
    while IFS= read -r file; do
        if (( removed < to_remove )); then
            rm -f "${file}"
            removed=$(( removed + 1 ))
        fi
    done < <(ls -1t "${backup_dir}"/*.tar.gz 2>/dev/null | tail -n "${to_remove}" || true)
}

# ------------------------------------------------------------------------------
# Function: au_patches_info_ru
# Purpose.: Extract the recommended RU number from patches_info.json
# Args....: $1 - download folder (AU_DOWNLOAD_FOLDER)
# Stdout..: RU string, e.g. "19.27"
# Returns.: 0 on success, 1 if file absent or field not found
# Notes...: WP7 implements the full version; this is the WP1 stub.
# ------------------------------------------------------------------------------
au_patches_info_ru() {
    local dl_folder="${1:-}"
    local info_file="${dl_folder}/patches_info.json"
    [[ -f "${info_file}" ]] || return 1
    grep -m1 '"ru_version"' "${info_file}" 2>/dev/null \
        | grep -oE '"[0-9]+\.[0-9]+"' \
        | tr -d '"' \
        || return 1
}

# ------------------------------------------------------------------------------
# Function: au_log_scan
# Purpose.: Print VDGI_* and GOLD_IMAGE= lines from autoupgrade_patching.log.
# Args....: $1 - global_log_dir (AU_LOG_DIR)
#           $2 - mode (only runs for "download")
# Returns.: 0; named WARN if log not found (no silent skip).
# Notes...: Called by au_run.sh after a -mode download run.
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
