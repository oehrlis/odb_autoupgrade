#!/usr/bin/env bats
# shellcheck disable=SC1090
# ------------------------------------------------------------------------------
# tests/script_au_patch_pin.bats
# BATS tests for bin/au_patch_pin.sh (WP7)
# ------------------------------------------------------------------------------

load 'test_helper'

SCRIPT=""
FIXTURE_DIR=""

setup() {
    setup_helper
    SCRIPT="${REPO_ROOT}/bin/au_patch_pin.sh"
    FIXTURE_DIR="${REPO_ROOT}/tests/fixtures"
    export AUTOUPGRADE_JAVA_SUPPORTED="8 11"
}

teardown() {
    teardown_helper
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

make_patches_info() {
    local folder="$1"
    cp "${FIXTURE_DIR}/patches_info_19_28.json" "${folder}/patches_info.json"
}

make_patches_info_recommended() {
    local folder="$1"
    cp "${FIXTURE_DIR}/patches_info_recommended.json" "${folder}/patches_info.json"
}

# ---------------------------------------------------------------------------
# Basic pin from patches_info.json
# ---------------------------------------------------------------------------

@test "au_patch_pin.sh: --help exits 0" {
    run bash "${SCRIPT}" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage"* ]]
}

@test "au_patch_pin.sh: RECOMMENDED -> RECOMMENDED:<x.y> pin" {
    make_patches_info_recommended "${WORK_DIR}/patches"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RECOMMENDED
        bash '${SCRIPT}' '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"19.32"* ]]
    local pin_file="${WORK_DIR}/patches/au_patch.env"
    [ -f "${pin_file}" ]
    grep -q 'AU_PATCH=RECOMMENDED:19.32' "${pin_file}"
}

@test "au_patch_pin.sh: pin file has 0600 permissions" {
    make_patches_info_recommended "${WORK_DIR}/patches"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RECOMMENDED
        bash '${SCRIPT}' '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 0 ]
    local pin_file="${WORK_DIR}/patches/au_patch.env"
    local perms
    perms=$(stat -c '%a' "${pin_file}" 2>/dev/null || stat -f '%Lp' "${pin_file}" 2>/dev/null)
    [ "${perms}" = "600" ]
}

@test "au_patch_pin.sh: RU (bare) -> RU:<x.y> in pin" {
    make_patches_info "${WORK_DIR}/patches"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RU,OPATCH,OJVM
        bash '${SCRIPT}' '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 0 ]
    grep -q 'AU_PATCH=RU:19.28,OPATCH,OJVM' "${WORK_DIR}/patches/au_patch.env"
}

@test "au_patch_pin.sh: RU:x.y already versioned -> unchanged" {
    make_patches_info "${WORK_DIR}/patches"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RU:19.28,OPATCH
        bash '${SCRIPT}' '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 0 ]
    grep -q 'AU_PATCH=RU:19.28,OPATCH' "${WORK_DIR}/patches/au_patch.env"
}

@test "au_patch_pin.sh: conflicting pin refused without --force" {
    make_patches_info "${WORK_DIR}/patches"
    # Write an existing pin with a different value
    printf 'AU_PATCH=RECOMMENDED:19.27\n' > "${WORK_DIR}/patches/au_patch.env"
    chmod 600 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RECOMMENDED
        bash '${SCRIPT}' '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"conflicts"* || "${output}" == *"conflict"* || "${output}" == *"force"* || "${output}" == *"WARN"* ]]
}

@test "au_patch_pin.sh: conflicting pin overwritten with --force" {
    make_patches_info "${WORK_DIR}/patches"
    printf 'AU_PATCH=RECOMMENDED:19.27\n' > "${WORK_DIR}/patches/au_patch.env"
    chmod 600 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RECOMMENDED
        bash '${SCRIPT}' --force '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 0 ]
    grep -q 'AU_PATCH=RECOMMENDED:19.32\|AU_PATCH=RECOMMENDED:19.28' "${WORK_DIR}/patches/au_patch.env"
}

@test "au_patch_pin.sh: matching existing pin: no rewrite (exits 0)" {
    make_patches_info_recommended "${WORK_DIR}/patches"
    printf 'AU_PATCH=RECOMMENDED:19.32\n' > "${WORK_DIR}/patches/au_patch.env"
    chmod 600 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RECOMMENDED
        bash '${SCRIPT}' '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"already matches"* ]]
}

@test "au_patch_pin.sh: --dry-run does not write pin file" {
    make_patches_info_recommended "${WORK_DIR}/patches"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RECOMMENDED
        bash '${SCRIPT}' --dry-run '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DRY-RUN"* ]]
    [ ! -f "${WORK_DIR}/patches/au_patch.env" ]
}

@test "au_patch_pin.sh: --resolve-mrp replaces MRP with patchId" {
    make_patches_info "${WORK_DIR}/patches"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RU,OPATCH,MRP
        bash '${SCRIPT}' --resolve-mrp '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 0 ]
    # MRP patchId from fixture is 37056207
    grep -q '37056207' "${WORK_DIR}/patches/au_patch.env"
}

@test "au_patch_pin.sh: missing patches_info.json -> exit 1" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"not found"* || "${output}" == *"ERROR"* ]]
}

@test "au_patch_pin.sh: patches_info.json without releaseUpdate -> exit 1" {
    cat > "${WORK_DIR}/patches/patches_info.json" <<'JSON'
{"patchFolder":"/w","generatedAt":"2024-01-01T00:00:00Z","patches":[{"description":"OPatch","patchId":6880880,"files":[{"name":"opatch.zip","SHA-256":"abc123","size":100}]}]}
JSON
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        bash '${SCRIPT}' '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"releaseUpdate"* || "${output}" == *"ERROR"* ]]
}

@test "au_patch_pin.sh: version 19.28.0.0.0 -> 19.28 short form" {
    make_patches_info "${WORK_DIR}/patches"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RECOMMENDED
        bash '${SCRIPT}' '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 0 ]
    grep -q '19.28' "${WORK_DIR}/patches/au_patch.env"
}
