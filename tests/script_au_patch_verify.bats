#!/usr/bin/env bats
# shellcheck disable=SC1090
# ------------------------------------------------------------------------------
# tests/script_au_patch_verify.bats
# BATS tests for bin/au_patch_verify.sh (WP7)
# ------------------------------------------------------------------------------

load 'test_helper'

SCRIPT=""

setup() {
    setup_helper
    SCRIPT="${REPO_ROOT}/bin/au_patch_verify.sh"
}

teardown() {
    teardown_helper
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create a minimal patches_info.json with a known file entry.
# Args: $1 = folder, $2 = filename, $3 = sha256 (hex), $4 = size
make_single_patch_info() {
    local _folder="$1" _name="$2" _sha256="$3" _size="$4"
    mkdir -p "${_folder}"
    cat > "${_folder}/patches_info.json" <<JSONEOF
{
  "patchFolder": "${_folder}",
  "generatedAt": "2024-10-15T08:00:00Z",
  "patches": [
    {
      "description": "Test patch",
      "patchId": 12345,
      "releaseUpdate": "19.28.0.0.0",
      "files": [
        {
          "name": "${_name}",
          "SHA-256": "${_sha256}",
          "size": ${_size}
        }
      ]
    }
  ]
}
JSONEOF
    touch "${_folder}/bug-map.json"
}

# Compute SHA-256 of a file portably
file_sha256() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${f}" | cut -d' ' -f1
    else
        shasum -a 256 "${f}" | cut -d' ' -f1
    fi
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "au_patch_verify.sh: --help exits 0" {
    run bash "${SCRIPT}" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage"* ]]
}

@test "au_patch_verify.sh: valid file passes" {
    local folder="${WORK_DIR}/patches/ok"
    mkdir -p "${folder}"
    echo "test content" > "${folder}/test.zip"
    local sha
    sha=$(file_sha256 "${folder}/test.zip")
    local size
    size=$(stat -c '%s' "${folder}/test.zip" 2>/dev/null || stat -f '%z' "${folder}/test.zip")
    make_single_patch_info "${folder}" "test.zip" "${sha}" "${size}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PASSED"* || "${output}" == *"OK"* ]]
}

@test "au_patch_verify.sh: missing file -> exit 1" {
    local folder="${WORK_DIR}/patches/missing"
    mkdir -p "${folder}"
    make_single_patch_info "${folder}" "nothere.zip" "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1" 9999
    touch "${folder}/bug-map.json"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"MISSING"* || "${output}" == *"missing"* ]]
}

@test "au_patch_verify.sh: wrong SHA-256 -> exit 1" {
    local folder="${WORK_DIR}/patches/badsha"
    mkdir -p "${folder}"
    echo "hello" > "${folder}/p12345.zip"
    make_single_patch_info "${folder}" "p12345.zip" "0000000000000000000000000000000000000000000000000000000000000000" 6
    touch "${folder}/bug-map.json"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"MISMATCH"* || "${output}" == *"mismatch"* ]]
}

@test "au_patch_verify.sh: size mismatch -> exit 1" {
    local folder="${WORK_DIR}/patches/badsize"
    mkdir -p "${folder}"
    echo "hello" > "${folder}/p12345.zip"
    local sha
    sha=$(file_sha256 "${folder}/p12345.zip")
    make_single_patch_info "${folder}" "p12345.zip" "${sha}" 999999
    touch "${folder}/bug-map.json"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"SIZE"* || "${output}" == *"MISMATCH"* ]]
}

@test "au_patch_verify.sh: missing bug-map.json -> exit 1" {
    local folder="${WORK_DIR}/patches/nobugmap"
    mkdir -p "${folder}"
    echo "test" > "${folder}/test.zip"
    local sha
    sha=$(file_sha256 "${folder}/test.zip")
    local size
    size=$(stat -c '%s' "${folder}/test.zip" 2>/dev/null || stat -f '%z' "${folder}/test.zip")
    make_single_patch_info "${folder}" "test.zip" "${sha}" "${size}"
    # make_single_patch_info creates bug-map.json; remove it for this test
    rm -f "${folder}/bug-map.json"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"bug-map"* || "${output}" == *"FAIL"* ]]
}

@test "au_patch_verify.sh: aru-bug-map.json accepted when bug-map.json absent" {
    local folder="${WORK_DIR}/patches/arubugmap"
    mkdir -p "${folder}"
    echo "test" > "${folder}/test.zip"
    local sha
    sha=$(file_sha256 "${folder}/test.zip")
    local size
    size=$(stat -c '%s' "${folder}/test.zip" 2>/dev/null || stat -f '%z' "${folder}/test.zip")
    make_single_patch_info "${folder}" "test.zip" "${sha}" "${size}"
    touch "${folder}/aru-bug-map.json"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    [ "${status}" -eq 0 ]
}

@test "au_patch_verify.sh: unlisted file is named in output (no silent skip)" {
    local folder="${WORK_DIR}/patches/extra"
    mkdir -p "${folder}"
    echo "test" > "${folder}/test.zip"
    local sha
    sha=$(file_sha256 "${folder}/test.zip")
    local size
    size=$(stat -c '%s' "${folder}/test.zip" 2>/dev/null || stat -f '%z' "${folder}/test.zip")
    make_single_patch_info "${folder}" "test.zip" "${sha}" "${size}"
    # Add an unlisted file
    echo "extra" > "${folder}/extra_unknown.zip"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    # extra file is a WARN, not a failure; status should still be 0
    [[ "${output}" == *"UNLISTED"* || "${output}" == *"unlisted"* || "${output}" == *"extra_unknown"* ]]
}

@test "au_patch_verify.sh: au_patch.env excluded from unlisted check" {
    local folder="${WORK_DIR}/patches/pinfile"
    mkdir -p "${folder}"
    echo "test" > "${folder}/test.zip"
    local sha
    sha=$(file_sha256 "${folder}/test.zip")
    local size
    size=$(stat -c '%s' "${folder}/test.zip" 2>/dev/null || stat -f '%z' "${folder}/test.zip")
    make_single_patch_info "${folder}" "test.zip" "${sha}" "${size}"
    printf 'AU_PATCH=RECOMMENDED:19.28\n' > "${folder}/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"au_patch.env"* ]] || [[ "${output}" == *"excluded"* ]]
}

@test "au_patch_verify.sh: checksum-256 field accepted (alt SHA field name)" {
    local folder="${WORK_DIR}/patches/checksum256"
    mkdir -p "${folder}"
    echo "test" > "${folder}/test.zip"
    local sha
    sha=$(file_sha256 "${folder}/test.zip")
    local size
    size=$(stat -c '%s' "${folder}/test.zip" 2>/dev/null || stat -f '%z' "${folder}/test.zip")
    # Use checksum-256 field name instead of SHA-256
    cat > "${folder}/patches_info.json" <<JSONEOF
{
  "patchFolder": "${folder}",
  "generatedAt": "2024-10-15T08:00:00Z",
  "patches": [
    {
      "description": "Test",
      "patchId": 11111,
      "releaseUpdate": "19.28.0.0.0",
      "files": [
        {
          "name": "test.zip",
          "checksum-256": "${sha}",
          "size": ${size}
        }
      ]
    }
  ]
}
JSONEOF
    touch "${folder}/bug-map.json"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    [ "${status}" -eq 0 ]
}

@test "au_patch_verify.sh: missing patches_info.json -> exit 1" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"not found"* || "${output}" == *"ERROR"* ]]
}
