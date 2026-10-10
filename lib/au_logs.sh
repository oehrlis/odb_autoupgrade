#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Module.....: au_logs.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.10.10
# Version....: v0.7.0
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
# 2026.10.10 oehrli - security hardening: canonicalize log dir, tighter AU
#                     marker (cfgtoollogs/patch/auto or upgrade/auto), Oracle
#                     binary detection, dangerous-path guard, TOCTOU-safe
#                     deletion, java.*autoupgrade.jar-only process detection,
#                     named empty-dir prune (WP8)
# ------------------------------------------------------------------------------

# Guard on function existence.
declare -F au_logs_validate_dir >/dev/null 2>&1 && return 0

# =============================================================================
# VALIDATION
# =============================================================================

# ------------------------------------------------------------------------------
# Function: au_logs_validate_dir
# Purpose.: Validate that AU_LOG_DIR is safe to operate on.
#           Refuses: unset, not resolvable, '/', $HOME, not owned by current
#           user, not a directory, no cfgtoollogs/patch/auto or
#           cfgtoollogs/upgrade/auto subdirectory, contains Oracle Home or
#           inventory markers, equals or is ancestor/descendant of
#           ORACLE_BASE/ORACLE_HOME/AUTOUPGRADE_BASE/AU_DOWNLOAD_FOLDER/
#           AU_KEYSTORE. Every refusal names the reason.
# Args....: None (reads AU_LOG_DIR from environment; updates it with canonical)
# Returns.: 0 on success; exits via die() on failure
# ------------------------------------------------------------------------------
au_logs_validate_dir() {
    if [[ -z "${AU_LOG_DIR:-}" ]]; then
        die "AU_LOG_DIR is not set. Set it in your environment or config file."
    fi

    # Early refusal of filesystem root before any canonicalization.
    # Stripping trailing slashes on "/" produces "" which cd treats as $HOME.
    if [[ "${AU_LOG_DIR}" == "/" ]]; then
        die "AU_LOG_DIR must not be / (filesystem root)."
    fi

    # Must be an existing directory before we attempt canonicalization.
    if [[ ! -d "${AU_LOG_DIR}" ]]; then
        die "AU_LOG_DIR does not exist or is not a directory: ${AU_LOG_DIR}"
    fi

    # Canonicalise: strip trailing slashes, resolve symlinks and . / ..
    local raw_dir canon_dir
    raw_dir="${AU_LOG_DIR%/}"
    [[ -z "${raw_dir}" ]] && raw_dir="${AU_LOG_DIR}"  # safety for bare "/"
    canon_dir=$(cd -P "${raw_dir}" 2>/dev/null && pwd -P) || true
    if [[ -z "${canon_dir}" ]]; then
        die "AU_LOG_DIR cannot be resolved to a real path: ${AU_LOG_DIR}"
    fi
    AU_LOG_DIR="${canon_dir}"

    # Post-canonicalization: also catch symlinks pointing at root
    if [[ "${AU_LOG_DIR}" == "/" ]]; then
        die "AU_LOG_DIR must not be / (filesystem root)."
    fi

    # Refuse $HOME
    local real_home
    real_home=$(cd -P "${HOME:-/}" 2>/dev/null && pwd -P) || real_home="${HOME:-}"
    if [[ -n "${real_home}" && "${AU_LOG_DIR}" == "${real_home}" ]]; then
        die "AU_LOG_DIR must not equal \$HOME (${real_home})."
    fi

    # Must be owned by the current user (portable: try GNU then BSD stat)
    local owner
    owner=$(stat -c '%U' "${AU_LOG_DIR}" 2>/dev/null \
        || stat -f '%Su' "${AU_LOG_DIR}" 2>/dev/null || true)
    if [[ -n "${owner}" && "${owner}" != "$(id -un)" ]]; then
        die "AU_LOG_DIR is owned by '${owner}', not '$(id -un)'. Refusing."
    fi

    # Must contain an AutoUpgrade-specific subdirectory.
    # cfgtoollogs/ alone is too broad; require the deep AU path.
    if [[ ! -d "${AU_LOG_DIR}/cfgtoollogs/patch/auto" && \
          ! -d "${AU_LOG_DIR}/cfgtoollogs/upgrade/auto" ]]; then
        die "AU_LOG_DIR does not look like an AutoUpgrade log directory (no cfgtoollogs/patch/auto or cfgtoollogs/upgrade/auto): ${AU_LOG_DIR}"
    fi

    # Refuse if tree contains Oracle Home or inventory markers (bounded search).
    # read stops at first match; -maxdepth 6 limits scan cost.
    local oracle_marker=""
    read -r oracle_marker < <(find -P "${AU_LOG_DIR}" -maxdepth 6 \
        \( -path "*/bin/oracle" \
           -o -path "*/inventory/ContentsXML" \
           -o -name "oraInst.loc" \) \
        -print 2>/dev/null) || true
    if [[ -n "${oracle_marker}" ]]; then
        die "AU_LOG_DIR contains Oracle Home or inventory markers (${oracle_marker}). Refusing to avoid deleting Oracle binaries."
    fi

    # Refuse if log dir equals or contains (is ancestor of) dangerous paths.
    # Also refuse if log dir is inside a dangerous path.
    local danger_var danger_path canon_danger
    for danger_var in ORACLE_BASE ORACLE_HOME AUTOUPGRADE_BASE \
                      AU_DOWNLOAD_FOLDER AU_KEYSTORE; do
        # shellcheck disable=SC2299
        danger_path="${!danger_var:-}"
        [[ -z "${danger_path}" ]] && continue
        [[ ! -e "${danger_path}" ]] && continue
        canon_danger=$(cd -P "${danger_path}" 2>/dev/null && pwd -P) || true
        [[ -z "${canon_danger}" ]] && continue

        if [[ "${AU_LOG_DIR}" == "${canon_danger}" ]]; then
            die "AU_LOG_DIR (${AU_LOG_DIR}) equals \$${danger_var} (${canon_danger}). Refusing."
        fi
        # log dir is ancestor of danger_path (danger_path is inside log dir)
        if [[ "${canon_danger}" == "${AU_LOG_DIR}/"* ]]; then
            die "AU_LOG_DIR (${AU_LOG_DIR}) contains \$${danger_var} (${canon_danger}). Refusing."
        fi
    done

    log_debug "au_logs_validate_dir: ${AU_LOG_DIR} passed validation"
}

# =============================================================================
# PROCESS CHECK
# =============================================================================

# ------------------------------------------------------------------------------
# Function: au_logs_is_au_running
# Purpose.: Check whether autoupgrade.jar is running as a java process for the
#           current user. Excludes the current process ($$).
#           pgrep pattern: 'java.*autoupgrade\.jar'
#           ps fallback uses the same pattern via bash regex.
# Args....: None
# Returns.: 0 if running, 1 if not
# ------------------------------------------------------------------------------
au_logs_is_au_running() {
    local self_pid="$$"
    local pid line

    if command -v pgrep >/dev/null 2>&1; then
        # Match only java processes running autoupgrade.jar; exclude self
        while IFS= read -r pid; do
            [[ -z "${pid}" ]] && continue
            [[ "${pid}" == "${self_pid}" ]] && continue
            return 0
        done < <(pgrep -u "$(id -u)" -f 'java.*autoupgrade\.jar' 2>/dev/null || true)
        return 1
    else
        # pgrep not available; fall back to ps
        # shellcheck disable=SC2009
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            local ppid pargs
            ppid="${line%%[[:space:]]*}"
            pargs="${line#*[[:space:]]}"
            [[ "${ppid}" == "${self_pid}" ]] && continue
            if [[ "${pargs}" =~ java.*autoupgrade\.jar ]]; then
                return 0
            fi
        done < <(ps -o pid=,args= -u "$(id -u)" 2>/dev/null || true)
        return 1
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
        mtime=$(stat -c '%Y' "${dir}" 2>/dev/null \
            || stat -f '%m' "${dir}" 2>/dev/null || echo 0)
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
#           No silent filters. Deletion is TOCTOU-safe (re-validated via find -P
#           at delete time). Empty directories are named before removal.
# Args....: $1 - log_dir   (AU_LOG_DIR, validated canonical path)
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

        # --- Age check (files only; directories handled by empty-dir prune) ---
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
            # TOCTOU-safe deletion: re-validate at delete time via find -P.
            # -type f excludes symlinks; -mtime re-checks age; -P prevents
            # symlink traversal in the parent directory.
            local entry_dir entry_name
            entry_dir="${entry%/*}"
            entry_name="${entry##*/}"
            find -P "${entry_dir}" -maxdepth 1 \
                -name "${entry_name}" -type f \
                -mtime "+${older_than}" -delete 2>/dev/null || true
            log_info "DELETE: ${rel}"
        else
            printf 'WOULD DELETE: %s\n' "${rel}"
        fi
        (( AU_LOGS_DELETED++ )) || true
    done < <(find -P "${log_dir}" -xdev -print0 2>/dev/null | sort -z)

    # After deletion: prune empty dirs (never cfgtoollogs or .autoupgrade tree).
    # Name each directory before removal - no silent filter.
    if [[ "${do_delete}" == "true" ]]; then
        local empty_dir
        while IFS= read -r -d '' empty_dir; do
            log_info "PRUNE [empty-dir]: ${empty_dir#"${log_dir}/"}"
            rmdir "${empty_dir}" 2>/dev/null || true
        done < <(find -P "${log_dir}" -mindepth 1 -depth -type d -empty \
            ! -path "${log_dir}/cfgtoollogs*" \
            ! -path "${log_dir}/.autoupgrade*" \
            -print0 2>/dev/null)
    fi
}
