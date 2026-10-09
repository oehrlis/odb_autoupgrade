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

    # Step 3: Level 2a - profile (WP13 placeholder)
    log_debug "Config level-2a: profile not active (WP13 placeholder)"

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
# Purpose.: Read AU_PATCH from the pin file if not already set.
# Notes...: Pin file is parsed line-by-line (never sourced).
#           Security: refuse symlink, numeric owner check, refuse g/o-writable.
#           Only AU_PATCH=<value> accepted; value must match ^[A-Za-z0-9_.,:-]+$
# ------------------------------------------------------------------------------
au_read_pin() {
    _au_patch_pinned=false
    [[ -n "${AU_PATCH:-}" ]] && return 0

    local _patch_env="${AU_DOWNLOAD_FOLDER}/au_patch.env"
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
                | sed -e 's/^\$[{]//' -e 's/[}]$//'
            grep -oE '\$[A-Za-z_][A-Za-z0-9_]*' <<< "${filtered}" \
                | sed 's/^\$//'
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
