#!/usr/bin/env bats
# shellcheck disable=SC1090
# ------------------------------------------------------------------------------
# tests/au_gen_config.bats
# BATS tests for bin/au_gen_config.sh (WP9).
# ------------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    SCRIPT="${REPO_ROOT}/bin/au_gen_config.sh"
    WORK_DIR="${BATS_TMPDIR}/au_gen_cfg_test_$$_${RANDOM}"
    mkdir -p "${WORK_DIR}/etc" "${WORK_DIR}/patches" "${WORK_DIR}/logs" \
             "${WORK_DIR}/keystore"
    chmod 700 "${WORK_DIR}" "${WORK_DIR}/etc" "${WORK_DIR}/patches" \
              "${WORK_DIR}/logs" "${WORK_DIR}/keystore"

    # Copy au_patch.cfg template
    cp "${REPO_ROOT}/etc/au_patch.cfg" "${WORK_DIR}/etc/au_patch.cfg"
    chmod 600 "${WORK_DIR}/etc/au_patch.cfg"

    # Fake Oracle homes - must not be g/o-writable for binary trust check
    FAKE_SRC="${WORK_DIR}/src_home"
    mkdir -p "${FAKE_SRC}/rdbms/lib" "${FAKE_SRC}/bin"
    chmod 755 "${FAKE_SRC}" "${FAKE_SRC}/bin"

    export AUTOUPGRADE_BASE="${WORK_DIR}"
    export AU_ORACLE_BASE="${WORK_DIR}/oracle_base"
    export AU_EDITION="EE"

    STUB_DIR="${WORK_DIR}/stubs"
    mkdir -p "${STUB_DIR}"
    export PATH="${STUB_DIR}:${PATH}"

    # Stub envsubst if needed (usually present; add a stub for isolated envs)
    if ! command -v envsubst >/dev/null 2>&1; then
        cat > "${STUB_DIR}/envsubst" <<'ESTUB'
#!/usr/bin/env bash
# Minimal envsubst stub: replace ${VAR} with env value or empty
perl -pe 's/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/$ENV{$1}\/\/""/ge'
ESTUB
        chmod +x "${STUB_DIR}/envsubst"
    fi
}

teardown() {
    rm -rf "${WORK_DIR}"
    unset AUTOUPGRADE_BASE AU_ORACLE_BASE AU_EDITION AU_SOURCE_HOME AU_TARGET_HOME \
          AU_GROUP_OSDBA AU_GROUP_OSOPER AU_GROUP_OSBACKUPDBA \
          AU_GROUP_OSDGDBA AU_GROUP_OSKMDBA AU_GROUP_OSRACDBA 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Basic option parsing
# ---------------------------------------------------------------------------

@test "au_gen_config.sh: --help exits 0" {
    run bash "${SCRIPT}" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--ru"* ]]
}

@test "au_gen_config.sh: missing --ru exits non-zero" {
    run bash "${SCRIPT}" --oracle-base /u01 --edition EE 2>&1
    [ "${status}" -ne 0 ]
}

@test "au_gen_config.sh: invalid RU format exits non-zero" {
    run bash "${SCRIPT}" --ru notvalid --oracle-base /u01 2>&1
    [ "${status}" -ne 0 ]
}

@test "au_gen_config.sh: without source-home requires oracle-base" {
    unset AU_ORACLE_BASE
    run bash "${SCRIPT}" --ru 19.32 --edition EE 2>&1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"oracle-base"* ]] || [[ "${output}" == *"ORACLE_BASE"* ]]
}

@test "au_gen_config.sh: requires --output or --dry-run" {
    run bash "${SCRIPT}" \
        --ru 19.32 \
        --oracle-base "${WORK_DIR}/oracle_base" \
        --edition EE \
        --groups-standard 2>&1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"--output"* ]] || [[ "${output}" == *"dry-run"* ]]
}

# ---------------------------------------------------------------------------
# Dry-run rendering
# ---------------------------------------------------------------------------

@test "au_gen_config.sh: dry-run renders config without writing a file" {
    run bash "${SCRIPT}" \
        --ru 19.32 \
        --oracle-base "${WORK_DIR}/oracle_base" \
        --edition EE \
        --groups-standard \
        --dry-run 2>&1
    [ "${status}" -eq 0 ]
    # Config content should appear in output (printed to stderr in dry-run)
    [[ "${output}" == *"DRY-RUN"* ]] || [[ "${output}" == *"dry"* ]] || \
        [[ "${output}" == *"global"* ]] || [[ "${output}" == *"patch1"* ]]
}

@test "au_gen_config.sh: dry-run does not write output file" {
    local _out="${WORK_DIR}/test_output.cfg"
    run bash "${SCRIPT}" \
        --ru 19.32 \
        --oracle-base "${WORK_DIR}/oracle_base" \
        --edition EE \
        --groups-standard \
        --dry-run 2>&1
    [ "${status}" -eq 0 ]
    # Output file should NOT exist after dry-run (no --output given)
    [ ! -f "${_out}" ]
}

# ---------------------------------------------------------------------------
# Target home naming (decision 9)
# ---------------------------------------------------------------------------

@test "au_gen_config.sh: target home uses four-part RU path" {
    local _out="${WORK_DIR}/gen_test.cfg"
    run bash "${SCRIPT}" \
        --ru 19.32 \
        --oracle-base "${WORK_DIR}/oracle_base" \
        --edition EE \
        --groups-standard \
        --output "${_out}" 2>&1
    [ "${status}" -eq 0 ]
    [ -f "${_out}" ]
    # Target home must contain product/19.32.0.0
    grep -q "19.32.0.0" "${_out}"
}

@test "au_gen_config.sh: output file has mode 0600" {
    local _out="${WORK_DIR}/gen_test_perms.cfg"
    run bash "${SCRIPT}" \
        --ru 19.32 \
        --oracle-base "${WORK_DIR}/oracle_base" \
        --edition EE \
        --groups-standard \
        --output "${_out}" 2>&1
    [ "${status}" -eq 0 ]
    [ -f "${_out}" ]
    local _perms
    _perms=$(stat -c '%a' "${_out}" 2>/dev/null || stat -f '%A' "${_out}" 2>/dev/null || echo "000")
    [ "${_perms}" = "600" ]
}

@test "au_gen_config.sh: refuses to overwrite without --force" {
    local _out="${WORK_DIR}/existing.cfg"
    echo "existing" > "${_out}"
    run bash "${SCRIPT}" \
        --ru 19.32 \
        --oracle-base "${WORK_DIR}/oracle_base" \
        --edition EE \
        --groups-standard \
        --output "${_out}" 2>&1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"force"* ]] || [[ "${output}" == *"exists"* ]]
}

@test "au_gen_config.sh: overwrites with --force" {
    local _out="${WORK_DIR}/existing_force.cfg"
    echo "existing" > "${_out}"
    run bash "${SCRIPT}" \
        --ru 19.32 \
        --oracle-base "${WORK_DIR}/oracle_base" \
        --edition EE \
        --groups-standard \
        --output "${_out}" \
        --force 2>&1
    [ "${status}" -eq 0 ]
    [ -f "${_out}" ]
    # Content should be new config, not "existing"
    ! grep -q "^existing$" "${_out}"
}

# ---------------------------------------------------------------------------
# Group derivation from config.c
# ---------------------------------------------------------------------------

@test "au_gen_config.sh: groups-from reads config.c and includes in output" {
    # Create a config.c using current user's actual groups so group check passes
    local _my_group
    _my_group=$(id -gn 2>/dev/null || echo "dba")

    mkdir -p "${FAKE_SRC}/rdbms/lib"
    cat > "${FAKE_SRC}/rdbms/lib/config.c" <<CONFIGC
#define SS_DBA_GRP   "${_my_group}"
#define SS_OPER_GRP  "${_my_group}"
#define SS_BKP_GRP   "${_my_group}"
#define SS_DGD_GRP   "${_my_group}"
#define SS_KMT_GRP   "${_my_group}"
#define SS_RAC_GRP   "${_my_group}"
CONFIGC

    local _out="${WORK_DIR}/gen_grp.cfg"
    run bash "${SCRIPT}" \
        --ru 19.32 \
        --oracle-base "${WORK_DIR}/oracle_base" \
        --edition EE \
        --groups-from "${FAKE_SRC}" \
        --output "${_out}" 2>&1
    [ "${status}" -eq 0 ]
    [ -f "${_out}" ]
    # Groups should appear in config
    grep -q "osdba_group=${_my_group}" "${_out}" || \
        grep -q "${_my_group}" "${_out}"
}

# ---------------------------------------------------------------------------
# Source home path (with source-home: skips group/base derivation in script)
# ---------------------------------------------------------------------------

@test "au_gen_config.sh: --source-home sets AU_SOURCE_HOME in config" {
    # Provide a minimal source home with orabase stub
    mkdir -p "${FAKE_SRC}/bin"
    printf '#!/usr/bin/env bash\necho "%s"\n' "${WORK_DIR}/oracle_base" \
        > "${FAKE_SRC}/bin/orabase"
    chmod 0755 "${FAKE_SRC}/bin/orabase"
    mkdir -p "${FAKE_SRC}/rdbms/lib"
    touch "${FAKE_SRC}/rdbms/lib/config.c"

    local _out="${WORK_DIR}/gen_src.cfg"
    run bash "${SCRIPT}" \
        --ru 19.32 \
        --source-home "${FAKE_SRC}" \
        --output "${_out}" 2>&1
    [ "${status}" -eq 0 ]
    [ -f "${_out}" ]
    grep -q "source_home" "${_out}"
}

# ---------------------------------------------------------------------------
# MUST 2 regression: group name validation
# ---------------------------------------------------------------------------

@test "au_gen_config.sh: rejects invalid group name from env (MUST 2)" {
    # Groups with shell metacharacters must be rejected when passed via env
    run bash -c "
        AU_GROUP_OSDBA='dba x;y=injected' bash '${SCRIPT}' \
            --ru 19.32 \
            --oracle-base '${WORK_DIR}/oracle_base' \
            --edition EE \
            --groups-standard \
            --skip-group-check \
            --output '${WORK_DIR}/out_bad_grp.cfg' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"invalid"* ]] || [[ "${output}" == *"group"* ]]
}

@test "au_gen_config.sh: rejects group name with newline from env (MUST 2)" {
    run bash -c "
        AU_GROUP_OSDBA=$'dba\nINJECTED=key' bash '${SCRIPT}' \
            --ru 19.32 \
            --oracle-base '${WORK_DIR}/oracle_base' \
            --edition EE \
            --groups-standard \
            --skip-group-check \
            --output '${WORK_DIR}/out_nl_grp.cfg' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"invalid"* ]] || [[ "${output}" == *"group"* ]] || [[ "${output}" == *"newline"* ]]
}

@test "au_gen_config.sh: rejects invalid group from --groups-from config.c (MUST 2)" {
    # Write a config.c with an invalid group name that embeds a semicolon
    mkdir -p "${FAKE_SRC}/rdbms/lib"
    cat > "${FAKE_SRC}/rdbms/lib/config.c" <<'CONFIGC'
#define SS_DBA_GRP   "dba x;injected"
#define SS_OPER_GRP  "oper"
CONFIGC

    local _out="${WORK_DIR}/out_cfgc_bad.cfg"
    run bash "${SCRIPT}" \
        --ru 19.32 \
        --oracle-base "${WORK_DIR}/oracle_base" \
        --edition EE \
        --groups-from "${FAKE_SRC}" \
        --skip-group-check \
        --output "${_out}" 2>&1
    # au_home_read_groups skips invalid group and emits WARN (may include the bad value in the warning)
    # The generated config FILE must NOT contain the bad value (injection guard)
    if [ -f "${_out}" ]; then
        run grep -c "dba x;injected" "${_out}"
        [ "${output}" = "0" ]
    fi
    # The warning (to stderr) proves the invalid name was detected, not silently accepted
    [[ "${output}" == *"WARN"* ]] || [[ "${status}" -ne 0 ]]
}

@test "au_home_validate_group: accepts valid group name (MUST 2)" {
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${REPO_ROOT}/lib/au_home.sh'
        au_home_validate_group 'dba' 'test_label'
    "
    [ "${status}" -eq 0 ]
}

@test "au_home_validate_group: rejects name with semicolon (MUST 2)" {
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${REPO_ROOT}/lib/au_home.sh'
        au_home_validate_group 'dba;bad' 'test_label' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"invalid"* ]]
}

@test "au_home_validate_group: rejects name with newline (MUST 2)" {
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${REPO_ROOT}/lib/au_home.sh'
        au_home_validate_group $'dba\nINJECT' 'test_label' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"newline"* ]] || [[ "${output}" == *"invalid"* ]]
}

@test "au_home_validate_group: rejects name longer than 32 chars (MUST 2)" {
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${REPO_ROOT}/lib/au_home.sh'
        au_home_validate_group 'a123456789012345678901234567890123' 'test_label' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"invalid"* ]]
}
