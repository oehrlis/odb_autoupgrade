#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Script.....: au_keystore.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Editor.....: Stefan Oehrli
# Date.......: 2026.10.09
# Version....: v0.6.1
# Purpose....: Manage the AutoUpgrade MOS keystore: create, check, re-save, and
#              back up the ewallet.p12 / cwallet.sso wallet pair.
# Notes......: Operations:
#              --create (default): drive -patch -load_password via expect
#              --check:  non-interactive permission/owner/symlink/key pair check
#              --resave: backup + console "group mos" + "save" (recreates PKEY1/2)
#              --backup: tar the keystore directory to a 0600 file in a 0700
#                        backup directory outside logs/ and patches/
#
#              Security properties:
#              - Passwords passed only via expect env vars, never on argv.
#              - The expect script unsets EXPECT_MOS_PASS and EXPECT_KS_PASS
#                before spawning au_run.sh/java (JVM never inherits them).
#              - --mos-pass and --ks-pass require --insecure-argv.
#              - KS_PASS does not silently default to MOS_PASS.
#              - umask 077 before creating any credential files.
#              - Keystore directory created with mode 0700.
#              - Symlinked directories or wallet files refused.
#              - Auto-login modes (AutoUpgrade 26.x KSM_AUTO_LOGIN_PROMPT):
#                  YES    = local auto-login, bound to host + OS user (default)
#                  SHARED = portable auto-login (WARN emitted when chosen)
#                  NO     = no auto-login; password required each time
#              - --yes required when overwriting existing wallet (--force).
# Reference..: https://github.com/oehrlis/odb_autoupgrade
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.08 oehrli - initial version with --create; spawn via au_run.sh;
#                     --auto-login, security hardening (insecure-argv guard,
#                     umask 077, mkdir 700, symlink refusal, KS_PASS no default)
# 2026.10.09 oehrli - WP6: --check, --resave, --backup, etc/au_keystore.cfg
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
: "${SCRIPT_VERSION:=0.6.1}"

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

OPERATION="create"                          # --create|--check|--resave|--backup
AU_CFG="etc/au_keystore.cfg"               # minimal AU config for -load_password
WORKDIR="${AU_KEYSTORE:-$(pwd)}"            # wallet files location
MOS_USER="${MOS_USER:-}"                    # --mos-user, MOS_USER env, or prompt
MOS_PASS="${MOS_PASS:-}"                    # --mos-pass-file, MOS_PASS env, or prompt
KS_PASS="${KS_PASS:-}"                      # --ks-pass-file, KS_PASS env, or prompt
FORCE="false"                               # --force to overwrite existing wallet
AUTO_LOGIN="YES"                            # --auto-login YES|SHARED|NO
INSECURE_ARGV="false"                       # --insecure-argv to allow pass on argv
YES="false"                                 # --yes for non-interactive overwrite
BACKUP_ROOT=""                              # --backup-dir <dir>
DRY_RUN="false"                             # --dry-run (parse_common_opts)

# =============================================================================
# FUNCTIONS
# =============================================================================

# ------------------------------------------------------------------------------
# Function: usage
# Purpose.: Display usage information and exit 0.
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [--create|--check|--resave|--backup] [options]

Manage the AutoUpgrade MOS keystore (ewallet.p12 + cwallet.sso).

Operations (default: --create):
  --create          Create keystore via au_run.sh -patch -load_password
  --check           Check permissions, owner, symlinks, key pair (non-interactive)
  --resave          Backup then re-save keystore (recreates PKEY1/PKEY2)
  --backup          Backup keystore directory to a 0600 tar.gz in a 0700 dir

Common options:
  -h, --help        Show this help message
  -V, --version     Show version
  -v, --verbose     Enable verbose output
  -d, --debug       Enable debug output
  -q, --quiet       Quiet mode (WARN level only)
  -n, --dry-run     Show what would be done without making changes

Keystore options:
  --workdir DIR            Keystore directory (default: AU_KEYSTORE or cwd)
  --cfg PATH               AU config file for --create/--resave
                           (default: etc/au_keystore.cfg)
  --mos-user USER          MOS username (email; also MOS_USER env)
  --mos-pass-file FILE     Read MOS password from file (preferred)
  --ks-pass-file FILE      Read keystore password from file (preferred)
  --auto-login MODE        YES|SHARED|NO (default YES)
  --force                  Overwrite existing wallet (--create)
  --yes                    Skip confirmation when overwriting with --force
  --backup-dir DIR         Custom backup root (default: <workdir>_backup)
  --insecure-argv          Allow --mos-pass / --ks-pass (visible in ps)
  --mos-pass PASS          MOS password on argv (requires --insecure-argv)
  --ks-pass PASS           Keystore password on argv (requires --insecure-argv)

Password precedence (highest first):
  1. --mos-pass-file / --ks-pass-file
  2. MOS_PASS / KS_PASS environment variables
  3. --mos-pass / --ks-pass (only with --insecure-argv)
  4. Interactive prompt (when stdin is a TTY)

EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Function: check_pass_file
# Purpose.: Validate a password file: must exist, be owned by current user,
#           and not be group/world readable.
# Args....: $1 - file path, $2 - label for error messages
# Returns.: 0 on pass, exits via die on failure
# ------------------------------------------------------------------------------
check_pass_file() {
    local file="$1" label="$2"
    [[ -f "${file}" ]] || die "${label}: file not found: ${file}"
    local file_perms file_uid
    file_perms="$(au_file_perms "${file}")"
    file_uid="$(au_file_owner_uid "${file}")"
    if [[ -n "${file_uid}" && "${file_uid}" != "$(id -u)" ]]; then
        die "${label}: file not owned by current user (UID=${file_uid}): ${file}"
    fi
    # Readable bit (4) in group or world position makes the field >= 4
    local g_bit w_bit
    g_bit="${file_perms: -2:1}"
    w_bit="${file_perms: -1:1}"
    if [[ "${g_bit}" =~ [4-7] || "${w_bit}" =~ [4-7] ]]; then
        die "${label}: file is group or world readable (${file_perms}): ${file}"
    fi
}

# ------------------------------------------------------------------------------
# Function: trimnl
# Purpose.: Read a file and strip trailing CR/LF without a subshell pipeline.
# Args....: $1 - file path
# Stdout..: file content without trailing newlines
# ------------------------------------------------------------------------------
trimnl() {
    local content
    content="$(cat "$1")"
    while [[ "${content}" == *$'\n' || "${content}" == *$'\r' ]]; do
        content="${content%$'\n'}"
        content="${content%$'\r'}"
    done
    printf '%s' "${content}"
}

# ------------------------------------------------------------------------------
# Function: confirm_overwrite
# Purpose.: Ask user to confirm an overwrite when --yes is not set.
# Args....: $1 - prompt string
# Returns.: 0 on confirm, exits via die on refusal
# ------------------------------------------------------------------------------
confirm_overwrite() {
    local prompt="$1"
    if [[ "${YES}" == "true" ]]; then return 0; fi
    if [[ -t 0 ]]; then
        local answer
        read -r -p "${prompt} [y/N] " answer </dev/tty
        [[ "${answer}" =~ ^[Yy]$ ]] || die "Aborted by user."
    else
        die "Overwrite requires --yes in non-interactive mode."
    fi
}

# ------------------------------------------------------------------------------
# Function: run_create
# Purpose.: Drive the expect-based keystore creation flow (--create).
# ------------------------------------------------------------------------------
run_create() {
    local ewallet="${WORKDIR%/}/ewallet.p12"
    local cwallet="${WORKDIR%/}/cwallet.sso"

    [[ -L "${ewallet}" ]] && die "ewallet.p12 is a symlink, refusing: ${ewallet}"
    [[ -L "${cwallet}" ]] && die "cwallet.sso is a symlink, refusing: ${cwallet}"

    if [[ "${FORCE}" != "true" && ( -f "${ewallet}" || -f "${cwallet}" ) ]]; then
        log_warn "Wallet already exists in ${WORKDIR} (use --force to recreate). Skipping."
        exit 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_warn "DRY-RUN: would run au_run.sh -config ${AU_CFG} -patch -load_password"
        return 0
    fi

    if [[ "${FORCE}" == "true" && ( -f "${ewallet}" || -f "${cwallet}" ) ]]; then
        confirm_overwrite "Overwrite existing wallet in ${WORKDIR}?"
        local bak
        bak="$(au_keystore_backup "${WORKDIR}" "${BACKUP_ROOT}")" \
            || die "Backup failed before overwrite; aborting. Use --backup-dir to set a writable backup location."
        log_info "Backup: ${bak}"
    fi

    if [[ "${AUTO_LOGIN}" == "SHARED" ]]; then
        log_warn "--auto-login SHARED: portable keystore - anyone with the files can use MOS credentials"
    fi

    umask 077

    (
        cd "${WORKDIR}"
        local exp_log_user
        exp_log_user="$([[ "${LOG_LEVEL:-WARN}" == "WARN" || "${LOG_LEVEL:-WARN}" == "ERROR" ]] && printf '0' || printf '1')"

        AU_KEYSTORE="${WORKDIR}" \
        EXPECT_AU_RUN="${AU_RUN}" \
        EXPECT_AU_CFG="${AU_CFG}" \
        EXPECT_MOS_USER="${MOS_USER}" \
        EXPECT_MOS_PASS="${MOS_PASS}" \
        EXPECT_KS_PASS="${KS_PASS}" \
        EXPECT_AUTO_LOGIN="${AUTO_LOGIN}" \
        EXP_LOG_USER="${exp_log_user}" \
        expect <<'EXPECTEOF'
    set timeout 120
    log_user $env(EXP_LOG_USER)

    set au_run    $env(EXPECT_AU_RUN)
    set cfg       $env(EXPECT_AU_CFG)
    set user      $env(EXPECT_MOS_USER)
    set pass      $env(EXPECT_MOS_PASS)
    set kspass    $env(EXPECT_KS_PASS)
    set autologin $env(EXPECT_AUTO_LOGIN)

    unset env(EXPECT_MOS_PASS)
    unset env(EXPECT_KS_PASS)

    set user_added 0

    spawn bash $au_run -config $cfg -patch -load_password

    expect {
        "Enter password:"         { send -- "$kspass\r"; exp_continue }
        "Enter password again:"   { send -- "$kspass\r"; exp_continue }
        "Enter wallet password:"  { send -- "$kspass\r"; exp_continue }

        -re {^MOS>\s*$} {
            if { $user_added == 0 } {
                send -- "add -user $user\r"
                set user_added 1
            } else {
                send -- "exit\r"
            }
            exp_continue
        }

        "Enter your secret/Password:"    { send -- "$pass\r"; exp_continue }
        "Re-enter your secret/Password:" { send -- "$pass\r"; exp_continue }

        -re {Save the AutoUpgrade Patching keystore before exiting.*} {
            send -- "YES\r"; exp_continue
        }

        -re {Select auto-login mode.*\[(YES|NO|SHARED)\].*} {
            send -- "$autologin\r"; exp_continue
        }

        -re {Convert the AutoUpgrade Patching keystore to auto-login.*} {
            send -- "YES\r"; exp_continue
        }

        eof {
            catch wait result
            exit [lindex $result 3]
        }
        timeout { puts "ERROR: timed out during keystore creation"; exit 1 }
    }
EXPECTEOF
    )

    [[ -f "${ewallet}" ]] || die "Keystore creation finished but ewallet.p12 not found in ${WORKDIR}"
    [[ -f "${cwallet}" ]] && chmod 600 "${cwallet}"
    chmod 600 "${ewallet}"
    log_info "Keystore created in ${WORKDIR}"
}

# ------------------------------------------------------------------------------
# Function: run_check
# Purpose.: Non-interactive permission/key-pair check (--check).
# ------------------------------------------------------------------------------
run_check() {
    local jar_file="${SCRIPT_BASE}/jar/autoupgrade.jar"
    au_keystore_check "${WORKDIR}" "${jar_file}"
}

# ------------------------------------------------------------------------------
# Function: run_resave
# Purpose.: Backup + re-save via "group mos" + "save" (--resave).
# ------------------------------------------------------------------------------
run_resave() {
    local ewallet="${WORKDIR%/}/ewallet.p12"
    [[ -f "${ewallet}" ]] || die "No ewallet.p12 found in ${WORKDIR}. Run --create first."

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "DRY-RUN: would backup ${WORKDIR} then run au_run.sh -patch -load_password (group mos + save)"
        return 0
    fi

    local bak
    bak="$(au_keystore_backup "${WORKDIR}" "${BACKUP_ROOT}")" \
        || die "Backup failed; aborting resave."
    log_info "Backup: ${bak}"

    if [[ "${AUTO_LOGIN}" == "SHARED" ]]; then
        log_warn "--auto-login SHARED: portable keystore - anyone with the files can use MOS credentials"
    fi

    umask 077

    (
        cd "${WORKDIR}"
        local exp_log_user
        exp_log_user="$([[ "${LOG_LEVEL:-WARN}" == "WARN" || "${LOG_LEVEL:-WARN}" == "ERROR" ]] && printf '0' || printf '1')"

        AU_KEYSTORE="${WORKDIR}" \
        EXPECT_AU_RUN="${AU_RUN}" \
        EXPECT_AU_CFG="${AU_CFG}" \
        EXPECT_KS_PASS="${KS_PASS}" \
        EXPECT_AUTO_LOGIN="${AUTO_LOGIN}" \
        EXP_LOG_USER="${exp_log_user}" \
        expect <<'EXPECTEOF'
    set timeout 120
    log_user $env(EXP_LOG_USER)

    set au_run    $env(EXPECT_AU_RUN)
    set cfg       $env(EXPECT_AU_CFG)
    set kspass    $env(EXPECT_KS_PASS)
    set autologin $env(EXPECT_AUTO_LOGIN)

    unset env(EXPECT_KS_PASS)

    spawn bash $au_run -config $cfg -patch -load_password

    expect {
        "Enter password:"         { send -- "$kspass\r"; exp_continue }
        "Enter password again:"   { send -- "$kspass\r"; exp_continue }
        "Enter wallet password:"  { send -- "$kspass\r"; exp_continue }

        -re {^MOS>\s*$} {
            send -- "group mos\r"; exp_continue
        }

        -re {^MOS mos>\s*$} {
            send -- "save\r"; exp_continue
        }

        -re {Save the AutoUpgrade Patching keystore before exiting.*} {
            send -- "YES\r"; exp_continue
        }

        -re {Select auto-login mode.*\[(YES|NO|SHARED)\].*} {
            send -- "$autologin\r"; exp_continue
        }

        -re {Convert the AutoUpgrade Patching keystore to auto-login.*} {
            send -- "YES\r"; exp_continue
        }

        eof {
            catch wait result
            exit [lindex $result 3]
        }
        timeout { puts "ERROR: timed out during keystore re-save"; exit 1 }
    }
EXPECTEOF
    )

    log_info "Keystore re-saved in ${WORKDIR}"
}

# ------------------------------------------------------------------------------
# Function: run_backup
# Purpose.: Back up the keystore directory (--backup).
# ------------------------------------------------------------------------------
run_backup() {
    [[ -d "${WORKDIR}" ]] || die "Keystore directory not found: ${WORKDIR}"
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "DRY-RUN: would backup ${WORKDIR} to ${BACKUP_ROOT:-<workdir>_backup}"
        return 0
    fi
    local bak
    bak="$(au_keystore_backup "${WORKDIR}" "${BACKUP_ROOT}")" \
        || die "Backup failed."
    log_info "Backup created: ${bak}"
}

# ------------------------------------------------------------------------------
# Function: parse_args
# Purpose.: Parse command-line arguments.
# ------------------------------------------------------------------------------
parse_args() {
    parse_common_opts "$@"

    local -a remaining=()
    set -- "${ARGS[@]-}"

    local _arg_mos_pass="" _arg_ks_pass=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --create)        OPERATION="create"; shift ;;
            --check)         OPERATION="check"; shift ;;
            --resave)        OPERATION="resave"; shift ;;
            --backup)        OPERATION="backup"; shift ;;
            --workdir)       WORKDIR="$2"; shift 2 ;;
            --cfg)           AU_CFG="$2"; shift 2 ;;
            --mos-user)      MOS_USER="$2"; shift 2 ;;
            --mos-pass-file) check_pass_file "$2" "--mos-pass-file"; MOS_PASS="$(trimnl "$2")"; shift 2 ;;
            --ks-pass-file)  check_pass_file "$2" "--ks-pass-file";  KS_PASS="$(trimnl "$2")"; shift 2 ;;
            --backup-dir)    BACKUP_ROOT="$2"; shift 2 ;;
            --mos-pass)      _arg_mos_pass="$2"; shift 2 ;;
            --ks-pass)       _arg_ks_pass="$2"; shift 2 ;;
            --auto-login)
                case "${2:-}" in
                    YES|SHARED|NO) AUTO_LOGIN="$2" ;;
                    *) die "--auto-login must be YES, SHARED, or NO" ;;
                esac
                shift 2 ;;
            --au-jar)
                log_warn "--au-jar ignored since v0.5.0 (au_run.sh uses jar/autoupgrade.jar)"
                shift 2 ;;
            --insecure-argv) INSECURE_ARGV="true"; shift ;;
            --force)         FORCE="true"; shift ;;
            --yes)           YES="true"; shift ;;
            -*)
                die "Unknown option: $1 (use --help for usage)" ;;
            *)
                remaining+=("$1"); shift ;;
        esac
    done
    ARGS=("${remaining[@]+"${remaining[@]}"}")

    if [[ -n "${_arg_mos_pass}" || -n "${_arg_ks_pass}" ]]; then
        if [[ "${INSECURE_ARGV}" != "true" ]]; then
            die "--mos-pass / --ks-pass require --insecure-argv. Preferred: --mos-pass-file or MOS_PASS env."
        fi
        [[ -n "${_arg_mos_pass}" ]] && MOS_PASS="${_arg_mos_pass}"
        [[ -n "${_arg_ks_pass}" ]]  && KS_PASS="${_arg_ks_pass}"
    fi
}

# ------------------------------------------------------------------------------
# Function: validate_inputs
# Purpose.: Validate required inputs and resolve paths.
# ------------------------------------------------------------------------------
validate_inputs() {
    # Normalise trailing slashes
    while [[ "${WORKDIR}" == */ && "${WORKDIR}" != "/" ]]; do WORKDIR="${WORKDIR%/}"; done

    # Resolve to absolute path so backup directory is always computed outside the keystore
    if [[ "${WORKDIR}" != /* ]]; then
        WORKDIR="$(pwd)/${WORKDIR}"
    fi
    # Resolve . and .. so the keystore name is never "." or ".."; logical
    # resolution keeps a symlinked WORKDIR visible for the symlink refusal below
    if [[ -d "${WORKDIR}" ]]; then
        WORKDIR="$(cd -L -- "${WORKDIR}" && pwd -L)" || die "Cannot resolve WORKDIR: ${WORKDIR}"
    fi
    case "${WORKDIR##*/}" in
        ""|.|..) die "WORKDIR must name a keystore directory, not ${WORKDIR}" ;;
    esac

    # --check and --backup do not need au_run.sh or expect
    if [[ "${OPERATION}" == "check" || "${OPERATION}" == "backup" ]]; then
        return 0
    fi

    AU_RUN="${SCRIPT_DIR}/au_run.sh"
    require_cmd expect
    [[ -x "${AU_RUN}" ]] || die "au_run.sh not found or not executable at ${AU_RUN}"

    # Create WORKDIR with restricted permissions
    if [[ ! -d "${WORKDIR}" ]]; then
        mkdir -p "${WORKDIR}" || die "Cannot create WORKDIR: ${WORKDIR}"
        chmod 700 "${WORKDIR}"
    fi
    [[ -L "${WORKDIR}" ]] && die "WORKDIR is a symlink, refusing: ${WORKDIR}"

    # Resolve AU_CFG relative to SCRIPT_BASE if not absolute
    [[ "${AU_CFG}" = /* ]] || AU_CFG="${SCRIPT_BASE}/${AU_CFG}"
    [[ -f "${AU_CFG}" ]] || die "AU config not found: ${AU_CFG}"

    # Passwords for --create
    if [[ "${OPERATION}" == "create" ]]; then
        [[ -n "${MOS_USER}" ]] || die "--mos-user (or MOS_USER env) is required for --create"
        if [[ -z "${MOS_PASS}" ]]; then
            if [[ -t 0 ]]; then
                read -rs -p "MOS Password: " MOS_PASS </dev/tty; echo >&2
            else
                die "MOS password not set. Use --mos-pass-file, MOS_PASS env, or run interactively."
            fi
        fi
    fi

    # KS_PASS for --create and --resave
    if [[ -z "${KS_PASS}" ]]; then
        if [[ -t 0 ]]; then
            read -rs -p "Keystore Password: " KS_PASS </dev/tty; echo >&2
        else
            die "Keystore password not set. Use --ks-pass-file, KS_PASS env, or run interactively."
        fi
    fi
}

# ------------------------------------------------------------------------------
# Function: do_work
# Purpose.: Dispatch to operation-specific function.
# ------------------------------------------------------------------------------
do_work() {
    case "${OPERATION}" in
        create) run_create ;;
        check)  run_check ;;
        resave) run_resave ;;
        backup) run_backup ;;
        *) die "Unknown operation: ${OPERATION}" ;;
    esac
}

# ------------------------------------------------------------------------------
# Function: cleanup
# Purpose.: Cleanup function called on EXIT trap.
# ------------------------------------------------------------------------------
cleanup() {
    log_debug "Cleanup completed"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Unexport password variables immediately so no child process inherits them.
    # This covers all operations (--check, --backup, --create, --resave).
    export -n MOS_PASS KS_PASS 2>/dev/null || true

    setup_error_handling

    au_load_config

    parse_args "$@"

    validate_inputs

    do_work

    log_debug "${SCRIPT_NAME} completed successfully"
}

main "$@"
# - EOF ------------------------------------------------------------------------
