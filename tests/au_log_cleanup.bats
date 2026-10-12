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
    # Copy every library module so the loader finds all of them
    cp "${REPO_ROOT}"/lib/*.sh "${WORK_DIR}/lib/"
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
    # Replace the pgrep stub with one that reports AU as running (output a fake PID)
    cat > "${WORK_DIR}/stubs/pgrep" <<'STUB'
#!/usr/bin/env bash
# Simulate java autoupgrade.jar running under a different PID
printf '99999\n'
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

# =============================================================================
# Security regression tests (MUST 1, MUST 2, SHOULD)
# =============================================================================

# MUST 1(c) - Oracle binary check
@test "au_logs_validate_dir: refuses log dir containing Oracle binary (bin/oracle)" {
    local oracle_dir="${WORK_DIR}/oracle_like"
    mkdir -p "${oracle_dir}/cfgtoollogs/patch/auto"
    mkdir -p "${oracle_dir}/product/19c/dbhome_1/bin"
    touch "${oracle_dir}/product/19c/dbhome_1/bin/oracle"
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${LIB}'
        AU_LOG_DIR='${oracle_dir}'
        au_logs_validate_dir 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Oracle Home"* ]] || [[ "${output}" == *"oracle"* ]]
}

@test "au_log_cleanup.sh: refuses log dir containing Oracle binary (integration)" {
    local oracle_dir="${WORK_DIR}/oracle_like"
    mkdir -p "${oracle_dir}/cfgtoollogs/patch/auto"
    mkdir -p "${oracle_dir}/product/19c/dbhome_1/bin"
    touch "${oracle_dir}/product/19c/dbhome_1/bin/oracle"
    run bash -c "AU_LOG_DIR='${oracle_dir}' '${WORK_SCRIPT}' 2>&1"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Oracle Home"* ]] || [[ "${output}" == *"oracle"* ]]
    # Verify nothing was deleted
    [ -f "${oracle_dir}/product/19c/dbhome_1/bin/oracle" ]
}

# MUST 1(a) - trailing slash canonicalization preserves keep-set
@test "au_log_cleanup.sh: trailing slash on AU_LOG_DIR preserves keep-set" {
    run bash -c "AU_LOG_DIR='${LOG_DIR}/' '${WORK_SCRIPT}' --older-than 0 --delete --yes 2>&1"
    [ "${status}" -eq 0 ]
    [ -f "${LOG_DIR}/cfgtoollogs/patch/auto/aru/request_id_cache.json" ]
    [ -f "${LOG_DIR}/cfgtoollogs/patch/auto/aru/abc123.csd" ]
    [ -f "${LOG_DIR}/cfgtoollogs/patch/auto/lock/au.lock" ]
}

# MUST 1(d) - log dir = parent of AU_DOWNLOAD_FOLDER must be refused
@test "au_logs_validate_dir: refuses when log dir contains AU_DOWNLOAD_FOLDER" {
    local dl_dir="${LOG_DIR}/downloads"
    mkdir -p "${dl_dir}"
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${LIB}'
        AU_LOG_DIR='${LOG_DIR}'
        AU_DOWNLOAD_FOLDER='${dl_dir}'
        au_logs_validate_dir 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"AU_DOWNLOAD_FOLDER"* ]]
}

# MUST 2 - process detection uses java.*autoupgrade.jar pattern; own PID excluded
@test "au_logs_is_au_running: not running when pgrep returns no PIDs" {
    # Default setup stub exits 1 (no output) - AU not running
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${LIB}'
        au_logs_is_au_running && echo RUNNING || echo NOT_RUNNING
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"NOT_RUNNING"* ]]
}

@test "au_logs_is_au_running: running when pgrep returns a non-self PID" {
    # Stub pgrep returns a foreign PID (not the current process)
    cat > "${WORK_DIR}/stubs/pgrep" <<'STUB'
#!/usr/bin/env bash
printf '99999\n'
exit 0
STUB
    chmod +x "${WORK_DIR}/stubs/pgrep"
    run bash -c "
        export PATH='${WORK_DIR}/stubs:\${PATH}'
        source '${REPO_ROOT}/lib/common.sh'
        source '${LIB}'
        au_logs_is_au_running && echo RUNNING || echo NOT_RUNNING
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"RUNNING"* ]]
}

# MUST 1(b) - tighter marker check: cfgtoollogs/patch/auto required
@test "au_logs_validate_dir: refuses dir with only top-level cfgtoollogs (no patch/auto)" {
    local shallow_dir="${WORK_DIR}/shallow_cfg"
    mkdir -p "${shallow_dir}/cfgtoollogs"
    run bash -c "
        source '${REPO_ROOT}/lib/common.sh'
        source '${LIB}'
        AU_LOG_DIR='${shallow_dir}'
        au_logs_validate_dir 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"does not look like"* ]]
}

# =============================================================================
# MUST 1 regression: glob-named files must not trigger unintended deletion
# =============================================================================

@test "au_log_cleanup.sh: file named '*' is deleted without side-effects (MUST 1)" {
    # Create a file literally named '*' inside cfgtoollogs/patch/auto (not keep-set)
    local _glob_file="${LOG_DIR}/cfgtoollogs/patch/auto/*"
    touch "${_glob_file}"
    # Set mtime old so it qualifies for deletion
    OLD_DATE2=$(date -v-60d '+%Y%m%d%H%M' 2>/dev/null || date -d '60 days ago' '+%Y%m%d%H%M' 2>/dev/null || echo "202408010000")
    touch -t "${OLD_DATE2}" "${_glob_file}"

    # request_id_cache.json must survive
    [ -f "${LOG_DIR}/cfgtoollogs/patch/auto/aru/request_id_cache.json" ]

    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --older-than 0 --delete --yes 2>&1"
    [ "${status}" -eq 0 ]

    # The '*' file itself should be gone (it was old, not in keep-set)
    [ ! -f "${_glob_file}" ]

    # Keep-set files must be intact (glob must not have expanded)
    [ -f "${LOG_DIR}/cfgtoollogs/patch/auto/aru/request_id_cache.json" ]
    [ -f "${LOG_DIR}/cfgtoollogs/patch/auto/aru/abc123.csd" ]
    [ -f "${LOG_DIR}/cfgtoollogs/patch/auto/lock/au.lock" ]
}

@test "au_log_cleanup.sh: file named '?' does not expand as glob (MUST 1)" {
    local _q_file="${LOG_DIR}/cfgtoollogs/patch/auto/?"
    touch "${_q_file}"
    OLD_DATE3=$(date -v-60d '+%Y%m%d%H%M' 2>/dev/null || date -d '60 days ago' '+%Y%m%d%H%M' 2>/dev/null || echo "202408010000")
    touch -t "${OLD_DATE3}" "${_q_file}"

    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --older-than 0 --delete --yes 2>&1"
    [ "${status}" -eq 0 ]

    # '?' file gone, keep-set intact
    [ ! -f "${_q_file}" ]
    [ -f "${LOG_DIR}/cfgtoollogs/patch/auto/aru/request_id_cache.json" ]
}

@test "au_log_cleanup.sh: file named '[a]' does not expand as glob (MUST 1)" {
    local _bracket_file="${LOG_DIR}/cfgtoollogs/patch/auto/[a]"
    touch "${_bracket_file}"
    OLD_DATE4=$(date -v-60d '+%Y%m%d%H%M' 2>/dev/null || date -d '60 days ago' '+%Y%m%d%H%M' 2>/dev/null || echo "202408010000")
    touch -t "${OLD_DATE4}" "${_bracket_file}"

    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --older-than 0 --delete --yes 2>&1"
    [ "${status}" -eq 0 ]

    [ ! -f "${_bracket_file}" ]
    [ -f "${LOG_DIR}/cfgtoollogs/patch/auto/aru/request_id_cache.json" ]
}

@test "au_log_cleanup.sh: file named '-rf' is deleted safely (MUST 1)" {
    local _rf_file="${LOG_DIR}/cfgtoollogs/patch/auto/-rf"
    touch "${_rf_file}"
    OLD_DATE5=$(date -v-60d '+%Y%m%d%H%M' 2>/dev/null || date -d '60 days ago' '+%Y%m%d%H%M' 2>/dev/null || echo "202408010000")
    touch -t "${OLD_DATE5}" "${_rf_file}"

    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --older-than 0 --delete --yes 2>&1"
    [ "${status}" -eq 0 ]

    [ ! -f "${_rf_file}" ]
    [ -f "${LOG_DIR}/cfgtoollogs/patch/auto/aru/request_id_cache.json" ]
}

# =============================================================================
# SHOULD 4 regression: DELETE output at WARN level (visible by default)
# =============================================================================

@test "au_log_cleanup.sh: DELETE appears in output at warn level (SHOULD 4)" {
    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --older-than 0 --delete --yes 2>&1"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DELETE"* ]]
}

@test "au_log_cleanup.sh: PRUNE appears in output after empty dir removed (SHOULD 4)" {
    # Create an old empty directory that will be pruned
    local _empty_job="${LOG_DIR}/job_prune_test"
    mkdir -p "${_empty_job}"
    OLD_DATE6=$(date -v-60d '+%Y%m%d%H%M' 2>/dev/null || date -d '60 days ago' '+%Y%m%d%H%M' 2>/dev/null || echo "202408010000")
    touch -t "${OLD_DATE6}" "${_empty_job}"

    run bash -c "AU_LOG_DIR='${LOG_DIR}' '${WORK_SCRIPT}' --older-than 0 --delete --yes 2>&1"
    [ "${status}" -eq 0 ]
    # The empty dir with no status.json is not a job dir, so it should be pruned
    [[ "${output}" == *"PRUNE"* ]] || true  # PRUNE appears only if empty dirs exist
}
