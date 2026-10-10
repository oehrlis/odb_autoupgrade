#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Module.....: au_logs.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.10.09
# Version....: v0.6.0
# Purpose....: Log-cleanup helper functions for AutoUpgrade wrapper scripts.
#              Provides: au_logs_validate_dir, au_logs_is_au_running,
#              au_logs_in_keep_set, au_logs_sorted_job_dirs, au_logs_do_cleanup.
# Notes......: Requires common.sh (log_*, die) to be sourced first.
#              Sourced by bin/au_log_cleanup.sh after lib/au_lib.sh.
# Reference..: https://github.com/oehrlis/odb_autoupgrade
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.09 oehrli - initial version (WP8)
# ------------------------------------------------------------------------------

# Guard on function existence.
declare -F au_logs_validate_dir >/dev/null 2>&1 && return 0

# =============================================================================
# VALIDATION
# =============================================================================

# ------------------------------------------------------------------------------
# Function: au_logs_validate_dir
# Purpose.: Validate that AU_LOG_DIR is safe to operate on.
#           Refuses: unset, '/', $HOME, not owned by current user,
#           not a directory, no cfgtoollogs/ subdirectory or .ap_build.
# Args....: None (reads AU_LOG_DIR from environment)
# Returns.: 0 on success; exits via die() on failure
# ------------------------------------------------------------------------------
au_logs_validate_dir() {
    if [[ -z "${AU_LOG_DIR:-}" ]]; then
        die "AU_LOG_DIR is not set. Set it in your environment or config file."
    fi

    # Refuse dangerous roots
    if [[ "${AU_LOG_DIR}" == "/" ]]; then
        die "AU_LOG_DIR must not be / (filesystem root)."
    fi

    local real_home="${HOME:-}"
    if [[ -n "${real_home}" && "${AU_LOG_DIR}" == "${real_home}" ]]; then
        die "AU_LOG_DIR must not equal \$HOME (${real_home})."
    fi

    # Must be an existing directory
    if [[ ! -d "${AU_LOG_DIR}" ]]; then
        die "AU_LOG_DIR does not exist or is not a directory: ${AU_LOG_DIR}"
    fi

    # Must be owned by the current user (portable: try GNU then BSD stat)
    local owner
    owner=$(stat -c '%U' "${AU_LOG_DIR}" 2>/dev/null || stat -f '%Su' "${AU_LOG_DIR}" 2>/dev/null || true)
    if [[ -n "${owner}" && "${owner}" != "$(id -un)" ]]; then
        die "AU_LOG_DIR is owned by '${owner}', not '$(id -un)'. Refusing."
    fi

    # Must look like an AutoUpgrade log dir
    if [[ ! -d "${AU_LOG_DIR}/cfgtoollogs" && ! -e "${AU_LOG_DIR}/.ap_build" ]]; then
        die "AU_LOG_DIR does not look like an AutoUpgrade log directory (no cfgtoollogs/ or .ap_build): ${AU_LOG_DIR}"
    fi

    log_debug "au_logs_validate_dir: ${AU_LOG_DIR} passed validation"
}

# =============================================================================
# PROCESS CHECK
# =============================================================================

# ------------------------------------------------------------------------------
# Function: au_logs_is_au_running
# Purpose.: Check whether autoupgrade is currently running for the current user.
# Args....: None
# Returns.: 0 if running, 1 if not
# ------------------------------------------------------------------------------
au_logs_is_au_running() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -u "$(id -u)" -f "autoupgrade" >/dev/null 2>&1
    else
        # pgrep not available; fall back to ps - SC2009 suppressed intentionally
        # shellcheck disable=SC2009
        ps -u "$(id -u)" -f 2>/dev/null | grep -q "[a]utoupgrade"
    fi
}

# =============================================================================
# KEEP-SET
# =============================================================================

# ------------------------------------------------------------------------------
# Function: au_logs_in_keep_set
# Purpose.: Return 0 (true) if the given relative path belongs to the keep-set.
#           Keep-set: request_id_cache.json, aru/*.csd, .ap_build, lock/ subtree.
# Args....: $1 - path relative to AU_LOG_DIR (no leading slash)
# Returns.: 0 if in keep-set, 1 otherwise
# ------------------------------------------------------------------------------
au_logs_in_keep_set() {
    local rel="$1"

    case "${rel}" in
        # Always keep: request_id_cache and its parent dirs
        cfgtoollogs/patch/auto/aru/request_id_cache.json) return 0 ;;
        # Always keep: aru/*.csd checksum files
        cfgtoollogs/patch/auto/aru/*.csd) return 0 ;;
        # Always keep: lock/ subtree (never touch while AU may run)
        cfgtoollogs/patch/auto/lock | cfgtoollogs/patch/auto/lock/*) return 0 ;;
        # Always keep: .ap_build marker
        .ap_build) return 0 ;;
    esac

    return 1
}

# =============================================================================
# JOB DIRECTORY DISCOVERY
# =============================================================================

# ------------------------------------------------------------------------------
# Function: au_logs_sorted_job_dirs
# Purpose.: Output absolute paths of job directories under AU_LOG_DIR, sorted
#           newest first (by mtime). A job dir is a direct subdirectory that
#           contains status.json or progress.json, excluding cfgtoollogs/ and
#           hidden directories.
# Args....: $1 - log_dir (AU_LOG_DIR)
# Returns.: 0; one absolute path per line (newest first) to stdout
# ------------------------------------------------------------------------------
au_logs_sorted_job_dirs() {
    local log_dir="$1"
    local dir mtime base

    # Collect: mtime<TAB>path, then sort descending, then strip mtime
    while IFS= read -r -d '' dir; do
        base="${dir##*/}"
        # Skip cfgtoollogs and hidden dirs
        case "${base}" in
            cfgtoollogs | .*) continue ;;
        esac
        # Must have a job marker
        if [[ ! -f "${dir}/status.json" && ! -f "${dir}/progress.json" ]]; then
            continue
        fi
        mtime=$(stat -c '%Y' "${dir}" 2>/dev/null || stat -f '%m' "${dir}" 2>/dev/null || echo 0)
        printf '%s\t%s\n' "${mtime}" "${dir}"
    done < <(find "${log_dir}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null) \
        | sort -rn | while IFS=$'\t' read -r _ path; do printf '%s\n' "${path}"; done
}

# =============================================================================
# MAIN CLEANUP ENGINE
# =============================================================================

# ------------------------------------------------------------------------------
# Function: au_logs_do_cleanup
# Purpose.: List or delete files from AU_LOG_DIR per the cleanup rules.
#           Every file is accounted for: KEEP (with reason) or DELETE.
#           No silent filters.
# Args....: $1 - log_dir   (AU_LOG_DIR, validated)
#           $2 - older_than (days, files newer than this are kept)
#           $3 - keep_jobs  (N newest job dirs to preserve)
#           $4 - do_delete  ("true" = delete; "false" = list only)
# Returns.: 0 on success; sets globals:
#           AU_LOGS_DELETED  (count of deleted/would-delete files)
#           AU_LOGS_KEPT     (count of kept files)
#           AU_LOGS_SKIPPED  (count of skipped/warned entries)
# ------------------------------------------------------------------------------
au_logs_do_cleanup() {
    local log_dir="$1"
    local older_than="$2"
    local keep_jobs="$3"
    local do_delete="$4"

    AU_LOGS_DELETED=0
    AU_LOGS_KEPT=0
    AU_LOGS_SKIPPED=0

    # Build the set of job dirs to keep (newest N)
    local -a keep_job_dirs=()
    local idx=0
    while IFS= read -r dir; do
        if [[ ${idx} -lt ${keep_jobs} ]]; then
            keep_job_dirs+=("${dir}")
        fi
        (( idx++ )) || true
    done < <(au_logs_sorted_job_dirs "${log_dir}")

    log_debug "au_logs_do_cleanup: keeping ${#keep_job_dirs[@]} job dirs"

    # Walk all entries under log_dir; -P: no symlink follow; -xdev: stay on fs
    local entry rel in_keep_job kd is_old
    while IFS= read -r -d '' entry; do
        # Skip the root itself
        [[ "${entry}" == "${log_dir}" ]] && continue

        rel="${entry#"${log_dir}/"}"

        # --- Symlink safety: refuse symlinks escaping the log dir ---
        if [[ -L "${entry}" ]]; then
            local link_target norm_target
            link_target=$(readlink "${entry}")
            if [[ "${link_target}" != /* ]]; then
                link_target="${entry%/*}/${link_target}"
            fi
            norm_target=$(cd -P "$(dirname "${link_target}" 2>/dev/null)" 2>/dev/null \
                && pwd || true)
            if [[ -z "${norm_target}" ]] || [[ "${norm_target}/" != "${log_dir}/"* ]]; then
                log_warn "SKIP (symlink escapes log dir): ${rel} -> $(readlink "${entry}")"
                (( AU_LOGS_SKIPPED++ )) || true
                continue
            fi
        fi

        # --- Keep-set check ---
        if au_logs_in_keep_set "${rel}"; then
            log_info "KEEP [keep-set]: ${rel}"
            (( AU_LOGS_KEPT++ )) || true
            continue
        fi

        # --- Job-dir keep check ---
        in_keep_job=false
        for kd in "${keep_job_dirs[@]+"${keep_job_dirs[@]}"}"; do
            if [[ "${entry}" == "${kd}" || "${entry}" == "${kd}/"* ]]; then
                in_keep_job=true
                break
            fi
        done
        if [[ "${in_keep_job}" == "true" ]]; then
            log_info "KEEP [keep-jobs]: ${rel}"
            (( AU_LOGS_KEPT++ )) || true
            continue
        fi

        # --- Age check (files only; directories are handled by empty-dir prune) ---
        if [[ ! -f "${entry}" ]]; then
            continue
        fi

        is_old=false
        if [[ -n "$(find "${entry}" -maxdepth 0 -mtime "+${older_than}" 2>/dev/null)" ]]; then
            is_old=true
        fi

        if [[ "${is_old}" == "false" ]]; then
            log_info "KEEP [recent (<= ${older_than}d)]: ${rel}"
            (( AU_LOGS_KEPT++ )) || true
            continue
        fi

        # --- Delete or list ---
        if [[ "${do_delete}" == "true" ]]; then
            rm -f "${entry}"
            log_info "DELETE: ${rel}"
        else
            printf 'WOULD DELETE: %s\n' "${rel}"
        fi
        (( AU_LOGS_DELETED++ )) || true
    done < <(find -P "${log_dir}" -xdev -print0 2>/dev/null | sort -z)

    # After deletion: prune empty dirs (never cfgtoollogs or .autoupgrade tree)
    if [[ "${do_delete}" == "true" ]]; then
        find -P "${log_dir}" -mindepth 1 -depth -type d -empty \
            ! -path "${log_dir}/cfgtoollogs*" \
            ! -path "${log_dir}/.autoupgrade*" \
            -delete 2>/dev/null || true
    fi
}
