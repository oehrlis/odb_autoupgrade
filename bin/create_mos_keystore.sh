#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Create (or skip if present) an AutoUpgrade MOS keystore using -load_password.
# Drives the interactive CLI via 'expect' to produce ewallet.p12 + cwallet.sso.
# ------------------------------------------------------------------------------
set -euo pipefail

# --- defaults (override via flags) -------------------------------------------
AU_JAR="jar/autoupgrade.jar"         # relative to --workdir by default
AU_CFG="etc/test.cfg"                # minimal/any valid AU config file
WORKDIR="$(pwd)"                     # where wallet files will be written
MOS_USER=""                          # --mos-user or MOS_USER env
MOS_PASS=""                          # --mos-pass or via file/secret
KS_PASS=""                           # --ks-pass (defaults to MOS_PASS)
FORCE="false"                        # --force to overwrite existing wallet
QUIET="false"                        # --quiet to suppress expect echo

# --- helpers ------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --workdir DIR          Working dir; wallet files will be created here
  --au-jar PATH          Path to autoupgrade.jar (default: jar/autoupgrade.jar)
  --cfg PATH             Path to AU config file (default: etc/test.cfg)
  --mos-user USER        MOS username (email)
  --mos-pass PASS        MOS password (avoid shell history; prefer --mos-pass-file)
  --mos-pass-file FILE   Read MOS password from file/secret
  --ks-pass PASS         Keystore password (defaults to MOS password)
  --ks-pass-file FILE    Read keystore password from file/secret
  --force                Recreate wallet even if files exist
  --quiet                Reduce expect output

Examples:
  $(basename "$0") --workdir /u00/app/oracle/autoupgrade/keystore \\
    --au-jar /u00/app/oracle/autoupgrade/jar/autoupgrade.jar \\
    --cfg /u00/app/oracle/autoupgrade/config/dummy.config \\
    --mos-user you@example.com --mos-pass-file /run/secrets/mos_pass \\
    --ks-pass-file /run/secrets/ks_pass
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
trimnl() { tr -d '\r\n' < "$1"; }

# --- arg parsing --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) WORKDIR="$2"; shift 2;;
    --au-jar) AU_JAR="$2"; shift 2;;
    --cfg) AU_CFG="$2"; shift 2;;
    --mos-user) MOS_USER="$2"; shift 2;;
    --mos-pass) MOS_PASS="$2"; shift 2;;
    --mos-pass-file) MOS_PASS="$(trimnl "$2")"; shift 2;;
    --ks-pass) KS_PASS="$2"; shift 2;;
    --ks-pass-file) KS_PASS="$(trimnl "$2")"; shift 2;;
    --force) FORCE="true"; shift;;
    --quiet) QUIET="true"; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done

# --- sanity -------------------------------------------------------------------
command -v java   >/dev/null || die "java not found in PATH"
command -v expect >/dev/null || die "expect not found (dnf/yum/apt install expect)"
[[ -d "$WORKDIR" ]] || mkdir -p "$WORKDIR"

# Resolve AU_JAR, AU_CFG relative to WORKDIR if they are relative paths
[[ "$AU_JAR" = /* ]] || AU_JAR="${WORKDIR%/}/$AU_JAR"
[[ "$AU_CFG" = /* ]] || AU_CFG="${WORKDIR%/}/$AU_CFG"

[[ -f "$AU_JAR" ]] || die "AutoUpgrade jar not found: $AU_JAR"
[[ -f "$AU_CFG" ]] || die "AU config not found: $AU_CFG"

# Secrets
[[ -n "${MOS_USER}" ]] || die "--mos-user (or MOS_USER env) is required"
if [[ -z "${MOS_PASS}" ]]; then
  die "--mos-pass or --mos-pass-file required"
fi
[[ -n "${KS_PASS}" ]] || KS_PASS="${MOS_PASS}"

EWL="${WORKDIR%/}/ewallet.p12"
CWL="${WORKDIR%/}/cwallet.sso"

if [[ "$FORCE" != "true" && ( -f "$EWL" || -f "$CWL" ) ]]; then
  echo "Wallet already exists in $WORKDIR (use --force to recreate). Skipping."
  exit 0
fi

# --- run expect ---------------------------------------------------------------
# We 'cd' to WORKDIR so AU writes the wallet files there.
(
  cd "$WORKDIR"

  # build expect script
  # shellcheck disable=SC2034 # used by expect environment
  EXP_LOG_USER=$([[ "$QUIET" == "true" ]] && echo 0 || echo 1)

  EXPECT_AU_JAR="$AU_JAR" \
  EXPECT_AU_CFG="$AU_CFG" \
  EXPECT_MOS_USER="$MOS_USER" \
  EXPECT_MOS_PASS="$MOS_PASS" \
  EXPECT_KS_PASS="$KS_PASS" \
  EXP_LOG_USER="$EXP_LOG_USER" \
  expect <<'EOF'
    # Debug toggles (set to 1 to troubleshoot):
    # log_user 1
    # exp_internal 1

    # import shell env vars set below
    set timeout 120
    log_user $env(EXP_LOG_USER)

    set aujar   $env(EXPECT_AU_JAR)
    set cfg     $env(EXPECT_AU_CFG)
    set user    $env(EXPECT_MOS_USER)
    set pass    $env(EXPECT_MOS_PASS)
    set kspass  $env(EXPECT_KS_PASS)

    set user_added 0

    # Start the loader exactly like your working session
    spawn java -jar $aujar -config $cfg -patch -load_password

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

      -re {Save the AutoUpgrade Patching keystore before exiting.*} { send -- "YES\r"; exp_continue }
      -re {Convert the AutoUpgrade Patching keystore to auto-login.*} { send -- "YES\r"; exp_continue }

      eof { exit 0 }
      timeout { puts "ERROR: timed out during keystore creation"; exit 1 }
    }
EOF
)

# --- verify outputs -----------------------------------------------------------
[[ -f "$EWL" ]] || die "Keystore creation finished but ewallet.p12 not found in $WORKDIR"
# cwallet.sso may be created after 'save'/'YES'; tolerate absence if AU chose not to
if [[ -f "$CWL" ]]; then
  chmod 600 "$CWL"
fi
chmod 600 "$EWL"
echo "Keystore created in $WORKDIR"
