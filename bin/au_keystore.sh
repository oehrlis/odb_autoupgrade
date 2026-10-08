#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Name.......: au_keystore.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Editor.....: Stefan Oehrli
# Date.......: 2026.10.08
# Version....: v0.5.0
# Purpose....: Create (or skip if present) an AutoUpgrade MOS keystore using
#              -patch -load_password via au_run.sh. Drives the interactive CLI
#              via expect to produce ewallet.p12 + cwallet.sso.
# Notes......: - Spawns au_run.sh (same bin dir) so Java, proxy, and truststore
#                resolution all apply via au_run.sh / au_lib.sh.
#              - Passwords are passed only via expect environment variables,
#                never on a command line visible in ps output.
#              - The expect script unsets EXPECT_MOS_PASS and EXPECT_KS_PASS
#                from the child environment before spawning au_run.sh/java so
#                that those variables are never inherited by the JVM process.
#              - --mos-pass and --ks-pass are only allowed together with
#                --insecure-argv; otherwise use --mos-pass-file / --ks-pass-file,
#                the MOS_PASS / KS_PASS environment variables, or interactive
#                'read -rs' (when stdin is a TTY).
#              - KS_PASS does not silently default to MOS_PASS; if unset and
#                stdin is a TTY the user is prompted; otherwise ERROR.
#              - umask 077 is applied before creating any credential files.
#              - The keystore directory is created with mode 0700 (mkdir -m 700).
#              - Symlinked keystore directories or wallet files are refused.
#              - Auto-login modes (AutoUpgrade 26.x KSM_AUTO_LOGIN_PROMPT):
#                  YES    = local auto-login, bound to host + OS user.
#                           A copy moved to another host fails with
#                           "Loading auto-login keystore failed" (TDE104).
#                  SHARED = portable auto-login; anyone with the files can use
#                           the MOS credentials (lower security). A WARN is
#                           emitted when this mode is chosen.
#                  NO     = no auto-login; password required each time; does not
#                           work with -noconsole.
#                Older JARs show "Convert ... to auto-login" instead; that
#                branch always answers YES for backward compatibility.
#              - MOS credentials are added via "group mos" + "add -user <user>"
#                (not -no_password); the device-flow path creates no key pair
#                and cannot be used for gold image downloads.
# Reference..: https://github.com/oehrlis/odb_autoupgrade
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.08 oehrli - renamed from create_mos_keystore.sh; spawn via au_run.sh,
#                     add --auto-login option for AutoUpgrade 26.x prompt
# 2026.10.08 oehrli - security: --insecure-argv guard for --mos-pass/--ks-pass,
#                     unset env vars before spawn in expect, umask 077,
#                     mkdir -m 700, symlink refusal, KS_PASS no silent default,
#                     MOS_USER from env respected, fix trimnl to use printf
# ------------------------------------------------------------------------------

set -euo pipefail

# - Default Values -------------------------------------------------------------
SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")
SCRIPT_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

AU_CFG="etc/test.cfg"                    # minimal/any valid AU config file
WORKDIR="$(pwd)"                         # where wallet files will be written
MOS_USER="${MOS_USER:-}"                 # --mos-user, MOS_USER env, or prompt
MOS_PASS="${MOS_PASS:-}" # --mos-pass-file, MOS_PASS env, or prompt
KS_PASS="${KS_PASS:-}" # --ks-pass-file, KS_PASS env, or prompt
FORCE="false"                            # --force to overwrite existing wallet
QUIET="false"                            # --quiet to suppress expect echo
AUTO_LOGIN="YES"                         # --auto-login YES|SHARED|NO (default YES)
INSECURE_ARGV="false"                    # --insecure-argv to allow pass on argv
# - EOF Default Values ---------------------------------------------------------

# - Functions ------------------------------------------------------------------

usage() {
    cat >&2 <<EOF
Usage: ${SCRIPT_NAME} [options]

Create an AutoUpgrade MOS keystore (ewallet.p12 + cwallet.sso) using
au_run.sh -config <cfg> -patch -load_password. Requires expect.

Options:
  --workdir DIR            Working dir; wallet files will be created here
  --cfg PATH               Path to AU config file (default: etc/test.cfg)
  --mos-user USER          MOS username (email; also read from MOS_USER env)
  --mos-pass-file FILE     Read MOS password from file/secret (preferred)
  --ks-pass-file FILE      Read keystore password from file/secret (preferred)
  --auto-login MODE        Auto-login mode for AutoUpgrade 26.x [YES|SHARED|NO]
                           YES    = local auto-login, bound to host + OS user (default)
                           SHARED = portable auto-login (WARN: less secure)
                           NO     = no auto-login; password required each time
  --force                  Recreate wallet even if files exist
  --quiet                  Reduce expect output
  --insecure-argv          Allow --mos-pass and --ks-pass (visible in ps, shell history)
  --mos-pass PASS          MOS password on argv (requires --insecure-argv)
  --ks-pass PASS           Keystore password on argv (requires --insecure-argv)
  --help                   Show this help and exit

Password precedence (highest first):
  1. --mos-pass-file / --ks-pass-file (read from file, stripped of trailing CR/LF)
  2. MOS_PASS / KS_PASS environment variables
  3. --mos-pass / --ks-pass (only with --insecure-argv)
  4. Interactive prompt (when stdin is a TTY)

Examples:
  ${SCRIPT_NAME} --workdir /u00/app/oracle/autoupgrade/keystore \\
    --cfg /u00/app/oracle/autoupgrade/etc/dummy.config \\
    --mos-user you@example.com --mos-pass-file /run/secrets/mos_pass \\
    --ks-pass-file /run/secrets/ks_pass
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

# Read a file and strip trailing newlines/carriage returns without a subshell
# pipeline. Uses printf '%s' to avoid echo's interpretation of backslash
# sequences and to suppress the implicit trailing newline.
trimnl() {
    local content
    content="$(cat "$1")"
    while [[ "${content}" == *$'\n' || "${content}" == *$'\r' ]]; do
        content="${content%$'\n'}"
        content="${content%$'\r'}"
    done
    printf '%s' "${content}"
}
# - EOF Functions --------------------------------------------------------------

# - Parse Parameters -----------------------------------------------------------
# Collect --insecure-argv first so it can gate --mos-pass / --ks-pass
_ARG_MOS_PASS=""
_ARG_KS_PASS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workdir)       WORKDIR="$2"; shift 2 ;;
        --cfg)           AU_CFG="$2"; shift 2 ;;
        --mos-user)      MOS_USER="$2"; shift 2 ;;
        --mos-pass-file) MOS_PASS="$(trimnl "$2")"; shift 2 ;;
        --ks-pass-file)  KS_PASS="$(trimnl "$2")"; shift 2 ;;
        --mos-pass)
            # Deferred: only accepted with --insecure-argv
            _ARG_MOS_PASS="$2"; shift 2 ;;
        --ks-pass)
            # Deferred: only accepted with --insecure-argv
            _ARG_KS_PASS="$2"; shift 2 ;;
        --auto-login)
            case "${2:-}" in
                YES|SHARED|NO) AUTO_LOGIN="$2" ;;
                *) die "--auto-login must be YES, SHARED, or NO" ;;
            esac
            shift 2 ;;
        --au-jar)
            echo "WARN: --au-jar is ignored since v0.5.0 (au_run.sh uses jar/autoupgrade.jar)" >&2
            shift 2 ;;
        --insecure-argv) INSECURE_ARGV="true"; shift ;;
        --force)  FORCE="true"; shift ;;
        --quiet)  QUIET="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

# Apply deferred argv passwords only when --insecure-argv was given
if [[ -n "${_ARG_MOS_PASS}" || -n "${_ARG_KS_PASS}" ]]; then
    if [[ "${INSECURE_ARGV}" != "true" ]]; then
        die "--mos-pass / --ks-pass require --insecure-argv." \
            $'\n'"       Preferred alternatives:" \
            $'\n'"         --mos-pass-file FILE  (read from file/secret)" \
            $'\n'"         MOS_PASS / KS_PASS env vars" \
            $'\n'"         interactive prompt (stdin TTY)"
    fi
    [[ -n "${_ARG_MOS_PASS}" ]] && MOS_PASS="${_ARG_MOS_PASS}"
    [[ -n "${_ARG_KS_PASS}" ]]  && KS_PASS="${_ARG_KS_PASS}"
fi
# MOS_PASS / KS_PASS from the environment were picked up in Default Values;
# anything still empty is prompted for below
# - EOF Parse Parameters -------------------------------------------------------

# - Sanity Checks --------------------------------------------------------------
AU_RUN="${SCRIPT_BIN_DIR}/au_run.sh"
[[ -x "${AU_RUN}" ]] || die "au_run.sh not found or not executable at ${AU_RUN}"
command -v expect >/dev/null 2>&1 || die "expect not found (dnf/yum/apt install expect)"

# Normalise trailing slashes so the symlink check below sees the link itself
while [[ "${WORKDIR}" == */ && "${WORKDIR}" != "/" ]]; do WORKDIR="${WORKDIR%/}"; done

# Create WORKDIR with restricted permissions.
# -p with -m only applies to the deepest dir on some platforms; use chmod after.
if [[ ! -d "${WORKDIR}" ]]; then
    mkdir -p "${WORKDIR}" || die "Cannot create WORKDIR: ${WORKDIR}"
    chmod 700 "${WORKDIR}"
fi

# Refuse symlinked WORKDIR
if [[ -L "${WORKDIR}" ]]; then
    die "WORKDIR is a symlink, refusing to use: ${WORKDIR}"
fi

# Resolve AU_CFG relative to WORKDIR if it is a relative path
[[ "${AU_CFG}" = /* ]] || AU_CFG="${WORKDIR%/}/${AU_CFG}"
[[ -f "${AU_CFG}" ]] || die "AU config not found: ${AU_CFG}"

[[ -n "${MOS_USER}" ]] || die "--mos-user (or MOS_USER env) is required"

# Resolve MOS_PASS: prompt if TTY and not yet set
if [[ -z "${MOS_PASS}" ]]; then
    if [[ -t 0 ]]; then
        read -rs -p "MOS Password: " MOS_PASS </dev/tty
        echo >&2
    else
        die "MOS password not set. Use --mos-pass-file, MOS_PASS env var, or run interactively."
    fi
fi

# Resolve KS_PASS: prompt if TTY, but do NOT silently default to MOS_PASS
if [[ -z "${KS_PASS}" ]]; then
    if [[ -t 0 ]]; then
        read -rs -p "Keystore Password: " KS_PASS </dev/tty
        echo >&2
    else
        die "Keystore password not set. Use --ks-pass-file, KS_PASS env var, or run interactively. (Does not default to MOS password.)"
    fi
fi

EWL="${WORKDIR%/}/ewallet.p12"
CWL="${WORKDIR%/}/cwallet.sso"

# Refuse symlinked wallet files
if [[ -L "${EWL}" ]]; then
    die "ewallet.p12 is a symlink, refusing to use: ${EWL}"
fi
if [[ -L "${CWL}" ]]; then
    die "cwallet.sso is a symlink, refusing to use: ${CWL}"
fi

if [[ "${FORCE}" != "true" && ( -f "${EWL}" || -f "${CWL}" ) ]]; then
    echo "Wallet already exists in ${WORKDIR} (use --force to recreate). Skipping."
    exit 0
fi

# Warn when SHARED auto-login chosen (portable but lower security)
if [[ "${AUTO_LOGIN}" == "SHARED" ]]; then
    echo "WARN: --auto-login SHARED: portable keystore - anyone with the files can use the MOS credentials" >&2
fi
# - EOF Sanity Checks ----------------------------------------------------------

# - Main Script Logic ----------------------------------------------------------
# Apply umask 077 so all credential files are created 0600/0700 by default
umask 077

# Keep passwords as shell variables only: callers may have exported MOS_PASS /
# KS_PASS, which au_run.sh and java would otherwise inherit
export -n MOS_PASS KS_PASS 2>/dev/null || true

# cd to WORKDIR so AutoUpgrade writes wallet files there
(
    cd "${WORKDIR}"

    EXP_LOG_USER="$([[ "${QUIET}" == "true" ]] && echo 0 || echo 1)"

    EXPECT_AU_RUN="${AU_RUN}" \
    EXPECT_AU_CFG="${AU_CFG}" \
    EXPECT_MOS_USER="${MOS_USER}" \
    EXPECT_MOS_PASS="${MOS_PASS}" \
    EXPECT_KS_PASS="${KS_PASS}" \
    EXPECT_AUTO_LOGIN="${AUTO_LOGIN}" \
    EXP_LOG_USER="${EXP_LOG_USER}" \
    expect <<'EOF'
    # Debug toggles (set to 1 to troubleshoot):
    # log_user 1
    # exp_internal 1

    set timeout 120
    log_user $env(EXP_LOG_USER)

    set au_run     $env(EXPECT_AU_RUN)
    set cfg        $env(EXPECT_AU_CFG)
    set user       $env(EXPECT_MOS_USER)
    set pass       $env(EXPECT_MOS_PASS)
    set kspass     $env(EXPECT_KS_PASS)
    set autologin  $env(EXPECT_AUTO_LOGIN)

    # Unset credential env vars before spawning so au_run.sh / java do not inherit them
    unset env(EXPECT_MOS_PASS)
    unset env(EXPECT_KS_PASS)

    set user_added 0

    # Spawn via au_run.sh so Java, proxy, and truststore resolution all apply
    spawn bash $au_run -config $cfg -patch -load_password

    expect {
        "Enter password:" { send -- "$kspass\r"; exp_continue }
        "Enter password again:" { send -- "$kspass\r"; exp_continue }
        "Enter wallet password:" { send -- "$kspass\r"; exp_continue }

        -re {^MOS>\s*$} {
            if { $user_added == 0 } {
                send -- "add -user $user\r"
                set user_added 1
            } else {
                send -- "exit\r"
            }
            exp_continue
        }

        "Enter your secret/Password:" { send -- "$pass\r"; exp_continue }
        "Re-enter your secret/Password:" { send -- "$pass\r"; exp_continue }

        -re {Save the AutoUpgrade Patching keystore before exiting.*} {
            send -- "YES\r"; exp_continue
        }

        # AutoUpgrade 26.x KSM_AUTO_LOGIN_PROMPT
        -re {Select auto-login mode for the AutoUpgrade Patching keystore.*\[YES|NO|SHARED\].*} {
            send -- "$autologin\r"; exp_continue
        }

        # Older JAR: "Convert ... to auto-login" prompt
        -re {Convert the AutoUpgrade Patching keystore to auto-login.*} {
            send -- "YES\r"; exp_continue
        }

        eof { exit 0 }
        timeout { puts "ERROR: timed out during keystore creation"; exit 1 }
    }
EOF
)

# - Verify Outputs -------------------------------------------------------------
[[ -f "${EWL}" ]] || die "Keystore creation finished but ewallet.p12 not found in ${WORKDIR}"
# cwallet.sso may be created after 'save'/'YES'; tolerate absence if AU chose not to
if [[ -f "${CWL}" ]]; then
    chmod 600 "${CWL}"
fi
chmod 600 "${EWL}"
echo "Keystore created in ${WORKDIR}"
# - EOF ------------------------------------------------------------------------
