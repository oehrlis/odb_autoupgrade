#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Name.......: au_update_jar.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Editor.....: Stefan Oehrli
# Date.......: 2026.10.08
# Version....: v0.5.0
# Purpose....: Download and update autoupgrade.jar if a new version is
#              available. Create versioned backup of existing JAR.
# Notes......: Can be run from any folder. Stores JAR in <script base>/jar.
# Reference..: https://github.com/oehrlis
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2025.06.17 oehrli - added backup with version or timestamp
# 2026.10.08 oehrli - renamed from update_autoupgrade.sh; set -euo pipefail,
#                     local vars in functions, BSD/GNU sha256 portability
# ------------------------------------------------------------------------------

set -euo pipefail

# - Default Values -------------------------------------------------------------
# shellcheck disable=SC2034
SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")                             # Script name
SCRIPT_BIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
SCRIPT_BASE=$(dirname "${SCRIPT_BIN_DIR}")                              # Script base
# shellcheck disable=SC2034
SCRIPT_ETC_DIR="${SCRIPT_BASE}/etc"                                     # Config dir
JAR_DIR="${SCRIPT_BASE}/jar"                                            # Target folder
JAR_FILE="${JAR_DIR}/autoupgrade.jar"                                   # JAR path
JAR_URL="https://download.oracle.com/otn-pub/otn_software/autoupgrade.jar"
# - EOF Default Values ---------------------------------------------------------

# - Functions ------------------------------------------------------------------

# Function to create backup of existing JAR
backup_existing_jar() {
    local version_out build_ver backup_file timestamp
    if command -v java >/dev/null 2>&1; then
        version_out="$(java -jar "${JAR_FILE}" -version 2>/dev/null | grep build.version || true)"
        build_ver="${version_out##* }"
        if [[ -n "${build_ver}" && "${build_ver}" != "${version_out}" ]]; then
            backup_file="${JAR_DIR}/autoupgrade_${build_ver}.jar"
        else
            timestamp="$(date +%Y%m%d_%H%M%S)"
            backup_file="${JAR_DIR}/autoupgrade_${timestamp}.jar"
            echo "WARNING: Could not determine build.version, using timestamp instead." >&2
        fi
    else
        timestamp="$(date +%Y%m%d_%H%M%S)"
        backup_file="${JAR_DIR}/autoupgrade_${timestamp}.jar"
        echo "WARNING: Java not available, using timestamp for backup." >&2
    fi

    echo "Creating backup: ${backup_file}"
    cp "${JAR_FILE}" "${backup_file}"
}

# Print SHA-256 checksum (GNU sha256sum or BSD shasum -a 256)
print_sha256() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${file}"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${file}"
    else
        echo "WARNING: sha256sum / shasum not found; skipping checksum." >&2
    fi
}
# Print usage
usage() {
    cat <<USAGE
Usage: ${SCRIPT_NAME} [--dry-run] [--help]

Download the current autoupgrade.jar from ${JAR_URL}
into ${JAR_DIR}, keeping a backup of the existing JAR.
curl uses https_proxy / no_proxy from the environment.

  --dry-run  Show what would be downloaded and exit
  --help     Show this help and exit
USAGE
}
# - EOF Functions --------------------------------------------------------------

# - Parse Parameters -----------------------------------------------------------
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done
if [[ "${DRY_RUN}" == true ]]; then
    echo "DRY-RUN: would download ${JAR_URL} to ${JAR_FILE}"
    exit 0
fi
# - EOF Parse Parameters -------------------------------------------------------

TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/au_update_XXXXXX")"
# Ensure temp file is removed on exit
trap 'rm -f "${TMP_FILE}"' EXIT

# - Main Script Logic ----------------------------------------------------------

# Create target folder if it does not exist
mkdir -p "${JAR_DIR}"

echo "Downloading latest autoupgrade.jar to temporary file..."
# --proto '=https': only allow https (no redirect to http/ftp)
# --proto-redir '=https': follow redirects only within https
curl --proto '=https' --proto-redir '=https' -Lf "${JAR_URL}" -o "${TMP_FILE}"

# Validate downloaded file: must be >= 1 MB and start with PK (ZIP magic)
local_size=0
local_size=$(stat -c '%s' "${TMP_FILE}" 2>/dev/null) \
    || local_size=$(stat -f '%z' "${TMP_FILE}" 2>/dev/null) \
    || local_size=0
if [[ "${local_size}" -lt 1048576 ]]; then
    echo "ERROR: Downloaded file is too small (${local_size} bytes < 1 MB) - possibly a redirect to an HTML error page" >&2
    exit 1
fi

# Check ZIP magic (first two bytes must be 'PK')
magic_bytes="$(dd if="${TMP_FILE}" bs=2 count=1 2>/dev/null)"
if [[ "${magic_bytes}" != "PK" ]]; then
    echo "ERROR: Downloaded file is not a valid ZIP/JAR (missing PK magic bytes)" >&2
    exit 1
fi

# Print SHA-256 and size before installing
echo "Downloaded file: ${local_size} bytes"
echo "SHA-256:"
print_sha256 "${TMP_FILE}"

# Check if autoupgrade.jar already exists
if [[ -f "${JAR_FILE}" ]]; then
    # Compare existing JAR with downloaded one
    if cmp -s "${TMP_FILE}" "${JAR_FILE}"; then
        echo "Already up to date. No changes made."
        exit 0
    else
        echo "New version found. Backing up existing JAR..."
        backup_existing_jar
        echo "Updating ${JAR_FILE}..."
        mv "${TMP_FILE}" "${JAR_FILE}"
    fi
else
    echo "No existing file found. Saving new autoupgrade.jar..."
    mv "${TMP_FILE}" "${JAR_FILE}"
fi

# Ensure the installed JAR has read-only permissions (no execute bit)
chmod 0644 "${JAR_FILE}"
echo "Done. Installed: ${JAR_FILE}"

# - EOF ------------------------------------------------------------------------
