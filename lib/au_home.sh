#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Module.....: au_home.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.10.09
# Version....: v0.6.0
# Purpose....: Oracle Home inspection helpers: OS groups from config.c and
#              binary options from libknlopt.a for WP9 (au_gen_config.sh,
#              au_home_verify.sh).
# Notes......: Requires bash 4.2+ (enforced by common.sh at load time).
#              Self-contained: sources only common.sh if not yet loaded.
#              au_lib.sh callers get this module via the au_lib.sh loader line
#              added in WP9; scripts that source au_lib.sh first then
#              source au_home.sh explicitly.
# Reference..: doc/design.md: Config generator (F10), Home naming
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.09 oehrli - initial version for WP9
# ------------------------------------------------------------------------------

# Guard on function existence, not an inheritable variable.
declare -F au_home_read_groups >/dev/null 2>&1 && return 0

# =============================================================================
# OS GROUP PARSING
# =============================================================================

# Known SS_ define names and their AutoUpgrade home_settings key suffixes.
# Order: dba, oper, backupdba, dgdba, kmdba, racdba.
readonly _AU_HOME_GROUP_KEYS=(
    "SS_DBA_GRP:osdba_group"
    "SS_OPER_GRP:osoper_group"
    "SS_BKP_GRP:osbackupdba_group"
    "SS_DGD_GRP:osdgdba_group"
    "SS_KMT_GRP:oskmdba_group"
    "SS_RAC_GRP:osracdba_group"
)

# ------------------------------------------------------------------------------
# Function: au_home_read_groups
# Purpose.: Parse OS group names from <home>/rdbms/lib/config.c SS_*_GRP defines.
#           Mirrors what AutoUpgrade's ParseConfigC does at runtime.
#           AutoUpgrade reads: #define SS_DBA_GRP "dba" (and config.s on some
#           platforms; we support only config.c here, which covers RHEL/OL).
# Args....: $1 - Oracle Home path (reads rdbms/lib/config.c from it)
#                OR direct path to a config.c file
# Returns.: 0 on success; 1 if config.c not found
# Output..: To stdout, one "key=value" line per resolved group, format:
#             osdba_group=dba
#             osoper_group=oper
#             osbackupdba_group=backupdba
#             osdgdba_group=backupdba
#             oskmdba_group=kmdba
#             osracdba_group=racdba
#           Only keys whose define is present in config.c are printed.
#           Missing defines are silently omitted (AutoUpgrade defaults to "dba").
# Notes...: Pure bash: no subshell for string ops; uses grep and bash =~ for
#           the regex capture; portable on BSD grep (no -P).
# ------------------------------------------------------------------------------
au_home_read_groups() {
    local _home="${1:-}"

    if [[ -z "${_home}" ]]; then
        echo "ERROR: au_home_read_groups: Oracle Home path required" >&2
        return 1
    fi

    # Accept either a home path or a direct config.c path
    local _configc
    if [[ -f "${_home}/rdbms/lib/config.c" ]]; then
        _configc="${_home}/rdbms/lib/config.c"
    elif [[ -f "${_home}" ]]; then
        _configc="${_home}"
    else
        echo "ERROR: au_home_read_groups: config.c not found: ${_home}/rdbms/lib/config.c" >&2
        return 1
    fi

    local _pair _define _key _line _val
    for _pair in "${_AU_HOME_GROUP_KEYS[@]}"; do
        _define="${_pair%%:*}"
        _key="${_pair#*:}"

        # Match: #define SS_DBA_GRP "somegroup"
        # BSD grep -E compatible; capture via bash =~
        _line=$(grep -E "^[[:space:]]*#define[[:space:]]+${_define}[[:space:]]" \
            "${_configc}" 2>/dev/null | head -1 || true)

        [[ -z "${_line}" ]] && continue

        # Use a variable for the regex so bash treats unquoted $() as regex,
        # not literal; quoted parentheses in [[ =~ ]] are literal in bash 4+.
        local _re="#define[[:space:]]+${_define}[[:space:]]+\"([^\"]+)\""
        if [[ "${_line}" =~ ${_re} ]]; then
            _val="${BASH_REMATCH[1]}"
            printf '%s=%s\n' "${_key}" "${_val}"
        fi
    done
}

# =============================================================================
# BINARY OPTION INSPECTION
# =============================================================================

# Known binary option object modules (from AU facts 11 / CODE BinaryOption).
# Format: <object_name>:<AU option name>
# kfon.o/kfoff.o -> ASM; kcsm.o -> RAC; jox.o/joxoff.o -> JAVA;
# kzaiang.o -> label security (OLS); kzanang.o -> OLS off
# dNFS is via libnfsodm<ver>.so, not in libknlopt.a - checked separately.
readonly _AU_HOME_BINOPT_MAP=(
    "kfon.o:asm"
    "kcsm.o:rac"
    "jox.o:java"
    "kzaiang.o:ols"
)

# ------------------------------------------------------------------------------
# Function: au_home_list_binopts
# Purpose.: List active binary options from <home>/rdbms/lib/libknlopt.a by
#           running: ar -t <home>/rdbms/lib/libknlopt.a
#           Matches members against _AU_HOME_BINOPT_MAP.
# Args....: $1 - Oracle Home path
# Returns.: 0 on success; 1 if libknlopt.a not found or ar fails
# Output..: To stdout, one "option=on" or "option=off" line per known option.
# Notes...: The caller must have ar on PATH; typically in binutils.
#           AIX uses ar -t -X32_64; we use plain ar -t (Linux/macOS target).
# ------------------------------------------------------------------------------
au_home_list_binopts() {
    local _home="${1:-}"

    if [[ -z "${_home}" ]]; then
        echo "ERROR: au_home_list_binopts: Oracle Home path required" >&2
        return 1
    fi

    local _lib="${_home}/rdbms/lib/libknlopt.a"
    if [[ ! -f "${_lib}" ]]; then
        echo "ERROR: au_home_list_binopts: libknlopt.a not found: ${_lib}" >&2
        return 1
    fi

    if ! command -v ar >/dev/null 2>&1; then
        echo "ERROR: au_home_list_binopts: ar not found on PATH" >&2
        return 1
    fi

    local _members
    _members=$(ar -t "${_lib}" 2>/dev/null) || {
        echo "ERROR: au_home_list_binopts: ar -t failed for ${_lib}" >&2
        return 1
    }

    local _pair _obj _opt _found
    for _pair in "${_AU_HOME_BINOPT_MAP[@]}"; do
        _obj="${_pair%%:*}"
        _opt="${_pair#*:}"
        _found=false
        # Check membership without a subshell loop - use grep on the listing
        if printf '%s\n' "${_members}" | grep -qxF "${_obj}" 2>/dev/null; then
            _found=true
        fi
        if [[ "${_found}" == "true" ]]; then
            printf '%s=on\n' "${_opt}"
        else
            printf '%s=off\n' "${_opt}"
        fi
    done
}

# ------------------------------------------------------------------------------
# Function: au_home_target_name
# Purpose.: Derive the target home path per decision 9:
#             ${oracle_base}/product/<RU in four parts>
#           A second home on the same RU gets a _2, _3 suffix.
# Args....: $1 - oracle_base (e.g. /u00/app/oracle)
#           $2 - RU version, two-part (e.g. 19.32) or four-part (19.32.0.0)
#           $3 - (optional) existing homes list to check for conflicts,
#                one path per line; pass "" to skip suffix logic
# Returns.: 0; prints derived path to stdout
# Notes...: Four-part RU is passed through; two-part is expanded to x.y.0.0.
# ------------------------------------------------------------------------------
au_home_target_name() {
    local _base="${1:-}"
    local _ru="${2:-}"
    local _existing="${3:-}"

    if [[ -z "${_base}" || -z "${_ru}" ]]; then
        echo "ERROR: au_home_target_name: oracle_base and RU required" >&2
        return 1
    fi

    # Expand two-part RU to four parts
    local _ru4
    case "${_ru}" in
        *.*.*.*)
            _ru4="${_ru}"
            ;;
        *.*)
            _ru4="${_ru}.0.0"
            ;;
        *)
            echo "ERROR: au_home_target_name: invalid RU format: ${_ru}" >&2
            return 1
            ;;
    esac

    local _base_path="${_base}/product/${_ru4}"

    # Check for suffix need
    if [[ -z "${_existing}" ]]; then
        printf '%s\n' "${_base_path}"
        return 0
    fi

    # If base path not in existing list, use it directly
    if ! printf '%s\n' "${_existing}" | grep -qxF "${_base_path}" 2>/dev/null; then
        printf '%s\n' "${_base_path}"
        return 0
    fi

    # Find next available suffix
    local _n=2
    while printf '%s\n' "${_existing}" | grep -qxF "${_base_path}_${_n}" 2>/dev/null; do
        _n=$(( _n + 1 ))
    done
    printf '%s_%s\n' "${_base_path}" "${_n}"
}

# =============================================================================
# BINARY TRUST AND ZIP SAFETY
# =============================================================================

# ------------------------------------------------------------------------------
# Function: _au_check_binary_trust
# Purpose.: Refuse to execute a binary from an Oracle home that is not owned by
#           the current user or root (numeric uid), or whose containing directory
#           is group/world-writable.  Dies with a named error on violation.
# Args....: $1 - path to the binary
#           $2 - label (for the error message, e.g. "opatch")
# Returns.: 0 if trusted; exits via die on violation.
# Notes...: Numeric uid is used to avoid locale-dependent name lookups.
# ------------------------------------------------------------------------------
_au_check_binary_trust() {
    local _bin="$1" _label="${2:-binary}"
    local _cur_uid=""
    _cur_uid=$(id -u 2>/dev/null || true)
    [[ -z "${_cur_uid}" ]] && die "${_label}: cannot determine current uid"

    [[ -f "${_bin}" ]] || die "${_label}: not found: ${_bin}"
    [[ -x "${_bin}" ]] || die "${_label}: not executable: ${_bin}"

    # Numeric owner check
    local _bin_uid=""
    _bin_uid=$(stat -c '%u' "${_bin}" 2>/dev/null \
        || stat -f '%u' "${_bin}" 2>/dev/null \
        || true)
    if [[ -z "${_bin_uid}" ]]; then
        die "${_label}: cannot determine owner of ${_bin} (stat failed), refusing"
    fi
    if [[ "${_bin_uid}" != "0" && "${_bin_uid}" != "${_cur_uid}" ]]; then
        die "${_label}: ${_bin} owned by uid ${_bin_uid} (not root=0 or current=${_cur_uid}), refusing"
    fi

    # Directory must not be group/world-writable
    local _dir="${_bin%/*}"
    [[ "${_dir}" == "${_bin}" || -z "${_dir}" ]] && _dir="."
    local _writable=""
    _writable=$(find "${_dir}" -maxdepth 0 \( -perm -g+w -o -perm -o+w \) 2>/dev/null || true)
    if [[ -n "${_writable}" ]]; then
        die "${_label}: directory ${_dir} is group/world-writable, refusing to execute ${_bin}"
    fi
}

# ------------------------------------------------------------------------------
# Function: _au_check_zip_slip
# Purpose.: List zip entries and refuse any starting with '/' or containing '..'.
#           Uses `unzip -Z1` (or `zipinfo -1` as fallback) to list without
#           extracting.  Warns and continues if neither tool can list entries.
# Args....: $1 - path to the zip file
# Returns.: 0 if safe; exits via die on a zip-slip entry.
# ------------------------------------------------------------------------------
_au_check_zip_slip() {
    local _zip="$1"
    local _list_out=""
    if _list_out=$(unzip -Z1 "${_zip}" 2>/dev/null); then
        : # use _list_out from unzip -Z1
    elif _list_out=$(zipinfo -1 "${_zip}" 2>/dev/null); then
        : # use _list_out from zipinfo -1
    else
        log_warn "zip slip check: cannot list entries of ${_zip} (unzip -Z1 / zipinfo -1 unavailable), continuing"
        return 0
    fi

    local _entry
    while IFS= read -r _entry; do
        [[ -z "${_entry}" ]] && continue
        if [[ "${_entry}" == /* ]]; then
            die "zip slip: absolute path entry in ${_zip}: ${_entry}"
        fi
        case "${_entry}" in
            ../*)   die "zip slip: path traversal entry in ${_zip}: ${_entry}" ;;
            */../*) die "zip slip: path traversal entry in ${_zip}: ${_entry}" ;;
            */..)   die "zip slip: path traversal entry in ${_zip}: ${_entry}" ;;
        esac
    done <<< "${_list_out}"
}

# au_home.sh loaded (v0.6.0)
