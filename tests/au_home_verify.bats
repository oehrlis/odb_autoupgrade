#!/usr/bin/env bats
# shellcheck disable=SC1090
# ------------------------------------------------------------------------------
# tests/au_home_verify.bats
# BATS tests for bin/au_home_verify.sh and lib/au_home.sh (WP9).
# ------------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    SCRIPT="${REPO_ROOT}/bin/au_home_verify.sh"
    LIB="${REPO_ROOT}/lib/au_lib.sh"
    WORK_DIR="${BATS_TMPDIR}/au_home_verify_test_$$_${RANDOM}"
    mkdir -p "${WORK_DIR}/etc" "${WORK_DIR}/patches" "${WORK_DIR}/logs" \
             "${WORK_DIR}/keystore"
    chmod 700 "${WORK_DIR}" "${WORK_DIR}/etc" "${WORK_DIR}/patches" \
              "${WORK_DIR}/logs" "${WORK_DIR}/keystore"

    # Stub homes for testing
    FAKE_SRC="${WORK_DIR}/src_home"
    FAKE_TGT="${WORK_DIR}/tgt_home"
    mkdir -p "${FAKE_SRC}/rdbms/lib" "${FAKE_TGT}/rdbms/lib"
    mkdir -p "${FAKE_SRC}/OPatch" "${FAKE_TGT}/OPatch"

    export AUTOUPGRADE_BASE="${WORK_DIR}"

    # Stub PATH directory for mocked commands
    STUB_DIR="${WORK_DIR}/stubs"
    mkdir -p "${STUB_DIR}"
    export PATH="${STUB_DIR}:${PATH}"
}

teardown() {
    rm -rf "${WORK_DIR}"
    unset AUTOUPGRADE_BASE
}

# ---------------------------------------------------------------------------
# Helpers: create fixture config.c and mocked ar
# ---------------------------------------------------------------------------

_make_config_c() {
    local _home="$1"
    cat > "${_home}/rdbms/lib/config.c" <<'CONFIGC'
/* Fake config.c for testing */
#define SS_DBA_GRP   "dba"
#define SS_OPER_GRP  "oper"
#define SS_BKP_GRP   "backupdba"
#define SS_DGD_GRP   "dgdba"
#define SS_KMT_GRP   "kmdba"
#define SS_RAC_GRP   "racdba"
CONFIGC
}

_make_ar_stub() {
    # Create mocked ar that returns a fixed libknlopt.a listing
    local _stub="${STUB_DIR}/ar"
    cat > "${_stub}" <<'ARSTUB'
#!/usr/bin/env bash
# Mocked ar: returns a fixed listing for -t
if [[ "$1" == "-t" ]]; then
    printf 'kfon.o\njox.o\n'
    exit 0
fi
exit 0
ARSTUB
    chmod +x "${_stub}"
}

_make_opatch_stub() {
    local _home="$1"
    local _patches="${2:-36233126;Database Release Update : 19.32.0.0.241015}"
    cat > "${_home}/OPatch/opatch" <<OPATCH
#!/usr/bin/env bash
if [[ "\$1" == "lspatches" ]]; then
    printf '%s\n' "${_patches}"
    exit 0
fi
exit 0
OPATCH
    chmod +x "${_home}/OPatch/opatch"
}

_make_patches_json() {
    local _folder="$1"
    cat > "${_folder}/patches_info.json" <<'JSON'
{
  "patches": [
    {"patchId": "36233126", "releaseUpdate": "19.32.0.0.0"},
    {"patchId": "36233127", "releaseUpdate": "19.32.0.0.0"}
  ]
}
JSON
}

# ---------------------------------------------------------------------------
# au_home_read_groups tests (lib/au_home.sh)
# ---------------------------------------------------------------------------

@test "au_home_read_groups: reads groups from config.c" {
    _make_config_c "${FAKE_SRC}"
    run bash -c "
        source '${LIB}'
        source '${REPO_ROOT}/lib/au_home.sh'
        au_home_read_groups '${FAKE_SRC}'
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"osdba_group=dba"* ]]
    [[ "${output}" == *"osoper_group=oper"* ]]
    [[ "${output}" == *"osbackupdba_group=backupdba"* ]]
    [[ "${output}" == *"osdgdba_group=dgdba"* ]]
    [[ "${output}" == *"oskmdba_group=kmdba"* ]]
    [[ "${output}" == *"osracdba_group=racdba"* ]]
}

@test "au_home_read_groups: accepts direct config.c path" {
    _make_config_c "${FAKE_SRC}"
    run bash -c "
        source '${LIB}'
        source '${REPO_ROOT}/lib/au_home.sh'
        au_home_read_groups '${FAKE_SRC}/rdbms/lib/config.c'
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"osdba_group=dba"* ]]
}

@test "au_home_read_groups: fails when config.c not found" {
    run bash -c "
        source '${LIB}'
        source '${REPO_ROOT}/lib/au_home.sh'
        au_home_read_groups '${FAKE_SRC}'
    " 2>&1
    [ "${status}" -ne 0 ]
}

@test "au_home_read_groups: fails on empty argument" {
    run bash -c "
        source '${LIB}'
        source '${REPO_ROOT}/lib/au_home.sh'
        au_home_read_groups ''
    " 2>&1
    [ "${status}" -ne 0 ]
}

# ---------------------------------------------------------------------------
# au_home_target_name tests (lib/au_home.sh)
# ---------------------------------------------------------------------------

@test "au_home_target_name: two-part RU expands to four parts" {
    run bash -c "
        source '${LIB}'
        source '${REPO_ROOT}/lib/au_home.sh'
        au_home_target_name '/u01/app/oracle' '19.32'
    "
    [ "${status}" -eq 0 ]
    [ "${output}" = "/u01/app/oracle/product/19.32.0.0" ]
}

@test "au_home_target_name: four-part RU passed through" {
    run bash -c "
        source '${LIB}'
        source '${REPO_ROOT}/lib/au_home.sh'
        au_home_target_name '/u01/app/oracle' '19.32.0.0'
    "
    [ "${status}" -eq 0 ]
    [ "${output}" = "/u01/app/oracle/product/19.32.0.0" ]
}

@test "au_home_target_name: suffix _2 when base path exists" {
    mkdir -p "${WORK_DIR}/product/19.32.0.0"
    run bash -c "
        source '${LIB}'
        source '${REPO_ROOT}/lib/au_home.sh'
        au_home_target_name '${WORK_DIR}' '19.32' '${WORK_DIR}/product/19.32.0.0'
    "
    [ "${status}" -eq 0 ]
    [ "${output}" = "${WORK_DIR}/product/19.32.0.0_2" ]
}

@test "au_home_target_name: suffix _3 when _2 also exists" {
    local _existing
    _existing="${WORK_DIR}/product/19.32.0.0
${WORK_DIR}/product/19.32.0.0_2"
    run bash -c "
        source '${LIB}'
        source '${REPO_ROOT}/lib/au_home.sh'
        au_home_target_name '${WORK_DIR}' '19.32.0.0' '${_existing}'
    "
    [ "${status}" -eq 0 ]
    [ "${output}" = "${WORK_DIR}/product/19.32.0.0_3" ]
}

@test "au_home_target_name: invalid RU format fails" {
    run bash -c "
        source '${LIB}'
        source '${REPO_ROOT}/lib/au_home.sh'
        au_home_target_name '/u01/app/oracle' 'notvalid'
    " 2>&1
    [ "${status}" -ne 0 ]
}

# ---------------------------------------------------------------------------
# au_home_list_binopts tests (lib/au_home.sh)
# ---------------------------------------------------------------------------

@test "au_home_list_binopts: reads options from mocked ar" {
    _make_ar_stub
    # Create a fake libknlopt.a
    touch "${FAKE_SRC}/rdbms/lib/libknlopt.a"
    run bash -c "
        source '${LIB}'
        source '${REPO_ROOT}/lib/au_home.sh'
        au_home_list_binopts '${FAKE_SRC}'
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"asm=on"* ]]
    [[ "${output}" == *"java=on"* ]]
    [[ "${output}" == *"rac=off"* ]]
}

@test "au_home_list_binopts: fails when libknlopt.a not found" {
    run bash -c "
        source '${LIB}'
        source '${REPO_ROOT}/lib/au_home.sh'
        au_home_list_binopts '${FAKE_SRC}'
    " 2>&1
    [ "${status}" -ne 0 ]
}

# ---------------------------------------------------------------------------
# au_home_verify.sh --help and basic validation
# ---------------------------------------------------------------------------

@test "au_home_verify.sh: --help exits 0" {
    run bash "${SCRIPT}" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--home"* ]]
}

@test "au_home_verify.sh: missing --home exits non-zero" {
    run bash "${SCRIPT}" 2>&1
    [ "${status}" -ne 0 ]
}

@test "au_home_verify.sh: invalid --home exits non-zero" {
    run bash "${SCRIPT}" --home /nonexistent/path 2>&1
    [ "${status}" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Patch check
# ---------------------------------------------------------------------------

@test "au_home_verify.sh: patch check passes when all patches present" {
    _make_opatch_stub "${FAKE_TGT}" "36233126;Database Release Update 19.32
36233127;OJVM Release Update 19.32"
    _make_patches_json "${WORK_DIR}/patches"

    run bash "${SCRIPT}" --verbose \
        --home "${FAKE_TGT}" \
        --patches-json "${WORK_DIR}/patches/patches_info.json" \
        --no-binopts --no-groups 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PASS"* ]]
}

@test "au_home_verify.sh: patch check fails when patch missing" {
    # Only patch 36233126 installed, but 36233127 expected
    _make_opatch_stub "${FAKE_TGT}" "36233126;Database Release Update 19.32"
    _make_patches_json "${WORK_DIR}/patches"

    run bash "${SCRIPT}" --verbose \
        --home "${FAKE_TGT}" \
        --patches-json "${WORK_DIR}/patches/patches_info.json" \
        --no-binopts --no-groups 2>&1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"FAIL"* ]] || [[ "${output}" == *"missing"* ]]
}

# ---------------------------------------------------------------------------
# Groups check
# ---------------------------------------------------------------------------

@test "au_home_verify.sh: group check passes when groups match" {
    _make_config_c "${FAKE_SRC}"
    _make_config_c "${FAKE_TGT}"

    run bash "${SCRIPT}" --verbose \
        --home "${FAKE_TGT}" \
        --source-home "${FAKE_SRC}" \
        --no-patches --no-binopts 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PASS"* ]]
}

@test "au_home_verify.sh: group check fails when groups differ" {
    _make_config_c "${FAKE_SRC}"
    # target has different dba group
    cat > "${FAKE_TGT}/rdbms/lib/config.c" <<'CONFIGC'
#define SS_DBA_GRP   "oinstall"
#define SS_OPER_GRP  "oper"
#define SS_BKP_GRP   "backupdba"
#define SS_DGD_GRP   "dgdba"
#define SS_KMT_GRP   "kmdba"
#define SS_RAC_GRP   "racdba"
CONFIGC

    run bash "${SCRIPT}" --verbose \
        --home "${FAKE_TGT}" \
        --source-home "${FAKE_SRC}" \
        --no-patches --no-binopts 2>&1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"FAIL"* ]] || [[ "${output}" == *"osdba_group"* ]]
}

# ---------------------------------------------------------------------------
# Binary options check
# ---------------------------------------------------------------------------

@test "au_home_verify.sh: binopt check skipped without source home" {
    _make_config_c "${FAKE_TGT}"
    run bash "${SCRIPT}" \
        --home "${FAKE_TGT}" \
        --no-patches --no-groups 2>&1
    # Should warn and skip, not fail
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"skip"* ]] || [[ "${output}" == *"require"* ]] || \
        [[ "${output}" == *"source"* ]]
}

@test "au_home_verify.sh: binopt check passes when options match" {
    _make_ar_stub
    touch "${FAKE_SRC}/rdbms/lib/libknlopt.a"
    touch "${FAKE_TGT}/rdbms/lib/libknlopt.a"

    run bash "${SCRIPT}" --verbose \
        --home "${FAKE_TGT}" \
        --source-home "${FAKE_SRC}" \
        --no-patches --no-groups 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PASS"* ]]
}
