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

@test "au_patch_verify.sh: malformed JSON -> exit 1 (parser error)" {
    local folder="${WORK_DIR}/patches/badjson"
    mkdir -p "${folder}"
    printf 'THIS IS NOT JSON\n' > "${folder}/patches_info.json"
    touch "${folder}/bug-map.json"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"parse"* || "${output}" == *"ERROR"* || "${output}" == *"error"* || "${output}" == *"Failed"* ]]
}

@test "au_patch_verify.sh: zero file entries in patches_info.json -> exit 1" {
    local folder="${WORK_DIR}/patches/nofiles"
    mkdir -p "${folder}"
    touch "${folder}/bug-map.json"
    printf '{"patchFolder":"%s","generatedAt":"2024-01-01T00:00:00Z","patches":[{"description":"Empty","patchId":99,"files":[]}]}\n' \
        "${folder}" > "${folder}/patches_info.json"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"No file entries"* || "${output}" == *"ERROR"* ]]
}

@test "au_patch_verify.sh: entry with neither SHA-256 nor checksum-256 -> exit 1 naming entry" {
    local folder="${WORK_DIR}/patches/nochecksum"
    mkdir -p "${folder}"
    echo "content" > "${folder}/test.zip"
    touch "${folder}/bug-map.json"
    cat > "${folder}/patches_info.json" <<JSONEOF
{
  "patchFolder": "${folder}",
  "generatedAt": "2024-01-01T00:00:00Z",
  "patches": [
    {
      "description": "Test",
      "patchId": 12345,
      "releaseUpdate": "19.28.0.0.0",
      "files": [
        {
          "name": "test.zip",
          "size": 8
        }
      ]
    }
  ]
}
JSONEOF
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"test.zip"* ]]
    [[ "${output}" == *"NO-CHECKSUM"* || "${output}" == *"neither"* || "${output}" == *"checksum"* ]]
}

@test "au_patch_verify.sh: entry name with slash -> exit 1 naming the entry" {
    local folder="${WORK_DIR}/patches/slashname"
    mkdir -p "${folder}"
    touch "${folder}/bug-map.json"
    cat > "${folder}/patches_info.json" <<JSONEOF
{
  "patchFolder": "${folder}",
  "generatedAt": "2024-01-01T00:00:00Z",
  "patches": [
    {
      "description": "Test",
      "patchId": 12345,
      "releaseUpdate": "19.28.0.0.0",
      "files": [
        {
          "name": "../../etc/passwd",
          "SHA-256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "size": 10
        }
      ]
    }
  ]
}
JSONEOF
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"INVALID NAME"* || "${output}" == *"invalid"* || "${output}" == *"basename"* ]]
}

@test "au_patch_verify.sh: entry name starting with dot -> exit 1 naming the entry" {
    local folder="${WORK_DIR}/patches/dotname"
    mkdir -p "${folder}"
    touch "${folder}/bug-map.json"
    cat > "${folder}/patches_info.json" <<JSONEOF
{
  "patchFolder": "${folder}",
  "generatedAt": "2024-01-01T00:00:00Z",
  "patches": [
    {
      "description": "Test",
      "patchId": 12345,
      "releaseUpdate": "19.28.0.0.0",
      "files": [
        {
          "name": ".hidden_file",
          "SHA-256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "size": 10
        }
      ]
    }
  ]
}
JSONEOF
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"INVALID NAME"* || "${output}" == *"invalid"* || "${output}" == *".hidden_file"* ]]
}

@test "au_patch_verify.sh: entry name with pipe -> exit 1 (pipe is field separator, parse corrupts name)" {
    local folder="${WORK_DIR}/patches/pipename"
    mkdir -p "${folder}"
    touch "${folder}/bug-map.json"
    # Build JSON with pipe in name using printf to avoid shell interpretation.
    # The pipe is the internal field separator: the name is split and the resulting
    # truncated name cannot be found -> MISSING -> exit 1.
    printf '{"patchFolder":"%s","generatedAt":"2024-01-01T00:00:00Z","patches":[{"description":"Test","patchId":12345,"releaseUpdate":"19.28.0.0.0","files":[{"name":"bad|name.zip","SHA-256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":10}]}]}\n' \
        "${folder}" > "${folder}/patches_info.json"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    # pipe corrupts the field split -> MISSING or INVALID NAME, either way exit 1
    [ "${status}" -eq 1 ]
}

@test "au_patch_verify.sh: listed file is symlink -> exit 1 naming it" {
    local folder="${WORK_DIR}/patches/listedsymlink"
    mkdir -p "${folder}"
    echo "real content" > "${WORK_DIR}/real_file.zip"
    ln -s "${WORK_DIR}/real_file.zip" "${folder}/patch.zip"
    touch "${folder}/bug-map.json"
    local size=13
    cat > "${folder}/patches_info.json" <<JSONEOF
{
  "patchFolder": "${folder}",
  "generatedAt": "2024-01-01T00:00:00Z",
  "patches": [
    {
      "description": "Test",
      "patchId": 12345,
      "releaseUpdate": "19.28.0.0.0",
      "files": [
        {
          "name": "patch.zip",
          "SHA-256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "size": ${size}
        }
      ]
    }
  ]
}
JSONEOF
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"patch.zip"* ]]
    [[ "${output}" == *"SYMLINK"* || "${output}" == *"symlink"* ]]
}

@test "au_patch_verify.sh: unlisted symlink is reported by name" {
    local folder="${WORK_DIR}/patches/unlistedsym"
    mkdir -p "${folder}"
    echo "real" > "${folder}/listed.zip"
    local sha
    sha=$(file_sha256 "${folder}/listed.zip")
    local size
    size=$(stat -c '%s' "${folder}/listed.zip" 2>/dev/null || stat -f '%z' "${folder}/listed.zip")
    make_single_patch_info "${folder}" "listed.zip" "${sha}" "${size}"
    # Create an unlisted symlink in the folder
    ln -s "${folder}/listed.zip" "${folder}/unlisted_link.zip"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    # Symlink should be reported, not silently skipped
    [[ "${output}" == *"unlisted_link.zip"* || "${output}" == *"UNLISTED"* ]]
}

@test "au_patch_verify.sh: --help mentions transfer integrity not authenticity" {
    run bash "${SCRIPT}" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"integrity"* ]]
    [[ "${output}" == *"authenticity"* ]]
}

# ---------------------------------------------------------------------------
# SHOULD 4 regression: names with '|' or newline must be reported INVALID NAME
# (previously dead code because IFS='|' split consumed the pipe char)
# ---------------------------------------------------------------------------

@test "au_patch_verify.sh: name with pipe char reported as INVALID NAME" {
    # jq now detects '|' in the name and emits the INVALID_NAME token; the shell
    # reads it and reports the offending name.
    local folder="${WORK_DIR}/patches/pipe_name"
    mkdir -p "${folder}"
    touch "${folder}/bug-map.json"
    cat > "${folder}/patches_info.json" <<'JSONEOF'
{
  "patches": [
    {
      "files": [
        {
          "name": "evil|name.zip",
          "SHA-256": "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1",
          "size": 100
        }
      ]
    }
  ]
}
JSONEOF
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"INVALID"* ]]
}

@test "au_patch_verify.sh: name with embedded newline reported as INVALID NAME" {
    # A JSON string with \n in the name must be caught inside jq/python3 and
    # reported as INVALID NAME (not silently accepted or split incorrectly).
    local folder="${WORK_DIR}/patches/nl_name"
    mkdir -p "${folder}"
    touch "${folder}/bug-map.json"
    # Use python3 to generate JSON with a real embedded newline in the name field
    python3 -I -c "
import json
data = {'patches': [{'files': [{'name': 'bad\nname.zip', 'SHA-256': 'abc123'*10+'ab', 'size': 100}]}]}
with open('${folder}/patches_info.json', 'w') as f:
    json.dump(data, f)
"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${folder}' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"INVALID"* ]]
}
