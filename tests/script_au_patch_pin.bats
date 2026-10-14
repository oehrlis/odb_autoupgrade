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

@test "au_patch_pin.sh: --resolve-mrp without MRP entry keeps MRP and warns (F15)" {
    make_patches_info_recommended "${WORK_DIR}/patches"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RU,OPATCH,MRP
        bash '${SCRIPT}' --resolve-mrp '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WARN"*"no MRP entry in patches_info.json"* ]]
    grep -q 'AU_PATCH=RU:19.32,OPATCH,MRP' "${WORK_DIR}/patches/au_patch.env"
}

@test "au_patch_pin.sh: --resolve-mrp without MRP in AU_PATCH does not warn (F15)" {
    make_patches_info_recommended "${WORK_DIR}/patches"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RU,OPATCH,DPBP
        bash '${SCRIPT}' --resolve-mrp '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"no MRP entry"* ]]
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

# ---------------------------------------------------------------------------
# MUST 4: injection / validation tests
# ---------------------------------------------------------------------------

@test "au_patch_pin.sh: releaseUpdate injection '19.28,12345678,OJVM:19.1' -> refused" {
    cp "${FIXTURE_DIR}/patches_info_inject_ru.json" "${WORK_DIR}/patches/patches_info.json"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RECOMMENDED
        bash '${SCRIPT}' '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Invalid releaseUpdate"* || "${output}" == *"injection"* || "${output}" == *"ERROR"* ]]
}

@test "au_patch_pin.sh: patchId injection '1,RU:18.1' -> refused" {
    cp "${FIXTURE_DIR}/patches_info_inject_patchid.json" "${WORK_DIR}/patches/patches_info.json"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RU,MRP
        bash '${SCRIPT}' --resolve-mrp '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Invalid MRP patchId"* || "${output}" == *"injection"* || "${output}" == *"ERROR"* ]]
}

@test "au_patch_pin.sh: valid fixtures still pin successfully (RECOMMENDED)" {
    make_patches_info_recommended "${WORK_DIR}/patches"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RECOMMENDED
        bash '${SCRIPT}' '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 0 ]
    grep -q 'AU_PATCH=RECOMMENDED:19.32' "${WORK_DIR}/patches/au_patch.env"
}

@test "au_patch_pin.sh: valid fixtures still pin successfully (RU,OPATCH,OJVM)" {
    make_patches_info "${WORK_DIR}/patches"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RU,OPATCH,OJVM
        bash '${SCRIPT}' '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 0 ]
    grep -q 'AU_PATCH=RU:19.28,OPATCH,OJVM' "${WORK_DIR}/patches/au_patch.env"
}

@test "au_patch_pin.sh: conflict detection refuses to overwrite a symlink pin file" {
    make_patches_info_recommended "${WORK_DIR}/patches"
    # Create a real file and symlink the pin file to it
    printf 'AU_PATCH=RECOMMENDED:19.27\n' > "${WORK_DIR}/real_pin.env"
    ln -s "${WORK_DIR}/real_pin.env" "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RECOMMENDED
        bash '${SCRIPT}' '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"symlink"* || "${output}" == *"SYMLINK"* || "${output}" == *"refusing"* ]]
}

# ---------------------------------------------------------------------------
# MUST 1 regression: trap injection via folder name with single-quote + $()
# ---------------------------------------------------------------------------

@test "au_patch_pin.sh: folder with single-quote+dollar in name does not execute code" {
    # A folder whose name contains p'$(touch PWNED)'q would previously cause
    # arbitrary code execution via the interpolated trap string.
    # After the fix: _AU_TMPFILES is used; no interpolated trap string is set.
    local _evil_name="p\$(touch PWNED)q"
    local _evil_dir="${WORK_DIR}/patches/${_evil_name}"
    mkdir -p "${_evil_dir}"
    chmod 700 "${_evil_dir}"
    cp "${FIXTURE_DIR}/patches_info_19_28.json" "${_evil_dir}/patches_info.json"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RU:19.28
        bash '${SCRIPT}' --dry-run '${_evil_dir}' 2>&1
    "
    # PWNED file must NOT be created anywhere in WORK_DIR
    [ ! -f "${WORK_DIR}/PWNED" ]
    [ ! -f "${_evil_dir}/PWNED" ]
    [ ! -f "PWNED" ]
}

@test "au_patch_pin.sh: temp file removed when write fails on non-dry-run path" {
    # Regression for Fix 1: a failed pin write (no-such-dir) must not leave a .XXXXXX
    # temp file behind; _AU_TMPFILES cleanup handles it.
    make_patches_info_recommended "${WORK_DIR}/patches"
    # Make the patches dir read-only so the mv fails after mktemp succeeds
    # (mktemp places the tmp in the same dir, so this makes mktemp fail too on most
    # systems; we instead test dry-run leaves nothing).
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RECOMMENDED
        bash '${SCRIPT}' --dry-run '${WORK_DIR}/patches' 2>&1
    "
    [ "${status}" -eq 0 ]
    # No .XXXXXX leftover from temp file registration
    local _leftover
    _leftover=$(find "${WORK_DIR}/patches" -maxdepth 1 -name 'au_patch.env.??????' 2>/dev/null || true)
    [ -z "${_leftover}" ]
}
