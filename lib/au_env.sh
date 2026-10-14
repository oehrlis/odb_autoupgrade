#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Module.....: au_env.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.10.09
# Version....: v0.6.2
# Purpose....: Configuration precedence , defaults, config rendering ,
#              pin file parsing, env file loading with security checks.
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------

# Guard on function existence, not an inheritable variable.
# A caller cannot bypass the bash 4.2 check in common.sh by pre-setting AU_ENV_SH_LOADED.
declare -F au_load_config >/dev/null 2>&1 && return 0

# Global array populated by au_check_cfg_vars; consumed by au_render_cfg.
AU_CFG_VARS=()

# Module-level: resolved real path set by _au_check_file_security, read by callers.
_AU_REAL_PATH=""
# Module-level: open file descriptor set by _au_check_file_security for TOCTOU fix.
_AU_REAL_FD=""
# Module-level: temp files registered for EXIT cleanup (Fix 5).
_AU_TMPFILES=()

# ------------------------------------------------------------------------------
# Function: _au_purge_tmpfiles
# Purpose.: Remove all temp files registered in _AU_TMPFILES (EXIT cleanup).
# Notes...: Called via EXIT trap; safe to call multiple times.
# ------------------------------------------------------------------------------
_au_purge_tmpfiles() {
    local _f
    for _f in "${_AU_TMPFILES[@]+"${_AU_TMPFILES[@]}"}"; do
        rm -f "${_f}" 2>/dev/null || true
    done
    _AU_TMPFILES=()
}

# Register EXIT cleanup for temp files. Chain with any existing EXIT trap to
# avoid overriding traps set by the calling script (setup_error_handling etc.).
# shellcheck disable=SC2064
_au_prev_exit=$(trap -p EXIT 2>/dev/null | sed "s/^trap -- '//;s/' EXIT\$//") || true
if [[ -z "${_au_prev_exit}" ]]; then
    trap '_au_purge_tmpfiles' EXIT
elif [[ "${_au_prev_exit}" != *"_au_purge_tmpfiles"* ]]; then
    # SC2064 intentional: expand _au_prev_exit NOW to capture current handler
    # shellcheck disable=SC2064
    trap "${_au_prev_exit}; _au_purge_tmpfiles" EXIT
fi
unset _au_prev_exit

# =============================================================================
# Internal security helpers
# =============================================================================

# ------------------------------------------------------------------------------
# Function: _au_resolve_realpath
# Purpose.: Portable symlink chain resolution (no GNU readlink -f, no realpath).
#           Follows one hop at a time with readlink, then canonicalises the
#           directory via cd -P / pwd -P.
# Args....: $1 - path to resolve
# Returns.: 0; prints resolved absolute path to stdout
#           1 on symlink loop (>40 hops) or unreachable target
# ------------------------------------------------------------------------------
_au_resolve_realpath() {
    local _cur="$1"
    local _i=0 _max=40 _target _dir _base

    while [[ "${_i}" -lt "${_max}" ]]; do
        [[ -L "${_cur}" ]] || break
        _target=$(readlink "${_cur}")   # one hop (portable BSD + GNU)
        if [[ "${_target}" == /* ]]; then
            _cur="${_target}"
        else
            _dir="${_cur%/*}"
            [[ "${_dir}" == "${_cur}" || -z "${_dir}" ]] && _dir="."
            _cur="${_dir}/${_target}"
        fi
        _i=$(( _i + 1 ))
    done
    [[ "${_i}" -ge "${_max}" ]] && return 1

    # Canonicalise via cd -P (resolves .., multiple slashes, and physical path)
    if [[ -d "${_cur}" ]]; then
        ( cd -P "${_cur}" 2>/dev/null && pwd -P ) || return 1
    else
        _dir="${_cur%/*}"
        [[ "${_dir}" == "${_cur}" || -z "${_dir}" ]] && _dir="."
        _base="${_cur##*/}"
        local _abs
        _abs=$( cd -P "${_dir}" 2>/dev/null && pwd -P ) || return 1
        printf '%s/%s\n' "${_abs}" "${_base}"
    fi
}

# ------------------------------------------------------------------------------
# Function: _au_check_parent_dir
# Purpose.: Check the direct parent directory of a file path. Refuses if it
#           is group/world-writable without the sticky+ownership exemption.
# Args....: $1 - file path whose parent to check
#           $2 - label for error messages
#           $3 - current user's numeric uid
# Returns.: 0 if the parent dir is safe; exits via die on violation
# Notes...: Sticky bit exemption: sticky dir owned by current user or root -> ok.
#           Only the immediate containing directory is checked (not all ancestors).
#           This prevents symlink/file injection via a group-writable directory
#           without requiring the entire path to root to be restricted.
# ------------------------------------------------------------------------------
_au_check_parent_dir() {
    local _path="$1" _label="$2" _cur_uid="$3"
    local _dir

    _dir="${_path%/*}"
    [[ "${_dir}" == "${_path}" || -z "${_dir}" ]] && _dir="."
    [[ -d "${_dir}" ]] || return 0   # no dir to check

    # ownership check applies to ALL (sticky or not) parent dirs
    local _dir_uid=""
    _dir_uid=$(stat -c '%u' "${_dir}" 2>/dev/null \
        || stat -f '%u' "${_dir}" 2>/dev/null \
        || true)

    local _writable=""
    _writable=$(find "${_dir}" -maxdepth 0 \( -perm -g+w -o -perm -o+w \) 2>/dev/null || true)

    if [[ -z "${_writable}" ]]; then
        # Not group/world-writable: still verify ownership (Fix 2)
        if [[ -n "${_dir_uid}" && "${_dir_uid}" != "0" && "${_dir_uid}" != "${_cur_uid}" ]]; then
            die "${_label}: directory '${_dir}' is owned by uid ${_dir_uid} (not root=0 or current=${_cur_uid}), refusing - fix: chown root or ${_cur_uid} '${_dir}'"
        fi
        return 0
    fi

    # Group/world-writable: check sticky bit exemption
    local _sticky=""
    _sticky=$(find "${_dir}" -maxdepth 0 -perm -1000 2>/dev/null || true)
    if [[ -n "${_sticky}" ]]; then
        # Sticky + owned by user or root -> ok (e.g. /tmp on Linux/macOS)
        if [[ "${_dir_uid}" == "0" || "${_dir_uid}" == "${_cur_uid}" ]]; then
            return 0
        fi
        die "${_label}: directory '${_dir}' has sticky bit but is owned by uid ${_dir_uid} (not root=0 or current=${_cur_uid}), refusing"
    fi

    die "${_label}: directory '${_dir}' containing file is group/world-writable (no sticky bit), refusing - fix: chmod go-w '${_dir}'"
}

# ------------------------------------------------------------------------------
# Function: _au_check_file_security
# Purpose.: Apply Decision-5 security checks before sourcing a file.
#           resolves symlink chains portably; checks original, every
#           intermediate hop, and final resolved path (Fix 3).
#           numeric UIDs; fail closed if stat/id returns empty.
#           TOCTOU (Fix 1): opens the file AFTER path checks, then re-verifies
#           owner and mode via stat -L on the open fd (/dev/fd/N). Caller MUST
#           source /dev/fd/${_AU_REAL_FD} and close it with `exec {_AU_REAL_FD}<&-`.
#           Sets _AU_REAL_PATH and _AU_REAL_FD on success.
# Args....: $1 - file path
#           $2 - label (for messages, e.g. "level-5")
# Returns.: 0 if file passes all checks; exits via die on violation
# Notes...: owner = current user OR root (numeric uid);
#           symlinks resolved + target checked; not g/o-writable; fatal.
#           Remaining assumption: directory ancestors ABOVE the direct parent
#           of each path in the chain are trusted (not walked).
# ------------------------------------------------------------------------------
_au_check_file_security() {
    local _file="$1" _label="${2:-env file}"

    # current user numeric uid; fail closed if empty
    local _cur_uid=""
    _cur_uid=$(id -u 2>/dev/null || true)
    [[ -z "${_cur_uid}" ]] \
        && die "${_label}: cannot determine current user uid (id -u failed), refusing"

    # check parent dir of the original path (catches symlink-in-unsafe-dir)
    _au_check_parent_dir "${_file}" "${_label}" "${_cur_uid}"

    # walk the symlink chain and check the parent dir of every hop target
    local _cur="${_file}" _target _hop_dir _i=0 _max=40
    while [[ "${_i}" -lt "${_max}" ]]; do
        [[ -L "${_cur}" ]] || break
        _target=$(readlink "${_cur}")
        if [[ "${_target}" == /* ]]; then
            _cur="${_target}"
        else
            _hop_dir="${_cur%/*}"
            [[ "${_hop_dir}" == "${_cur}" || -z "${_hop_dir}" ]] && _hop_dir="."
            _cur="${_hop_dir}/${_target}"
        fi
        # Check the parent of each intermediate hop target
        _au_check_parent_dir "${_cur}" "${_label}" "${_cur_uid}"
        _i=$(( _i + 1 ))
    done
    [[ "${_i}" -ge "${_max}" ]] \
        && die "${_label}: ${_file}: symlink chain too deep (>${_max} hops), refusing"

    # Canonicalize the final resolved path (handles .., multiple slashes)
    local _real=""
    _real=$(_au_resolve_realpath "${_file}") \
        || die "${_label}: ${_file}: symlink chain too deep or target unreachable"

    # File must be a regular file at the resolved path
    [[ -f "${_real}" ]] \
        || die "${_label}: ${_file}: resolved to '${_real}' which is not a regular file"

    # Perms check via path (before open): g/o-writable on the resolved file
    local _writable_file=""
    _writable_file=$(find "${_real}" -maxdepth 0 \( -perm -g+w -o -perm -o+w \) 2>/dev/null || true)
    [[ -n "${_writable_file}" ]] \
        && die "${_label}: ${_file} (resolved: ${_real}) is group/world-writable, refusing"

    # open the file NOW; uid check is done via the open fd.
    # On Linux /dev/fd/N is a symlink; stat -L follows it to the real file.
    # On macOS /dev/fd/N reflects the fd; stat -L gives the underlying file uid.
    # Note: mode check is path-based above (macOS /dev/fd reflects open mode, not file mode).
    # IMPORTANT: no `2>/dev/null` on exec with no command - that would permanently
    # redirect the current shell's stderr. Pre-check readability instead.
    local _fd
    [[ -r "${_real}" ]] || die "${_label}: ${_real}: file is not readable, refusing"
    exec {_fd}<"${_real}"

    # uid via fd (stat -L /dev/fd/N - GNU: -c '%u', BSD: -f '%u')
    local _file_uid_fd=""
    _file_uid_fd=$(stat -L -c '%u' "/dev/fd/${_fd}" 2>/dev/null \
        || stat -L -f '%u' "/dev/fd/${_fd}" 2>/dev/null \
        || true)
    if [[ -z "${_file_uid_fd}" ]]; then
        exec {_fd}<&-
        die "${_label}: ${_real}: cannot determine file owner via fd (stat failed), refusing"
    fi
    if [[ "${_file_uid_fd}" != "0" && "${_file_uid_fd}" != "${_cur_uid}" ]]; then
        exec {_fd}<&-
        die "${_label}: ${_file} (resolved: ${_real}): owned by uid ${_file_uid_fd} (not root=0 or current=${_cur_uid}), refusing"
    fi

    _AU_REAL_PATH="${_real}"
    _AU_REAL_FD="${_fd}"
}

# ------------------------------------------------------------------------------
# Function: _au_source_file
# Purpose.: Security-check and source a file with set -a.
#           sources /dev/fd/${_AU_REAL_FD} (already-opened fd),
#           not the path; closes fd on all exit paths.
# Args....: $1 - file path
#           $2 - label (e.g. "level-5 (extension)")
# Returns.: 0 on success; exits via die on security violation
# ------------------------------------------------------------------------------
_au_source_file() {
    local _file="$1" _label="${2:-env file}"
    _AU_REAL_PATH=""
    _AU_REAL_FD=""
    _au_check_file_security "${_file}" "${_label}"
    log_info "Config: loading ${_label}: ${_file}"
    _AU_CONF_FILES="${_AU_CONF_FILES:+${_AU_CONF_FILES} }${_file}"
    set -a
    # shellcheck source=/dev/null
    . "/dev/fd/${_AU_REAL_FD}"    # TOCTOU Fix 1: source already-opened fd
    local _src_rc=$?
    set +a
    exec {_AU_REAL_FD}<&-         # close fd on all paths
    return "${_src_rc}"
}

# =============================================================================
# Configuration precedence
# =============================================================================

# ------------------------------------------------------------------------------
# Function: au_load_config
# Purpose.: Load all configuration levels in the designed precedence order.
#
# Resolution order (highest wins):
#   8 CLI values          - applied by the calling script after this function
#   2 caller environment  - snapshot restored after all file sourcing
#   2a profile            - WP13 placeholder; no-op
#   3 AUTOUPGRADE_ENV_FILE - value from caller snapshot, loaded after level-5
#   4 ORADBA_CONFIG_DIR/autoupgrade.env (or ORADBA_ETC fallback)
#   5 AUTOUPGRADE_BASE/etc/autoupgrade.env
#   6 pin file (AU_PATCH)
#   7 built-in defaults
#
# Level-3 and level-4 paths are derived from the caller snapshot BEFORE
#     any file is sourced; file contents cannot redirect which higher-level
#     file is loaded.
# ------------------------------------------------------------------------------
au_load_config() {
    # Step 1: Take one snapshot of all currently exported variables.
    local -a _snap_names=() _snap_values=()
    local _n _i
    while IFS= read -r _n; do
        [[ -n "${_n}" ]] || continue
        _snap_names+=("${_n}")
        _snap_values+=("${!_n:-}")
    done < <(compgen -e)

    # Compute level-3 and level-4 paths from caller snapshot BEFORE sourcing.
    local _caller_l3="" _caller_l4=""
    local _snap_oradba_config_dir="" _snap_oradba_etc=""
    for _i in "${!_snap_names[@]}"; do
        case "${_snap_names[_i]}" in
            AUTOUPGRADE_ENV_FILE)  _caller_l3="${_snap_values[_i]}" ;;
            ORADBA_CONFIG_DIR)     _snap_oradba_config_dir="${_snap_values[_i]}" ;;
            ORADBA_ETC)            _snap_oradba_etc="${_snap_values[_i]}" ;;
        esac
    done
    if [[ -n "${_snap_oradba_config_dir}" ]]; then
        _caller_l4="${_snap_oradba_config_dir}/autoupgrade.env"
    elif [[ -n "${_snap_oradba_etc}" ]]; then
        _caller_l4="${_snap_oradba_etc}/autoupgrade.env"
    fi

    # Step 2: Source levels in order (lowest precedence first).

    # Level 5: extension env file
    local _l5="${AUTOUPGRADE_BASE}/etc/autoupgrade.env"
    if [[ -f "${_l5}" ]]; then
        _au_source_file "${_l5}" "level-5 (extension)"
    else
        log_debug "Config level-5: ${_l5}: not found, skipped"
    fi

    # Level 4: OraDBA site config (path from caller snapshot - M3)
    if [[ -n "${_caller_l4}" && -f "${_caller_l4}" ]]; then
        _au_source_file "${_caller_l4}" "level-4 (OraDBA site)"
    elif [[ -n "${_caller_l4}" ]]; then
        log_debug "Config level-4: ${_caller_l4}: not found, skipped"
    else
        log_debug "Config level-4: ORADBA_CONFIG_DIR/ORADBA_ETC not set in caller env, skipped"
    fi

    # Level 3: explicit env file override (path from caller snapshot - M3)
    if [[ -n "${_caller_l3}" ]]; then
        [[ -f "${_caller_l3}" ]] \
            || die "Config level-3 (AUTOUPGRADE_ENV_FILE): file not found: ${_caller_l3}"
        _au_source_file "${_caller_l3}" "level-3 (AUTOUPGRADE_ENV_FILE)"
    else
        log_debug "Config level-3: AUTOUPGRADE_ENV_FILE not set in caller env, skipped"
    fi

    # Step 3: Level 2a - profile (WP13: applied when _AU_PROFILE_PATH is set)
    if [[ -n "${_AU_PROFILE_PATH:-}" ]]; then
        au_apply_profile "${_AU_PROFILE_PATH}"
        log_debug "Config level-2a: profile applied: ${_AU_PROFILE_PATH}"
    else
        log_debug "Config level-2a: no profile selected"
    fi

    # Step 4: Restore caller snapshot - caller environment wins over all files.
    for _i in "${!_snap_names[@]}"; do
        _n="${_snap_names[_i]}"
        local _cur_val="${!_n-__UNSET_SENTINEL_2025__}"
        [[ "${_cur_val}" == "${_snap_values[_i]}" ]] && continue

        # if a file made a caller variable readonly with a different value -> die
        local _decl
        _decl=$(declare -p "${_n}" 2>/dev/null || true)
        if [[ "${_decl}" =~ ^declare\ -[a-zA-Z]*r ]]; then
            die "au_load_config: env file set '${_n}' to a different value but caller has it readonly; cannot restore - refusing"
        fi
        # shellcheck disable=SC2163
        export "${_n}=${_snap_values[_i]}" 2>/dev/null || true
    done

    # After snapshot restore: if the caller had AU_PATCH set (non-empty), the
    # profile value was overridden by the caller environment (level 2 > 2a).
    # Reset _au_patch_from_profile so au_read_pin treats AU_PATCH as a
    # caller-set value; the pin will then not override it either (level 6 < 2).
    # Design ref: "Configuration precedence" and Q13 in doc/design.md.
    local _snap_au_patch=""
    for _i in "${!_snap_names[@]}"; do
        if [[ "${_snap_names[_i]}" == "AU_PATCH" ]]; then
            _snap_au_patch="${_snap_values[_i]}"
            break
        fi
    done
    if [[ -n "${_snap_au_patch}" ]]; then
        _au_patch_from_profile=false
        log_debug "Config: AU_PATCH='${_snap_au_patch}' from caller env overrides profile; pin will not apply"
    fi

    # Step 5: Apply defaults (AU_DOWNLOAD_FOLDER needed before pin file read)
    au_set_defaults_no_patch

    # Step 6: Read pin file for AU_PATCH
    au_read_pin

    # Step 7: AU_PATCH default
    : "${AU_PATCH:=RECOMMENDED}"; export AU_PATCH
}

# ------------------------------------------------------------------------------
# Function: au_set_defaults_no_patch
# Purpose.: Apply built-in defaults for AU_* variables except AU_PATCH.
# Args....: None; Globals: AUTOUPGRADE_BASE
# ------------------------------------------------------------------------------
au_set_defaults_no_patch() {
    : "${AU_TARGET_VERSION:=19}"; export AU_TARGET_VERSION
    : "${AU_PLATFORM:=LINUX.X64}"; export AU_PLATFORM
    : "${AU_GOLD_IMAGE:=NO}"; export AU_GOLD_IMAGE
    : "${AU_LOG_DIR:=${AUTOUPGRADE_BASE}/logs}"; export AU_LOG_DIR
    : "${AU_KEYSTORE:=${AUTOUPGRADE_BASE}/keystore}"; export AU_KEYSTORE
    : "${AU_DOWNLOAD_FOLDER:=${AUTOUPGRADE_BASE}/patches}"; export AU_DOWNLOAD_FOLDER
    # Optional set: default to empty; au_render_cfg drops empty lines.
    : "${AU_SOURCE_HOME:=}"; export AU_SOURCE_HOME
    : "${AU_TARGET_HOME:=}"; export AU_TARGET_HOME
    : "${AU_SID:=}"; export AU_SID
    : "${AU_EDITION:=}"; export AU_EDITION
    : "${AU_GROUP_OSDBA:=}"; export AU_GROUP_OSDBA
    : "${AU_GROUP_OSOPER:=}"; export AU_GROUP_OSOPER
    : "${AU_GROUP_OSBACKUPDBA:=}"; export AU_GROUP_OSBACKUPDBA
    : "${AU_GROUP_OSDGDBA:=}"; export AU_GROUP_OSDGDBA
    : "${AU_GROUP_OSKMDBA:=}"; export AU_GROUP_OSKMDBA
    : "${AU_GROUP_OSRACDBA:=}"; export AU_GROUP_OSRACDBA
    : "${AU_ORACLE_BASE:=}"; export AU_ORACLE_BASE
    : "${AU_INVENTORY_LOCATION:=}"; export AU_INVENTORY_LOCATION
    : "${AU_INVENTORY_GROUP:=}"; export AU_INVENTORY_GROUP
}

# ------------------------------------------------------------------------------
# Function: au_set_defaults
# Purpose.: Apply all built-in defaults including AU_PATCH. Backward compat.
# Args....: None; Globals: AUTOUPGRADE_BASE
# ------------------------------------------------------------------------------
au_set_defaults() {
    au_set_defaults_no_patch
    au_read_pin
    : "${AU_PATCH:=RECOMMENDED}"; export AU_PATCH

    if [[ "${_au_patch_pinned:-false}" == true ]]; then
        echo "Patch list.: ${AU_PATCH} (pinned by ${AU_DOWNLOAD_FOLDER}/au_patch.env)" >&2
    else
        echo "Patch list.: ${AU_PATCH}" >&2
    fi
}

# ------------------------------------------------------------------------------
# Function: au_read_pin
# Purpose.: Read AU_PATCH from the pin file if not already set by the caller
#           environment, or if it was set by the profile (pin wins over profile
#           per design step 7). The caller environment always wins over the pin.
# Notes...: Pin file is parsed line-by-line (never sourced).
#           Security: refuse symlink, numeric owner check, refuse g/o-writable.
#           Only AU_PATCH=<value> accepted; value must match ^[A-Za-z0-9_.,:-]+$
#           When AU_PATCH is set by the caller (not profile) and a pin file
#           exists, a WARN is logged naming the pin file.
# ------------------------------------------------------------------------------
au_read_pin() {
    _au_patch_pinned=false

    local _patch_env="${AU_DOWNLOAD_FOLDER}/au_patch.env"

    # If AU_PATCH is set and came from caller env (not from profile), do not
    # override it; warn if a pin file also exists.
    if [[ -n "${AU_PATCH:-}" && "${_au_patch_from_profile:-false}" != true ]]; then
        if [[ -f "${_patch_env}" ]]; then
            log_warn "AU_PATCH set in caller environment; pin file ${_patch_env} not applied (caller wins)"
        fi
        return 0
    fi

    [[ -f "${_patch_env}" ]] || return 0

    # Security: refuse symlink
    if [[ -L "${_patch_env}" ]]; then
        echo "WARN: au_patch.env is a symlink, skipping (using RECOMMENDED)" >&2
        return 0
    fi

    # Security: numeric ownership check
    local _pf_uid=""
    _pf_uid=$(stat -c '%u' "${_patch_env}" 2>/dev/null \
        || stat -f '%u' "${_patch_env}" 2>/dev/null \
        || true)
    local _cur_uid=""
    _cur_uid=$(id -u 2>/dev/null || true)
    if [[ -z "${_pf_uid}" || -z "${_cur_uid}" ]]; then
        echo "WARN: au_patch.env: cannot verify ownership (stat or id failed), skipping (using RECOMMENDED)" >&2
        return 0
    fi
    if [[ "${_pf_uid}" != "${_cur_uid}" ]]; then
        echo "WARN: au_patch.env not owned by current user (owner=${_pf_uid}), skipping (using RECOMMENDED)" >&2
        return 0
    fi

    # Security: refuse g/o-writable
    local _pf_perms=""
    _pf_perms=$(stat -c '%a' "${_patch_env}" 2>/dev/null \
        || stat -f '%Lp' "${_patch_env}" 2>/dev/null \
        || true)
    if [[ -n "${_pf_perms}" ]]; then
        local _pf_last="${_pf_perms: -2}"
        local _pf_g="${_pf_last:0:1}" _pf_w="${_pf_last:1:1}"
        if [[ "${_pf_g}" =~ [2367] || "${_pf_w}" =~ [2367] ]]; then
            echo "WARN: au_patch.env is group/world-writable (perms ${_pf_perms}), skipping (using RECOMMENDED)" >&2
            return 0
        fi
    fi

    # Parse line-by-line: only AU_PATCH=<value> accepted
    local _lineno=0 _line _val
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        _lineno=$(( _lineno + 1 ))
        local _trim="${_line#"${_line%%[![:space:]]*}"}"
        _trim="${_trim%"${_trim##*[![:space:]]}"}"
        [[ -z "${_trim}" || "${_trim}" == '#'* ]] && continue
        if [[ "${_trim}" == AU_PATCH=* ]]; then
            _val="${_trim#AU_PATCH=}"
            if [[ "${_val}" == '"'*'"' ]]; then
                _val="${_val#\"}"; _val="${_val%\"}"
            elif [[ "${_val}" == "'"*"'" ]]; then
                _val="${_val#\'}"; _val="${_val%\'}"
            fi
            if [[ "${_val}" =~ ^[A-Za-z0-9_.,:-]+$ ]]; then
                AU_PATCH="${_val}"; export AU_PATCH; _au_patch_pinned=true
            else
                echo "WARN: au_patch.env line ${_lineno}: AU_PATCH value '${_val}' contains invalid characters, ignored" >&2
            fi
        else
            echo "WARN: au_patch.env line ${_lineno}: ignored: ${_trim}" >&2
        fi
    done < "${_patch_env}"
}

# =============================================================================
# Backward-compat: au_source_env_file
# =============================================================================

# ------------------------------------------------------------------------------
# Function: au_source_env_file
# Purpose.: Source an optional site env file with set -a; caller env wins.
#           thin wrapper around _au_check_file_security (Decision-5 rules).
#           Missing file is not an error. Symlinks are resolved (not refused).
# Args....: $1 - path to env file
# Returns.: 0; exits via die on security violation
# Notes...: Decision-5 rules: owner = current user OR root; symlinks resolved
#           and target checked; not g/o-writable on file or path dirs; fatal.
#           Previously refused symlinks (0.5.0); now resolves them per Decision-5.
# ------------------------------------------------------------------------------
au_source_env_file() {
    local env_file="$1"
    [[ -f "${env_file}" || -L "${env_file}" ]] || return 0

    # delegate all security checks to _au_check_file_security (Decision-5)
    _AU_REAL_PATH=""
    _AU_REAL_FD=""
    _au_check_file_security "${env_file}" "env file"

    # Capture caller's exported variable names and values
    local -a _caller_names=() _caller_values=()
    local _n
    while IFS= read -r _n; do
        [[ -n "${_n}" ]] || continue
        _caller_names+=("${_n}")
        _caller_values+=("${!_n:-}")
    done < <(compgen -e)

    set -a
    # shellcheck source=/dev/null
    . "/dev/fd/${_AU_REAL_FD}"    # TOCTOU Fix 1: source already-opened fd
    local _src_rc=$?
    set +a
    exec {_AU_REAL_FD}<&-         # close fd on all paths

    # Restore caller values: caller env wins over env file
    local _i
    for _i in "${!_caller_names[@]}"; do
        _n="${_caller_names[_i]}"
        [[ "${!_n-}" == "${_caller_values[_i]}" ]] && continue
        # check for readonly before restoring; die with message on stderr
        local _decl
        _decl=$(declare -p "${_n}" 2>/dev/null || true)
        if [[ "${_decl}" =~ ^declare\ -[a-zA-Z]*r ]]; then
            die "au_source_env_file: env file set '${_n}' to a different value but caller has it readonly; cannot restore - refusing"
        fi
        # shellcheck disable=SC2163
        export "${_n}=${_caller_values[_i]}" 2>/dev/null || true
    done

    echo "Env file...: ${env_file}" >&2
    return "${_src_rc}"
}

# =============================================================================
# Config variable checking
# =============================================================================

# ------------------------------------------------------------------------------
# Function: au_check_cfg_vars
# Purpose.: Verify all ${VAR} and $VAR references in a config file are set.
#           Populates AU_CFG_VARS for restricted envsubst in au_render_cfg.
# Args....: $1 - path to config file
# Returns.: 0 if all variables set; exits 1 listing each unset name
# Globals.: Sets AU_CFG_VARS
# ------------------------------------------------------------------------------
au_check_cfg_vars() {
    local cfg_file="$1"
    local -a var_names=()
    local var_name missing=""

    [[ -f "${cfg_file}" ]] || { echo "ERROR: Config file not found: ${cfg_file}" >&2; exit 1; }

    local filtered
    filtered="$(grep -vE '^[[:space:]]*#' "${cfg_file}" 2>/dev/null || true)"

    while IFS= read -r var_name; do
        [[ -n "${var_name}" ]] && var_names+=("${var_name}")
    done < <(
        {
            grep -oE '\$[{][A-Za-z_][A-Za-z0-9_]*[}]' <<< "${filtered}" \
                | sed -e 's/^\$[{]//' -e 's/[}]$//' || true
            grep -oE '\$[A-Za-z_][A-Za-z0-9_]*' <<< "${filtered}" \
                | sed 's/^\$//' || true
        } 2>/dev/null | sort -u
    )

    # shellcheck disable=SC2034
    AU_CFG_VARS=("${var_names[@]+"${var_names[@]}"}")

    for var_name in "${var_names[@]+"${var_names[@]}"}"; do
        # shellcheck disable=SC2016
        if [[ -z "${!var_name+isset}" ]]; then
            missing="${missing:+${missing}, }${var_name}"
        fi
    done

    if [[ -n "${missing}" ]]; then
        echo "ERROR: Config references unset variables: ${missing}" >&2
        exit 1
    fi
    return 0
}

# =============================================================================
# Config rendering and per-mode checks
# =============================================================================

# ------------------------------------------------------------------------------
# Function: au_render_cfg
# Purpose.: Render an AU config template: expand variables, drop empty lines
#           (named in log), apply mode-specific rules.
# Args....: $1 - source config file path
#           $2 - AutoUpgrade mode (download|create_home|deploy|...)
#           $3 - output file path
# Returns.: 0; writes rendered config to $3
# Notes...: Must be called AFTER au_check_cfg_vars (needs AU_CFG_VARS).
#           key trimmed of whitespace before comparison.
#           non-comment, non-blank lines without '=' -> die with line number.
#           envsubst must be on PATH; temp file cleaned up on RETURN.
#           global.keystore: rendered only for mode == 'download' (exact match).
#           Dropped keys named via log_info (expected, not a warning).
# ------------------------------------------------------------------------------
au_render_cfg() {
    local _cfg="$1"
    local _mode="${2:-}"
    local _out="$3"
    local -a _dropped=()

    [[ -f "${_cfg}" ]] || { echo "ERROR: Config file not found: ${_cfg}" >&2; exit 1; }

    # envsubst must be available
    command -v envsubst >/dev/null 2>&1 \
        || { echo "ERROR: envsubst not found - install gettext (yum/apt/brew install gettext)" >&2; exit 1; }

    # Build restricted envsubst spec; injection guard
    local _envsubst_vars="" _v _val
    for _v in "${AU_CFG_VARS[@]+"${AU_CFG_VARS[@]}"}"; do
        _val="${!_v:-}"
        if [[ "${_val}" == *$'\n'* || "${_val}" == *$'\r'* ]]; then
            echo "ERROR: Variable ${_v} value contains a newline or carriage return (possible injection)" >&2
            exit 1
        fi
        _envsubst_vars="${_envsubst_vars:+${_envsubst_vars} }\${${_v}}"
    done

    local _tmp
    _tmp="$(mktemp "${TMPDIR:-/tmp}/au_render_XXXXXX")"
    # register with EXIT cleanup list; no RETURN trap (avoids global trap pollution)
    _AU_TMPFILES+=("${_tmp}")

    local _line _trim _key _val_tpl _expanded _trim_exp _var_ref _lineno=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        _lineno=$(( _lineno + 1 ))
        _trim="${_line#"${_line%%[![:space:]]*}"}"
        _trim="${_trim%"${_trim##*[![:space:]]}"}"

        # Blank or comment: pass through unchanged
        if [[ -z "${_trim}" || "${_trim}" == '#'* ]]; then
            printf '%s\n' "${_line}" >> "${_tmp}"
            continue
        fi

        # non-comment, non-blank lines must contain '='
        if [[ "${_trim}" != *'='* ]]; then
            die "au_render_cfg: config line ${_lineno}: no '=' separator: ${_trim}"
        fi

        _key="${_trim%%=*}"
        # trim whitespace from key and value template
        _key="${_key#"${_key%%[![:space:]]*}"}"
        _key="${_key%"${_key##*[![:space:]]}"}"
        _val_tpl="${_trim#*=}"
        _val_tpl="${_val_tpl#"${_val_tpl%%[![:space:]]*}"}"

        # global.keystore: rendered only for -mode download (exact lowercase)
        if [[ "${_key}" == "global.keystore" && "${_mode}" != "download" ]]; then
            _dropped+=("${_key} (AU_KEYSTORE) - rendered only for -mode download")
            continue
        fi

        # Expand with restricted envsubst
        if [[ -n "${_envsubst_vars}" ]]; then
            _expanded=$(envsubst "${_envsubst_vars}" <<< "${_val_tpl}")
        else
            _expanded="${_val_tpl}"
        fi

        # Check if value is empty after expansion
        _trim_exp="${_expanded#"${_expanded%%[![:space:]]*}"}"
        _trim_exp="${_trim_exp%"${_trim_exp##*[![:space:]]}"}"
        if [[ -z "${_trim_exp}" ]]; then
            _var_ref=""
            if [[ "${_val_tpl}" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; then
                _var_ref="${BASH_REMATCH[1]}"
            elif [[ "${_val_tpl}" =~ \$([A-Za-z_][A-Za-z0-9_]*) ]]; then
                _var_ref="${BASH_REMATCH[1]}"
            fi
            _dropped+=("${_key} (${_var_ref:-value}) - empty after expansion")
            continue
        fi

        printf '%s=%s\n' "${_key}" "${_expanded}" >> "${_tmp}"
    done < "${_cfg}"

    mv "${_tmp}" "${_out}"
    # Remove _tmp from the cleanup list now that it has been renamed to _out
    local -a _au_tf_new=()
    local _au_tf_e
    for _au_tf_e in "${_AU_TMPFILES[@]+"${_AU_TMPFILES[@]}"}"; do
        [[ "${_au_tf_e}" == "${_tmp}" ]] || _au_tf_new+=("${_au_tf_e}")
    done
    _AU_TMPFILES=("${_au_tf_new[@]+"${_au_tf_new[@]}"}")

    # Report dropped keys (named, log_info per coordinator edit)
    if [[ "${#_dropped[@]}" -gt 0 ]]; then
        log_info "Config rendering: dropped ${#_dropped[@]} key(s) with empty value:"
        local _d
        for _d in "${_dropped[@]}"; do
            log_info "  dropped: ${_d}"
        done
    fi
}

# ------------------------------------------------------------------------------
# Function: au_check_cfg_mode
# Purpose.: Validate mandatory variables per AutoUpgrade mode.
# Args....: $1 - AutoUpgrade mode string (download|create_home|deploy|...)
# Returns.: 0 if all mandatory vars set; exits 1 naming each missing var
# ------------------------------------------------------------------------------
au_check_cfg_mode() {
    local _mode="${1:-}"
    local _fail=false

    case "${_mode}" in
        download)
            if [[ -z "${AU_PATCH:-}" ]]; then
                log_error "Mode download: AU_PATCH is required but not set"; _fail=true
            fi
            if [[ -n "${AU_SOURCE_HOME:-}" && ! -d "${AU_SOURCE_HOME}" ]]; then
                log_error "Mode download: AU_SOURCE_HOME='${AU_SOURCE_HOME}' does not exist"
                _fail=true
            fi
            ;;
        create_home)
            if [[ -z "${AU_TARGET_HOME:-}" ]]; then
                log_error "Mode create_home: AU_TARGET_HOME is required but not set"; _fail=true
            fi
            if [[ -z "${AU_SOURCE_HOME:-}" ]]; then
                if [[ -z "${AU_ORACLE_BASE:-}" ]]; then
                    log_error "Mode create_home: AU_ORACLE_BASE required when AU_SOURCE_HOME is not set"
                    _fail=true
                fi
                if [[ "${AU_PATCH:-}" != *"RU:"* && -z "${AU_TARGET_VERSION:-}" ]]; then
                    log_error "Mode create_home: AU_TARGET_VERSION or RU:x.y in AU_PATCH required"
                    _fail=true
                fi
            fi
            ;;
        deploy)
            local _req
            for _req in AU_SID AU_SOURCE_HOME AU_TARGET_HOME; do
                if [[ -z "${!_req:-}" ]]; then
                    log_error "Mode deploy: ${_req} is required but not set"; _fail=true
                fi
            done
            ;;
        "" | analyze | fixups | restore | rollback | resume | *)
            log_debug "Mode '${_mode}': no wrapper pre-checks"
            ;;
    esac

    [[ "${_fail}" == false ]] || exit 1
}

# =============================================================================
# WP13: Patch profiles
# =============================================================================

# Module-level: path to the selected profile (set by au_find_profile / --profile)
_AU_PROFILE_PATH=""

# Module-level: set to true when au_apply_profile sets AU_PATCH (pin wins over it)
_au_patch_from_profile=false

# Allowed keys in a profile file (allow-list; unknown keys are fatal)
_AU_PROFILE_ALLOWED_KEYS=(
    AU_PROFILE_DESC
    AU_PATCH
    AU_TARGET_VERSION
    AU_PLATFORM
    AU_GOLD_IMAGE
    AU_EDITION
)

# ------------------------------------------------------------------------------
# Function: _au_validate_group_name
# Purpose.: Validate an OS group name: ^[A-Za-z0-9_.-]{1,32}$
# Args....: $1 - group name value
#           $2 - variable name (for the error message)
# Returns.: 0 if valid; exits via die on violation.
# ------------------------------------------------------------------------------
_au_validate_group_name() {
    local _val="$1" _varname="$2"
    [[ -z "${_val}" ]] && return 0   # empty means unset; callers handle that separately
    if [[ ! "${_val}" =~ ^[A-Za-z0-9_.-]{1,32}$ ]]; then
        die "Invalid group name for ${_varname}='${_val}' (must match ^[A-Za-z0-9_.-]{1,32}$)"
    fi
}

# ------------------------------------------------------------------------------
# Function: au_find_profile
# Purpose.: Resolve a profile name or path to an absolute file path.
#           A value containing '/' is treated as an explicit path.
#           A bare name is searched in:
#             1. AU_PROFILE_DIR (if set)
#             2. ${ORADBA_CONFIG_DIR}/autoupgrade/profiles (if set)
#             3. ${AUTOUPGRADE_BASE}/etc/profiles/ (shipped)
#           First match wins; shadowed files are reported by name.
# Args....: $1 - name or path
# Returns.: 0; sets _AU_PROFILE_PATH; exits 1 if not found.
# ------------------------------------------------------------------------------
au_find_profile() {
    local _input="$1"
    _AU_PROFILE_PATH=""

    # Explicit path
    if [[ "${_input}" == */* ]]; then
        if [[ -f "${_input}" ]]; then
            _AU_PROFILE_PATH="${_input}"
            log_debug "Profile: explicit path: ${_AU_PROFILE_PATH}"
            return 0
        else
            die "Profile: explicit path not found: ${_input}"
        fi
    fi

    # Name lookup: build search dirs
    local -a _search_dirs=()
    [[ -n "${AU_PROFILE_DIR:-}" ]] && _search_dirs+=("${AU_PROFILE_DIR}")
    if [[ -n "${ORADBA_CONFIG_DIR:-}" ]]; then
        _search_dirs+=("${ORADBA_CONFIG_DIR}/autoupgrade/profiles")
    fi
    _search_dirs+=("${AUTOUPGRADE_BASE}/etc/profiles")

    local _name="${_input%.profile}"  # strip .profile suffix if provided
    local -a _found=()
    local _dir
    for _dir in "${_search_dirs[@]}"; do
        local _candidate="${_dir}/${_name}.profile"
        if [[ -f "${_candidate}" ]]; then
            _found+=("${_candidate}")
        fi
    done

    if [[ "${#_found[@]}" -eq 0 ]]; then
        log_error "Profile '${_input}' not found. Searched:"
        for _dir in "${_search_dirs[@]}"; do
            log_error "  ${_dir}/${_name}.profile"
        done
        exit 1
    fi

    _AU_PROFILE_PATH="${_found[0]}"
    log_debug "Profile: using: ${_AU_PROFILE_PATH}"

    if [[ "${#_found[@]}" -gt 1 ]]; then
        local _i
        log_warn "Profile '${_name}': shadowed by '${_AU_PROFILE_PATH}'. Other matches (not used):"
        for _i in "${!_found[@]}"; do
            [[ "${_i}" -eq 0 ]] && continue
            log_warn "  ${_found[_i]}"
        done
    fi
}

# ------------------------------------------------------------------------------
# Function: au_apply_profile
# Purpose.: Parse a profile file with an allow-list and apply allowed keys to
#           the current environment. Never sourced; parsed line-by-line.
#           Unknown keys are fatal. File security: same as env files.
# Args....: $1 - absolute path to the .profile file
# Returns.: 0; exports profile keys; exits 1 on security violation or bad key.
# Notes...: Values are literal (no variable expansion).
#           AU_PATCH in the profile is overridden by the pin file later
#           (pin file wins at level 6).
# ------------------------------------------------------------------------------
au_apply_profile() {
    local _profile_file="$1"

    [[ -f "${_profile_file}" ]] || die "Profile file not found: ${_profile_file}"

    # Full Decision-5 security checks: symlink chain per-hop parent check,
    # numeric uid fail-closed, mode, TOCTOU-safe fd open.
    _AU_REAL_FD=""
    _au_check_file_security "${_profile_file}" "profile"
    # _AU_REAL_FD is now open and pointing to the resolved file.

    # Parse line by line with allow-list; read from the open fd (TOCTOU-safe).
    local _lineno=0 _line _trim _key _val _allowed _ok
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        _lineno=$(( _lineno + 1 ))
        _trim="${_line#"${_line%%[![:space:]]*}"}"
        _trim="${_trim%"${_trim##*[![:space:]]}"}"
        [[ -z "${_trim}" || "${_trim}" == '#'* ]] && continue

        if [[ "${_trim}" != *'='* ]]; then
            exec {_AU_REAL_FD}<&-
            die "Profile ${_profile_file} line ${_lineno}: no '=' separator: ${_trim}"
        fi

        _key="${_trim%%=*}"
        _key="${_key#"${_key%%[![:space:]]*}"}"
        _key="${_key%"${_key##*[![:space:]]}"}"
        _val="${_trim#*=}"
        # Strip optional surrounding quotes
        if [[ "${_val}" == '"'*'"' ]]; then
            _val="${_val#\"}"; _val="${_val%\"}"
        elif [[ "${_val}" == "'"*"'" ]]; then
            _val="${_val#\'}"; _val="${_val%\'}"
        fi

        # Allow-list check
        _ok=false
        for _allowed in "${_AU_PROFILE_ALLOWED_KEYS[@]}"; do
            [[ "${_key}" == "${_allowed}" ]] && _ok=true && break
        done
        if [[ "${_ok}" == false ]]; then
            exec {_AU_REAL_FD}<&-
            die "Profile ${_profile_file} line ${_lineno}: unknown key '${_key}' (allowed: ${_AU_PROFILE_ALLOWED_KEYS[*]})"
        fi

        # Validate specific keys
        case "${_key}" in
            AU_GOLD_IMAGE)
                if [[ ! "${_val}" =~ ^(YES|NO|AUTO|ALL)$ ]]; then
                    exec {_AU_REAL_FD}<&-
                    die "Profile ${_profile_file} line ${_lineno}: AU_GOLD_IMAGE must be YES|NO|AUTO|ALL, got: ${_val}"
                fi
                ;;
            AU_EDITION)
                if [[ ! "${_val}" =~ ^(EE|SE2)$ ]]; then
                    exec {_AU_REAL_FD}<&-
                    die "Profile ${_profile_file} line ${_lineno}: AU_EDITION must be EE|SE2, got: ${_val}"
                fi
                ;;
            AU_TARGET_VERSION)
                if [[ ! "${_val}" =~ ^[0-9]{2}$ ]]; then
                    exec {_AU_REAL_FD}<&-
                    die "Profile ${_profile_file} line ${_lineno}: AU_TARGET_VERSION must be a 2-digit number, got: ${_val}"
                fi
                ;;
            AU_PLATFORM)
                if [[ ! "${_val}" =~ ^[A-Z0-9._]+$ ]]; then
                    exec {_AU_REAL_FD}<&-
                    die "Profile ${_profile_file} line ${_lineno}: AU_PLATFORM must match ^[A-Z0-9._]+$, got: ${_val}"
                fi
                ;;
            AU_PATCH)
                # Validate patch value; keywords validated later by au_validate_profile
                if [[ ! "${_val}" =~ ^[A-Za-z0-9_.,:-]+$ ]]; then
                    exec {_AU_REAL_FD}<&-
                    die "Profile ${_profile_file} line ${_lineno}: AU_PATCH contains invalid characters: ${_val}"
                fi
                ;;
        esac

        # Apply: only set if not already set (caller env wins per level-2 > level-2a)
        # We apply unconditionally here and the caller snapshot is restored in
        # au_load_config step 4 to enforce caller-wins.
        export "${_key}=${_val}"
        # Track when profile sets AU_PATCH so the pin file can override it (design step 7)
        [[ "${_key}" == "AU_PATCH" ]] && _au_patch_from_profile=true
        log_debug "Profile: ${_key}=${_val}"
    done < "/dev/fd/${_AU_REAL_FD}"

    # Close the fd on normal exit
    exec {_AU_REAL_FD}<&-

    log_info "Profile loaded: ${_profile_file}"
}

# ------------------------------------------------------------------------------
# Function: au_validate_profile
# Purpose.: Validate AU_PATCH keywords against target version and platform.
#           Called after the full configuration is resolved.
# Args....: None (reads AU_PATCH, AU_TARGET_VERSION, AU_PLATFORM from env)
# Returns.: 0 if valid; exits 1 with a named error on violation.
# Rules...:
#   - RECOMMENDED + RU:x.y together: fatal (PCB_RECOMMENDED_VERSION_MISMATCH)
#   - CSPU on LINUX.X64 for 19c or 23ai: fatal (VCP_CSPU_UNSUPPORTED_ON_LINUX)
#   - CSPU valid for 21c on all platforms
#   - MRP/DPBP/CSPU with version number: fatal (PATCH_FORMAT_FAIL)
#   - On 21c: MRP, OJVM, DPBP not supported (VCP_MRP_UNSUPPORTED_ON_21)
#   - OJVM:x.y must match RU:x.y (VCP_INVALID_RU_OJVM_MISMATCH)
# ------------------------------------------------------------------------------
au_validate_profile() {
    local _patch="${AU_PATCH:-}"
    local _ver="${AU_TARGET_VERSION:-19}"
    local _plat="${AU_PLATFORM:-LINUX.X64}"
    local _fail=false

    [[ -z "${_patch}" ]] && return 0  # no patch to validate

    # Split into tokens
    local -a _tokens=()
    local _saved_IFS="${IFS}"
    IFS=',' read -ra _tokens <<< "${_patch}"
    IFS="${_saved_IFS}"

    local _has_recommended=false _has_ru=false _ru_ver="" _ojvm_ver="" _has_cspu=false
    local _has_mrp=false _has_dpbp=false _has_ojvm=false
    local _token

    for _token in "${_tokens[@]}"; do
        _token="${_token#"${_token%%[![:space:]]*}"}"
        _token="${_token%"${_token##*[![:space:]]}"}"
        case "${_token}" in
            RECOMMENDED|RECOMMENDED:*)
                _has_recommended=true
                ;;
            RU)
                _has_ru=true
                ;;
            RU:*)
                _has_ru=true; _ru_ver="${_token#RU:}"
                ;;
            OJVM:*)
                _has_ojvm=true; _ojvm_ver="${_token#OJVM:}"
                ;;
            OJVM)
                _has_ojvm=true
                ;;
            MRP)
                _has_mrp=true
                ;;
            MRP:*)
                log_error "AU_PATCH: MRP must not have a version number (PATCH_FORMAT_FAIL): ${_token}"
                _fail=true
                ;;
            DPBP)
                _has_dpbp=true
                ;;
            DPBP:*)
                log_error "AU_PATCH: DPBP must not have a version number (PATCH_FORMAT_FAIL): ${_token}"
                _fail=true
                ;;
            CSPU)
                _has_cspu=true
                ;;
            CSPU:*)
                log_error "AU_PATCH: CSPU must not have a version number (PATCH_FORMAT_FAIL): ${_token}"
                _fail=true
                ;;
            [0-9]*)
                # Plain patch number: accepted
                ;;
            OPATCH|AU|TOOLS|GOLDIMAGE:*)
                # Valid keywords
                ;;
            JDK|JDK:*|OCW|OCW:*|GI|GI:*)
                # Valid keywords, also with version (same set as au_patch_pin.sh)
                ;;
            *)
                log_warn "AU_PATCH: unknown keyword '${_token}' (may be rejected by AutoUpgrade)"
                ;;
        esac
    done

    # RECOMMENDED + RU:x.y together
    if [[ "${_has_recommended}" == true && "${_has_ru}" == true ]]; then
        log_error "AU_PATCH: RECOMMENDED and RU:x.y cannot be combined (PCB_RECOMMENDED_VERSION_MISMATCH)"
        _fail=true
    fi

    # CSPU platform check
    local _major_ver="${_ver%%.*}"
    if [[ "${_has_cspu}" == true ]]; then
        local _plat_up="${_plat^^}"
        # CSPU is fatal on Linux for 19c and 23ai
        if [[ "${_plat_up}" == "LINUX.X64" || "${_plat_up}" == "LINUX.ARM" ]]; then
            if [[ "${_major_ver}" == "19" || "${_major_ver}" == "23" ]]; then
                log_error "AU_PATCH: CSPU is not supported on Linux for Oracle Database ${_major_ver}c (VCP_CSPU_UNSUPPORTED_ON_LINUX)"
                log_error "         Use MRP instead for Linux patching."
                _fail=true
            fi
        fi
    fi

    # 21c restrictions: no MRP, OJVM, DPBP
    if [[ "${_major_ver}" == "21" ]]; then
        if [[ "${_has_mrp}" == true ]]; then
            log_error "AU_PATCH: MRP is not supported on 21c (VCP_MRP_UNSUPPORTED_ON_21)"
            _fail=true
        fi
        if [[ "${_has_ojvm}" == true ]]; then
            log_error "AU_PATCH: OJVM is not supported on 21c (VCP_INVALID_PATCH_APPLY)"
            _fail=true
        fi
        if [[ "${_has_dpbp}" == true ]]; then
            log_error "AU_PATCH: DPBP is not supported on 21c (VCP_INVALID_PATCH_APPLY)"
            _fail=true
        fi
    fi

    # OJVM:x.y must match RU:x.y
    if [[ -n "${_ojvm_ver}" && -n "${_ru_ver}" && "${_ojvm_ver}" != "${_ru_ver}" ]]; then
        log_error "AU_PATCH: OJVM:${_ojvm_ver} does not match RU:${_ru_ver} (VCP_INVALID_RU_OJVM_MISMATCH)"
        _fail=true
    fi

    [[ "${_fail}" == false ]] || exit 1
}

# =============================================================================
# WP15: Edition and OS groups
# =============================================================================

# Default group names (Oracle Database Preinstallation RPM names)
_AU_DEFAULT_GROUP_OSDBA="dba"
_AU_DEFAULT_GROUP_OSOPER="oper"
_AU_DEFAULT_GROUP_OSBACKUPDBA="backupdba"
_AU_DEFAULT_GROUP_OSDGDBA="dgdba"
_AU_DEFAULT_GROUP_OSKMDBA="kmdba"
_AU_DEFAULT_GROUP_OSRACDBA="racdba"

# SS_* field names in config.c -> AU_GROUP_* mapping
_AU_GROUP_VARS=(AU_GROUP_OSDBA AU_GROUP_OSOPER AU_GROUP_OSBACKUPDBA AU_GROUP_OSDGDBA AU_GROUP_OSKMDBA AU_GROUP_OSRACDBA)

# ------------------------------------------------------------------------------
# Function: au_derive_groups_from_config_c
# Purpose.: Read SS_* group fields from an Oracle config.c file and set the
#           corresponding AU_GROUP_* variables (only if unset).
# Args....: $1 - path to config.c (or a file containing SS_* lines)
# Returns.: 0; exports AU_GROUP_* variables; reports WARN on missing fields.
# Notes...: Only unset AU_GROUP_* are filled (caller environment wins).
#           Reads lines of the form: SS_DBA_GRP=dba
# ------------------------------------------------------------------------------
au_derive_groups_from_config_c() {
    local _config_c="$1"
    [[ -f "${_config_c}" ]] || { log_warn "config.c not found: ${_config_c}"; return 0; }
    if ! declare -F au_home_read_groups >/dev/null; then
        log_warn "Groups: lib/au_home.sh not loaded; AU_GROUP_* not derived from ${_config_c}"
        return 0
    fi

    # Single parser for the real format (#define SS_DBA_GRP "dba") lives in
    # au_home.sh; map its home_settings key names to the AU_GROUP_* variables
    local _kv _key _val _var _ngroups=0
    while IFS= read -r _kv; do
        _key="${_kv%%=*}"
        _val="${_kv#*=}"
        case "${_key}" in
            osdba_group) _var="AU_GROUP_OSDBA" ;;
            osoper_group) _var="AU_GROUP_OSOPER" ;;
            osbackupdba_group) _var="AU_GROUP_OSBACKUPDBA" ;;
            osdgdba_group) _var="AU_GROUP_OSDGDBA" ;;
            oskmdba_group) _var="AU_GROUP_OSKMDBA" ;;
            osracdba_group) _var="AU_GROUP_OSRACDBA" ;;
            *) continue ;;
        esac
        _ngroups=$((_ngroups + 1))
        # Validate group name from config.c before use
        _au_validate_group_name "${_val}" "${_var}"
        # A value set by the caller or a config file wins over the source home
        [[ -n "${!_var:-}" ]] && continue
        export "${_var}=${_val}"
        log_info "Groups: ${_var}=${_val} (from ${_config_c})"
    done < <(au_home_read_groups "${_config_c}" 2>/dev/null || true)

    if [[ "${_ngroups}" -eq 0 ]]; then
        log_warn "Groups: no SS_*_GRP defines found in ${_config_c}; AU_GROUP_* not derived"
    fi
}

# ------------------------------------------------------------------------------
# Function: au_set_edition_defaults
# Purpose.: Apply AU_EDITION default logic based on AU_SOURCE_HOME presence.
#           - AU_SOURCE_HOME set, AU_EDITION unset: leave empty (AU derives)
#           - AU_SOURCE_HOME unset, AU_EDITION unset: default to EE
#           - AU_EDITION set: validate (EE|SE2)
# Args....: None (reads AU_EDITION, AU_SOURCE_HOME from env)
# Returns.: 0; exports AU_EDITION
# ------------------------------------------------------------------------------
au_set_edition_defaults() {
    # Validate if already set
    if [[ -n "${AU_EDITION:-}" ]]; then
        [[ "${AU_EDITION}" =~ ^(EE|SE2)$ ]] \
            || die "AU_EDITION: invalid value '${AU_EDITION}' (must be EE or SE2)"
        log_debug "Edition: using caller value: ${AU_EDITION}"
        return 0
    fi

    if [[ -n "${AU_SOURCE_HOME:-}" ]]; then
        # Leave AU_EDITION empty; AutoUpgrade derives edition from source home
        log_debug "Edition: unset + AU_SOURCE_HOME set; AutoUpgrade will derive edition"
    else
        # No source home: must provide edition; default EE
        AU_EDITION="EE"
        export AU_EDITION
        log_debug "Edition: no source home; defaulting to EE"
    fi
}

# ------------------------------------------------------------------------------
# Function: au_set_group_defaults
# Purpose.: Apply default OS group names when AU_SOURCE_HOME is not set.
#           When AU_SOURCE_HOME is set, unset AU_GROUP_* lines are dropped in
#           the template and AutoUpgrade derives groups from config.c natively.
#           When AU_SOURCE_HOME is not set, all six groups must be explicit.
# Args....: None (reads AU_SOURCE_HOME, AU_GROUP_* from env)
# Returns.: 0; exports AU_GROUP_* if AU_SOURCE_HOME is not set
# Notes...: Only applies to unset variables; caller env wins.
# ------------------------------------------------------------------------------
au_set_group_defaults() {
    if [[ -n "${AU_SOURCE_HOME:-}" ]]; then
        # With source home: leave unset; template lines are dropped by au_render_cfg
        log_debug "Groups: AU_SOURCE_HOME set; unset AU_GROUP_* will be dropped (AutoUpgrade derives)"
        return 0
    fi

    # Without source home: apply defaults for unset variables
    local -a _defaults=(
        "${_AU_DEFAULT_GROUP_OSDBA}"
        "${_AU_DEFAULT_GROUP_OSOPER}"
        "${_AU_DEFAULT_GROUP_OSBACKUPDBA}"
        "${_AU_DEFAULT_GROUP_OSDGDBA}"
        "${_AU_DEFAULT_GROUP_OSKMDBA}"
        "${_AU_DEFAULT_GROUP_OSRACDBA}"
    )
    local _i _var _def
    for _i in "${!_AU_GROUP_VARS[@]}"; do
        _var="${_AU_GROUP_VARS[_i]}"
        _def="${_defaults[_i]}"
        if [[ -z "${!_var:-}" ]]; then
            export "${_var}=${_def}"
            log_debug "Groups: ${_var}=${_def} (preinstall RPM default)"
        else
            log_debug "Groups: ${_var}=${!_var} (caller value)"
        fi
    done
}

# ------------------------------------------------------------------------------
# Function: au_check_group_membership
# Purpose.: Verify the current user is a member of every configured OS group.
#           Reports ERROR for each group the user is not a member of.
#           AutoUpgrade performs the same check (IS_*_GROUP_FAIL); the wrapper
#           checks early to give a clearer error message.
# Args....: None (reads AU_GROUP_* from env)
# Returns.: 0 if all groups OK or all groups empty; exits 1 listing missing ones
# Notes...: Skips empty group variables (e.g. when AU_SOURCE_HOME is set and
#           groups are left unset for AutoUpgrade to derive).
# ------------------------------------------------------------------------------
au_check_group_membership() {
    local _user_groups=""
    _user_groups=$(id -Gn 2>/dev/null || true)
    if [[ -z "${_user_groups}" ]]; then
        log_warn "Cannot determine group membership (id -Gn failed); skipping group check"
        return 0
    fi

    local _fail=false _var _grp
    for _var in "${_AU_GROUP_VARS[@]}"; do
        _grp="${!_var:-}"
        [[ -z "${_grp}" ]] && continue

        local _member_found=false _g
        for _g in ${_user_groups}; do
            [[ "${_g}" == "${_grp}" ]] && _member_found=true && break
        done

        if [[ "${_member_found}" == false ]]; then
            log_error "Group membership check: user '$(id -un)' is not a member of group '${_grp}' (required by ${_var})"
            _fail=true
        else
            log_debug "Group membership: OK - user is member of ${_grp} (${_var})"
        fi
    done

    if [[ "${_fail}" == true ]]; then
        log_error "Add the current user to the required groups and retry."
        exit 1
    fi
}
