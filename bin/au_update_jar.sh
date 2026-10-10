#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Script.....: au_update_jar.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Editor.....: Stefan Oehrli
# Date.......: 2026.10.09
# Version....: v0.6.0
# Purpose....: Download or install autoupgrade.jar; compare versions; refuse
#              downgrade unless --force; keep N versioned backups; warn when
#              keystore files are older than the new JAR build date.
# Notes......: - Source: --url (default Oracle URL) or --from FILE/URL
#              - Version compare uses Implementation-Version from MANIFEST.MF
#                (lib/au_tools.sh au_jar_version). Equal = no-op; older =
#                refuse unless --force + --yes; newer = backup + install.
#              - Backup: jar/autoupgrade_<Implementation-Version>.jar;
#                timestamp fallback if version unreadable.
#              - --keep N (default 3): prune oldest backups after install.
#              - --sha256 <hex>: enforce checksum (fleet pinning).
#              - After install: run au_run.sh -version to verify.
#              - Keystore staleness: if AU_KEYSTORE holds wallet files older
#                than the new JAR build date, emit WARN "re-save required".
#              - curl uses https_proxy / no_proxy from the environment.
# Reference..: https://github.com/oehrlis/odb_autoupgrade
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2025.06.17 oehrli - added backup with version or timestamp
# 2026.10.08 oehrli - renamed from update_autoupgrade.sh; set -euo pipefail,
#                     local vars in functions, BSD/GNU sha256 portability
# 2026.10.09 oehrli - WP5: version compare, downgrade guard, --from, --sha256,
#                     --keep, keystore staleness, lib/au_tools.sh
# 2026.10.09 oehrli - port onto foundation: source au_lib.sh, log_*/die from
#                     common.sh, main "$@" structure per bin/template.sh
# ------------------------------------------------------------------------------

set -euo pipefail

# =============================================================================
# BOOTSTRAP
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
: "${SCRIPT_VERSION:=0.6.0}"

SCRIPT_BASE="$(dirname "${SCRIPT_DIR}")"
if [[ -n "${AUTOUPGRADE_BASE:-}" && "${AUTOUPGRADE_BASE}" != "${SCRIPT_BASE}" ]]; then
    echo "WARN: AUTOUPGRADE_BASE env var ignored (derived from script location: ${SCRIPT_BASE})" >&2
fi
export AUTOUPGRADE_BASE="${SCRIPT_BASE}"

if [[ ! -f "${LIB_DIR}/au_lib.sh" ]]; then
    echo "ERROR: Cannot find au_lib.sh in ${LIB_DIR}" >&2
    exit 1
fi
# shellcheck source=../lib/au_lib.sh
. "${LIB_DIR}/au_lib.sh"

# =============================================================================
# SCRIPT DEFAULTS
# =============================================================================

JAR_DIR="${AU_JAR_DIR:-${SCRIPT_BASE}/jar}" # AU_JAR_DIR overrides (tests, shared jar dir)
JAR_FILE="${JAR_DIR}/autoupgrade.jar"
JAR_URL="https://download.oracle.com/otn-pub/otn_software/autoupgrade.jar"
FROM_FILE=""                             # --from <local file or URL>
EXPECTED_SHA256=""                       # --sha256 <hex>
KEEP_N=3                                 # --keep N backups (0 = keep all)
DRY_RUN="false"                          # set by parse_common_opts
FORCE="false"                            # --force to allow downgrade
YES="false"                              # --yes for non-interactive confirm
NO_VERIFY="false"                        # --no-verify: skip post-install check
_JAR_TMP_FILE=""                         # temp download file; removed by cleanup trap

# =============================================================================
# FUNCTIONS
# =============================================================================

# ------------------------------------------------------------------------------
# Function: usage
# Purpose.: Display usage information and exit 0.
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Download or install autoupgrade.jar. Compares Implementation-Version; refuses
downgrade unless --force.

Common options:
  -h, --help        Show this help message
  -V, --version     Show version
  -v, --verbose     Enable verbose output
  -d, --debug       Enable debug output
  -q, --quiet       Quiet mode (WARN level only)
  -n, --dry-run     Show what would be done without making changes

JAR options:
  --from FILE|URL    Source: local JAR file or alternative URL
                     (default: ${JAR_URL})
  --sha256 HEX       Expected SHA-256 (fleet pinning); abort on mismatch
  --keep N           Backup retention: keep N most recent (default: 3; 0=all)
  --force            Allow downgrade (older version than installed)
  --yes              Confirm downgrade without interactive prompt
  --no-verify        Skip post-install au_run.sh -version check

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --from /u01/downloads/autoupgrade.jar --sha256 abc123...
  ${SCRIPT_NAME} --force --yes
  ${SCRIPT_NAME} --keep 5

EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Function: confirm_downgrade
# Purpose.: Ask user to confirm a downgrade when --yes not set.
# Args....: $1 - old version, $2 - new version
# ------------------------------------------------------------------------------
confirm_downgrade() {
    local old_ver="$1" new_ver="$2"
    if [[ "${YES}" == "true" ]]; then return 0; fi
    if [[ -t 0 ]]; then
        local answer
        read -r -p "Downgrade from ${old_ver} to ${new_ver}? [y/N] " answer </dev/tty
        [[ "${answer}" =~ ^[Yy]$ ]] || die "Aborted by user."
    else
        die "Downgrade requires --yes in non-interactive mode."
    fi
}

# ------------------------------------------------------------------------------
# Function: validate_jar
# Purpose.: Check size, ZIP magic, MANIFEST Main-Class and Implementation-Version.
# Args....: $1 - file to validate
# Returns.: 0 on success, exits via die on failure
# ------------------------------------------------------------------------------
validate_jar() {
    local file="$1"
    local size magic manifest_check impl_ver

    size="$(au_file_size "${file}")"
    if (( size < 1048576 )); then
        die "File is too small (${size} bytes < 1 MB) - possibly an HTML error page: ${file}"
    fi

    magic="$(dd if="${file}" bs=2 count=1 2>/dev/null)"
    if [[ "${magic}" != "PK" ]]; then
        die "File is not a valid ZIP/JAR (missing PK magic bytes): ${file}"
    fi

    manifest_check="$(unzip -p "${file}" META-INF/MANIFEST.MF 2>/dev/null || true)"
    [[ "${manifest_check}" == *"Main-Class: oracle.boot.JointBoot"* ]] \
        || die "MANIFEST.MF missing 'Main-Class: oracle.boot.JointBoot' - not an AutoUpgrade JAR: ${file}"

    impl_ver="$(au_jar_version "${file}" 2>/dev/null || true)"
    [[ -n "${impl_ver}" ]] \
        || die "MANIFEST.MF missing Implementation-Version - not an AutoUpgrade JAR: ${file}"
}

# ------------------------------------------------------------------------------
# Function: check_keystore_staleness
# Purpose.: Warn when wallet files predate new JAR build date.
# Args....: $1 - new JAR Implementation-Version
# ------------------------------------------------------------------------------
check_keystore_staleness() {
    local new_version="$1"
    local ks_dir="${AU_KEYSTORE:-${SCRIPT_BASE}/keystore}"
    local ewallet="${ks_dir}/ewallet.p12"

    [[ -f "${ewallet}" ]] || return 0

    if [[ "${new_version}" =~ ^[0-9]+\.[0-9]+\.([0-9]{6})$ ]]; then
        local jar_build_date="${BASH_REMATCH[1]}"
        local ks_mtime
        ks_mtime="$(date -r "${ewallet}" '+%y%m%d' 2>/dev/null || true)"
        if [[ -n "${ks_mtime}" && -n "${jar_build_date}" ]] \
            && (( ks_mtime < jar_build_date )); then
            log_warn "Keystore files predate JAR build date ${jar_build_date} (keystore mtime ${ks_mtime})."
            log_warn "Re-save recommended: au_keystore.sh --resave"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Function: backup_jar
# Purpose.: Create a versioned backup of the installed JAR.
# ------------------------------------------------------------------------------
backup_jar() {
    local ver backup_file timestamp
    ver="$(au_jar_version "${JAR_FILE}" 2>/dev/null || true)"
    if [[ -n "${ver}" ]]; then
        backup_file="${JAR_DIR}/autoupgrade_${ver}.jar"
    else
        timestamp="$(date '+%Y%m%d_%H%M%S')"
        backup_file="${JAR_DIR}/autoupgrade_${timestamp}.jar"
        log_warn "Could not read Implementation-Version from installed JAR; using timestamp backup name."
    fi
    log_info "Backup: ${JAR_FILE} -> ${backup_file}"
    cp "${JAR_FILE}" "${backup_file}"
    chmod 0644 "${backup_file}"
}

# ------------------------------------------------------------------------------
# Function: prune_jar_backups
# Purpose.: Prune old jar backups in JAR_DIR, keeping KEEP_N most recent.
# Args....: $1 - keep count
# ------------------------------------------------------------------------------
prune_jar_backups() {
    local keep="$1"
    [[ "${keep}" -le 0 ]] && return 0

    local count=0 file
    # shellcheck disable=SC2012
    while IFS= read -r file; do
        count=$(( count + 1 ))
    done < <(ls -1t "${JAR_DIR}"/autoupgrade_*.jar 2>/dev/null || true)

    local to_remove=$(( count - keep ))
    (( to_remove <= 0 )) && return 0

    local removed=0
    # shellcheck disable=SC2012
    while IFS= read -r file; do
        if (( removed < to_remove )); then
            log_info "Pruning old backup: ${file}"
            rm -f "${file}"
            removed=$(( removed + 1 ))
        fi
    done < <(ls -1t "${JAR_DIR}"/autoupgrade_*.jar 2>/dev/null | tail -n "${to_remove}" || true)
}

# ------------------------------------------------------------------------------
# Function: parse_args
# Purpose.: Parse command-line arguments.
# ------------------------------------------------------------------------------
parse_args() {
    parse_common_opts "$@"

    local -a remaining=()
    set -- "${ARGS[@]-}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)      FROM_FILE="$2"; shift 2 ;;
            --sha256)    EXPECTED_SHA256="$2"; shift 2 ;;
            --keep)
                [[ "$2" =~ ^[0-9]+$ ]] || die "--keep requires a non-negative integer"
                KEEP_N="$2"; shift 2 ;;
            --force)     FORCE="true"; shift ;;
            --yes)       YES="true"; shift ;;
            --no-verify) NO_VERIFY="true"; shift ;;
            -*)
                die "Unknown option: $1 (use --help for usage)" ;;
            *)
                remaining+=("$1"); shift ;;
        esac
    done
    ARGS=("${remaining[@]+"${remaining[@]}"}")
}

# ------------------------------------------------------------------------------
# Function: validate_inputs
# Purpose.: Resolve source URL/file; check file existence for --from FILE.
# ------------------------------------------------------------------------------
validate_inputs() {
    if [[ -n "${FROM_FILE}" ]]; then
        case "${FROM_FILE}" in
            https://*|http://*)
                SOURCE_URL="${FROM_FILE}"
                SOURCE_FILE=""
                ;;
            *)
                SOURCE_FILE="${FROM_FILE}"
                SOURCE_URL=""
                [[ -f "${SOURCE_FILE}" ]] || die "File not found: ${SOURCE_FILE}"
                ;;
        esac
    else
        SOURCE_URL="${JAR_URL}"
        SOURCE_FILE=""
    fi
}

# ------------------------------------------------------------------------------
# Function: do_work
# Purpose.: Download/copy, validate, compare versions, backup, install.
# ------------------------------------------------------------------------------
do_work() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        if [[ -n "${SOURCE_FILE:-}" ]]; then
            log_warn "DRY-RUN: would install ${SOURCE_FILE} to ${JAR_FILE}"
        else
            log_warn "DRY-RUN: would download ${SOURCE_URL} to ${JAR_FILE}"
        fi
        return 0
    fi

    mkdir -p "${JAR_DIR}"

    # Temp file in same filesystem as JAR_DIR for atomic mv.
    # Use global _JAR_TMP_FILE so the cleanup() EXIT trap can remove it.
    _JAR_TMP_FILE="$(mktemp "${JAR_DIR}/.au_update_XXXXXX")"

    if [[ -n "${SOURCE_FILE:-}" ]]; then
        log_info "Installing from file: ${SOURCE_FILE}"
        cp "${SOURCE_FILE}" "${_JAR_TMP_FILE}"
    else
        log_info "Downloading: ${SOURCE_URL}"
        curl --proto '=https' --proto-redir '=https' -Lf "${SOURCE_URL}" -o "${_JAR_TMP_FILE}" \
            || die "Download failed from: ${SOURCE_URL}"
    fi

    validate_jar "${_JAR_TMP_FILE}"

    local actual_sha=""
    actual_sha="$(au_sha256 "${_JAR_TMP_FILE}" 2>/dev/null || true)"
    log_info "SHA-256: ${actual_sha:-unavailable}"
    log_info "Size: $(au_file_size "${_JAR_TMP_FILE}") bytes"

    if [[ -n "${EXPECTED_SHA256}" ]]; then
        if [[ -z "${actual_sha}" ]]; then
            die "Cannot verify SHA-256 (no sha256sum/shasum). Drop --sha256 or install a sha tool."
        fi
        if [[ "${actual_sha}" != "${EXPECTED_SHA256}" ]]; then
            die "SHA-256 mismatch: expected ${EXPECTED_SHA256}, got ${actual_sha}"
        fi
        log_info "SHA-256 verified."
    fi

    local new_ver old_ver=""
    new_ver="$(au_jar_version "${_JAR_TMP_FILE}" 2>/dev/null || true)"
    [[ -n "${new_ver}" ]] || die "Downloaded file has no Implementation-Version in its manifest - not an AutoUpgrade JAR: ${_JAR_TMP_FILE}"
    [[ -f "${JAR_FILE}" ]] && old_ver="$(au_jar_version "${JAR_FILE}" 2>/dev/null || true)"

    if [[ -n "${old_ver}" ]]; then
        log_info "Version: ${old_ver} -> ${new_ver}"
    else
        log_info "Version: (no existing JAR) -> ${new_ver}"
    fi

    if [[ -n "${old_ver}" && -n "${new_ver}" ]]; then
        local cmp_rc=0
        au_version_compare "${new_ver}" "${old_ver}" && cmp_rc=0 || cmp_rc=$?

        if [[ "${cmp_rc}" -eq 0 ]]; then
            if cmp -s "${_JAR_TMP_FILE}" "${JAR_FILE}"; then
                log_info "Already up to date (${new_ver}). No changes made."
                return 0
            fi
            log_info "Version identical (${new_ver}) but file differs; reinstalling."
        elif [[ "${cmp_rc}" -eq 2 ]]; then
            if [[ "${FORCE}" != "true" ]]; then
                die "Downgrade refused: installed=${old_ver}, new=${new_ver}. Use --force to allow."
            fi
            confirm_downgrade "${old_ver}" "${new_ver}"
            log_warn "Downgrading from ${old_ver} to ${new_ver}"
        fi
    fi

    if [[ -f "${JAR_FILE}" ]]; then
        backup_jar
        prune_jar_backups "${KEEP_N}"
    fi

    mv "${_JAR_TMP_FILE}" "${JAR_FILE}"
    chmod 0644 "${JAR_FILE}"
    log_info "Installed: ${JAR_FILE}"

    if [[ "${NO_VERIFY}" != "true" ]]; then
        local AU_RUN="${SCRIPT_DIR}/au_run.sh"
        if [[ -x "${AU_RUN}" ]]; then
            log_info "Verifying install..."
            "${AU_RUN}" -version 2>&1 | head -5 || \
                log_warn "au_run.sh -version returned non-zero; JAR may need compatible Java."
        fi
    fi

    check_keystore_staleness "${new_ver}"
}

# ------------------------------------------------------------------------------
# Function: cleanup
# Purpose.: Cleanup function called on EXIT trap.
# ------------------------------------------------------------------------------
cleanup() {
    [[ -n "${_JAR_TMP_FILE}" ]] && rm -f "${_JAR_TMP_FILE}"
    log_debug "Cleanup completed"
}

# =============================================================================
# MAIN
# =============================================================================

# Global source path variables (used by validate_inputs/do_work)
SOURCE_URL=""
SOURCE_FILE=""

main() {
    setup_error_handling

    au_load_config

    parse_args "$@"

    validate_inputs

    do_work

    log_debug "${SCRIPT_NAME} completed successfully"
}

main "$@"
# - EOF ------------------------------------------------------------------------
