#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2030,SC2031
# ------------------------------------------------------------------------------
# tests/au_log_cleanup.bats
# BATS tests for bin/au_log_cleanup.sh and lib/au_logs.sh (WP8).
# ------------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    LIB="${REPO_ROOT}/lib/au_logs.sh"
    WORK_DIR="${BATS_TMPDIR}/au_log_cleanup_$$_${RANDOM}"
    mkdir -p "${WORK_DIR}"

    # Build a fixture log tree that mirrors the design table
    LOG_DIR="${WORK_DIR}/logs"
    mkdir -p "${LOG_DIR}/cfgtoollogs/patch/auto/aru"
    mkdir -p "${LOG_DIR}/cfgtoollogs/patch/auto/lock"

    # Keep-set files
    touch "${LOG_DIR}/cfgtoollogs/patch/auto/aru/request_id_cache.json"
    touch "${LOG_DIR}/cfgtoollogs/patch/auto/aru/abc123.csd"
    touch "${LOG_DIR}/cfgtoollogs/patch/auto/aru/def456.csd"
    touch "${LOG_DIR}/.ap_build"
    touch "${LOG_DIR}/cfgtoollogs/patch/auto/lock/au.lock"

    # Old log files (set mtime 60 days ago using touch -t)
    OLD_DATE=$(date -v-60d '+%Y%m%d%H%M' 2>/dev/null || date -d '60 days ago' '+%Y%m%d%H%M' 2>/dev/null || echo "202408010000")
    mkdir -p "${LOG_DIR}/cfgtoollogs/patch/auto"
    touch -t "${OLD_DATE}" "${LOG_DIR}/cfgtoollogs/patch/auto/autoupgrade.log"
    touch -t "${OLD_DATE}" "${LOG_DIR}/cfgtoollogs/patch/auto/aru/ous.log"

    # Newest job dir (within 30 days - keep)
    mkdir -p "${LOG_DIR}/job_001"
    touch "${LOG_DIR}/job_001/status.json"
    touch "${LOG_DIR}/job_001/progress.json"

    # Old job dirs (set mtime 60 days ago)
    mkdir -p "${LOG_DIR}/job_002"
    touch "${LOG_DIR}/job_002/status.json"
    touch -t "${OLD_DATE}" "${LOG_DIR}/job_002/status.json"
    touch -t "${OLD_DATE}" "${LOG_DIR}/job_002"

    mkdir -p "${LOG_DIR}/job_003"
    touch "${LOG_DIR}/job_003/status.json"
    touch -t "${OLD_DATE}" "${LOG_DIR}/job_003/status.json"
    touch -t "${OLD_DATE}" "${LOG_DIR}/job_003"

    mkdir -p "${LOG_DIR}/job_004"
    touch "${LOG_DIR}/job_004/status.json"
    touch -t "${OLD_DATE}" "${LOG_DIR}/job_004/status.json"
    touch -t "${OLD_DATE}" "${LOG_DIR}/job_004"

    # Symlink pointing outside the log dir (should be refused/skipped)
    ln -s /tmp "${LOG_DIR}/evil_link"

    export AU_LOG_DIR="${LOG_DIR}"
    # Stub AUTOUPGRADE_BASE so au_lib.sh does not redirect
    export AUTOUPGRADE_BASE="${WORK_DIR}"
    # Create minimal lib layout in WORK_DIR so SCRIPT can bootstrap
    mkdir -p "${WORK_DIR}/lib"
    cp "${REPO_ROOT}/lib/common.sh" "${WORK_DIR}/lib/"
    cp "${REPO_ROOT}/lib/au_lib.sh" "${WORK_DIR}/lib/"
    cp "${REPO_ROOT}/lib/au_env.sh" "${WORK_DIR}/lib/"
    cp "${REPO_ROOT}/lib/au_net.sh" "${WORK_DIR}/lib/"
    cp "${REPO_ROOT}/lib/au_tools.sh" "${WORK_DIR}/lib/"
    cp "${REPO_ROOT}/lib/au_logs.sh" "${WORK_DIR}/lib/"
    mkdir -p "${WORK_DIR}/bin"
    cp "${REPO_ROOT}/bin/au_log_cleanup.sh" "${WORK_DIR}/bin/"
    chmod +x "${WORK_DIR}/bin/au_log_cleanup.sh"
    WORK_SCRIPT="${WORK_DIR}/bin/au_log_cleanup.sh"

    # Stub pgrep so au_logs_is_au_running returns false (AU not running)
    mkdir -p "${WORK_DIR}/stubs"
    cat > "${WORK_DIR}/stubs/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "${WORK_DIR}/stubs/pgrep"
    export PATH="${WORK_DIR}/stubs:${PATH}"
}

teardown() {
    rm -rf "${WORK_DIR}"
}

# =============================================================================
# au_logs_validate_dir
# =============================================================================

@test "au_logs_validate_dir: accepts valid log dir" {
    run bash -c "
        source '${LIB_COMMON:-${REPO_ROOT}/lib/common.sh}'
        source '${LIB}'
        AU_LOG_DIR='${LOG_DIR}'
        au_logs_validate_dir
    "
    [ "${status}" -eq 0 ]
}

@test "au_logs_validate_dir: refuses unset AU_LOG_DIR" {
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${LIB}'
        unset AU_LOG_DIR
        au_logs_validate_dir 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not set"* ]]
}

@test "au_logs_validate_dir: refuses AU_LOG_DIR=/" {
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${LIB}'
        AU_LOG_DIR='/'
        au_logs_validate_dir 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must not be /"* ]]
}

@test "au_logs_validate_dir: refuses AU_LOG_DIR=\$HOME" {
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${LIB}'
        AU_LOG_DIR=\"\${HOME}\"
        au_logs_validate_dir 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must not equal"* ]]
}

@test "au_logs_validate_dir: refuses non-existent directory" {
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${LIB}'
        AU_LOG_DIR='${WORK_DIR}/does_not_exist'
        au_logs_validate_dir 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not a directory"* ]]
}

@test "au_logs_validate_dir: refuses dir without cfgtoollogs or .ap_build" {
    local empty_dir="${WORK_DIR}/empty_log"
    mkdir -p "${empty_dir}"
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${LIB}'
        AU_LOG_DIR='${empty_dir}'
        au_logs_validate_dir 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"does not look like"* ]]
}

# =============================================================================
# au_logs_in_keep_set
# =============================================================================

@test "au_logs_in_keep_set: request_id_cache.json is kept" {
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${LIB}'
        au_logs_in_keep_set 'cfgtoollogs/patch/auto/aru/request_id_cache.json'
    "
    [ "${status}" -eq 0 ]
}

@test "au_logs_in_keep_set: aru/*.csd is kept" {
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${LIB}'
        au_logs_in_keep_set 'cfgtoollogs/patch/auto/aru/abc123.csd'
    "
    [ "${status}" -eq 0 ]
}

@test "au_logs_in_keep_set: .ap_build is kept" {
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${LIB}'
        au_logs_in_keep_set '.ap_build'
    "
    [ "${status}" -eq 0 ]
}

@test "au_logs_in_keep_set: lock/ subtree is kept" {
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${LIB}'
        au_logs_in_keep_set 'cfgtoollogs/patch/auto/lock/au.lock'
    "
    [ "${status}" -eq 0 ]
}

@test "au_logs_in_keep_set: regular log file is NOT kept" {
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${LIB}'
        au_logs_in_keep_set 'cfgtoollogs/patch/auto/autoupgrade.log'
    "
    [ "${status}" -ne 0 ]
}

@test "au_logs_in_keep_set: aru/*.log is NOT kept" {
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${LIB}'
        au_logs_in_keep_set 'cfgtoollogs/patch/auto/aru/ous.log'
    "
    [ "${status}" -ne 0 ]
}

# =============================================================================
# au_log_cleanup.sh CLI
# =============================================================================

@test "au_log_cleanup.sh: --help exits 0 and shows usage" {
    run "${WORK_SCRIPT}" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage:"* ]]
    [[ "${output}" == *"--delete"* ]]
    [[ "${output}" == *"--keep-jobs"* ]]
}

@test "au_log_cleanup.sh: --version exits 0" {
    run "${WORK_SCRIPT}" --version
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"au_log_cleanup.sh"* ]]
}

@test "au_log_cleanup.sh: refuses AU_LOG_DIR=/" {
    run bash -c "AU_LOG_DIR='/' '${WORK_SCRIPT}' --log-dir / 2>&1"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must not be /"* ]]
}

@test "au_log_cleanup.sh: refuses non-existent --log-dir" {
    run bash -c "'${WORK_SCRIPT}' --log-dir '${WORK_DIR}/no_such_dir' 2>&1"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not a directory"* ]]
}

@test "au_log_cleanup.sh: default listing shows WOULD DELETE for old files" {
    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --older-than 0 -v 2>&1"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WOULD DELETE"* ]]
}

@test "au_log_cleanup.sh: default listing shows KEEP for keep-set entries" {
    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --older-than 0 -v 2>&1"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"KEEP"* ]]
    [[ "${output}" == *"keep-set"* ]]
}

@test "au_log_cleanup.sh: --dry-run does not delete files" {
    local before_count
    before_count=$(find "${LOG_DIR}" -type f | wc -l)
    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --older-than 0 --dry-run 2>&1"
    [ "${status}" -eq 0 ]
    local after_count
    after_count=$(find "${LOG_DIR}" -type f | wc -l)
    [ "${before_count}" -eq "${after_count}" ]
}

@test "au_log_cleanup.sh: --dry-run overrides --delete" {
    local before_count
    before_count=$(find "${LOG_DIR}" -type f | wc -l)
    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --older-than 0 --delete --dry-run --yes 2>&1"
    [ "${status}" -eq 0 ]
    local after_count
    after_count=$(find "${LOG_DIR}" -type f | wc -l)
    [ "${before_count}" -eq "${after_count}" ]
    [[ "${output}" == *"overrides"* ]]
}

@test "au_log_cleanup.sh: --delete --yes actually removes old files" {
    # Verify autoupgrade.log exists before deletion
    [ -f "${LOG_DIR}/cfgtoollogs/patch/auto/autoupgrade.log" ]
    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --older-than 0 --delete --yes 2>&1"
    [ "${status}" -eq 0 ]
    # Old log file should be gone
    [ ! -f "${LOG_DIR}/cfgtoollogs/patch/auto/autoupgrade.log" ]
}

@test "au_log_cleanup.sh: --delete --yes preserves keep-set" {
    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --older-than 0 --delete --yes 2>&1"
    [ "${status}" -eq 0 ]
    # All keep-set files must still exist
    [ -f "${LOG_DIR}/cfgtoollogs/patch/auto/aru/request_id_cache.json" ]
    [ -f "${LOG_DIR}/cfgtoollogs/patch/auto/aru/abc123.csd" ]
    [ -f "${LOG_DIR}/cfgtoollogs/patch/auto/aru/def456.csd" ]
    [ -f "${LOG_DIR}/.ap_build" ]
    [ -f "${LOG_DIR}/cfgtoollogs/patch/auto/lock/au.lock" ]
}

@test "au_log_cleanup.sh: --keep-jobs 3 preserves newest N job dirs" {
    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --older-than 0 --delete --yes --keep-jobs 3 2>&1"
    [ "${status}" -eq 0 ]
    # job_001 is newest (fresh mtime) - must be kept
    [ -d "${LOG_DIR}/job_001" ]
}

@test "au_log_cleanup.sh: symlink escaping log dir is skipped with warning" {
    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --older-than 0 -v 2>&1"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"SKIP"* ]] || [[ "${output}" == *"symlink"* ]]
}

@test "au_log_cleanup.sh: invalid --older-than value is rejected" {
    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --older-than notanumber 2>&1"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"non-negative integer"* ]]
}

@test "au_log_cleanup.sh: invalid --keep-jobs value is rejected" {
    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --keep-jobs abc 2>&1"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"non-negative integer"* ]]
}

@test "au_log_cleanup.sh: refuses when autoupgrade is running" {
    # Replace the pgrep stub with one that reports AU as running
    cat > "${WORK_DIR}/stubs/pgrep" <<'STUB'
#!/usr/bin/env bash
# Simulate autoupgrade running
exit 0
STUB
    chmod +x "${WORK_DIR}/stubs/pgrep"
    run bash -c "export PATH='${WORK_DIR}/stubs:${PATH}'; AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' 2>&1"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"appears to be running"* ]]
}

@test "au_log_cleanup.sh: unknown option exits non-zero" {
    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --unknown-flag 2>&1"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Unknown option"* ]]
}
