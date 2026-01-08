#!/bin/bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Name.......: update_autoupgrade.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Editor.....: Stefan Oehrli
# Date.......: 2025.06.17
# Version....: v0.3.0
# Purpose....: Download and update autoupgrade.jar if a new version is 
#              available. Create versioned backup of existing JAR.
# Notes......: Can be run from any folder. Stores JAR in <script base>/jar.
# Reference..: https://github.com/oehrlis
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2025.06.17 oehrli - added backup with version or timestamp
# ------------------------------------------------------------------------------

# - Default Values -------------------------------------------------------------
SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")                             # Script name
SCRIPT_BIN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
SCRIPT_BASE=$(dirname "${SCRIPT_BIN_DIR}")                              # Script base
SCRIPT_ETC_DIR="${SCRIPT_BASE}/etc"                                     # Config dir
JAR_DIR="${SCRIPT_BASE}/jar"                                            # Target folder
JAR_FILE="${JAR_DIR}/autoupgrade.jar"                                   # JAR path
TMP_FILE="$(mktemp)"                                                    # Temp file
JAR_URL="https://download.oracle.com/otn-pub/otn_software/autoupgrade.jar"
# - EOF Default Values ---------------------------------------------------------

# - Functions ------------------------------------------------------------------

# Function to create backup of existing JAR
backup_existing_jar() {
    if [[ -x "$(command -v java)" ]]; then
        VERSION_OUT=$(java -jar "${JAR_FILE}" -version 2>/dev/null | grep build.version || true)
        BUILD_VER=$(echo "${VERSION_OUT}" | awk '{print $2}')
        if [[ -n "${BUILD_VER}" ]]; then
            BACKUP_FILE="${JAR_DIR}/autoupgrade_${BUILD_VER}.jar"
        else
            TIMESTAMP=$(date +%Y%m%d_%H%M%S)
            BACKUP_FILE="${JAR_DIR}/autoupgrade_${TIMESTAMP}.jar"
            echo "WARNING: Could not determine build.version, using timestamp instead."
        fi
    else
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        BACKUP_FILE="${JAR_DIR}/autoupgrade_${TIMESTAMP}.jar"
        echo "WARNING: Java not available, using timestamp for backup."
    fi

    echo "Creating backup: ${BACKUP_FILE}"
    cp "${JAR_FILE}" "${BACKUP_FILE}"
}
# - EOF Functions --------------------------------------------------------------

# - Parse Parameters -----------------------------------------------------------
# (no command-line options yet)
# - EOF Parse Parameters -------------------------------------------------------

# - Main Script Logic ----------------------------------------------------------

# Create target folder if it does not exist
mkdir -p "${JAR_DIR}"

echo "Downloading latest autoupgrade.jar to temporary file..."
curl -Lf "${JAR_URL}" -o "${TMP_FILE}"

# Check if autoupgrade.jar already exists
if [[ -f "${JAR_FILE}" ]]; then
    # Compare existing JAR with downloaded one
    if cmp -s "${TMP_FILE}" "${JAR_FILE}"; then
        echo "Already up to date. No changes made."
        rm -f "${TMP_FILE}"
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

echo "Done. Current SHA256:"
sha256sum "${JAR_FILE}"

# - EOF ------------------------------------------------------------------------
