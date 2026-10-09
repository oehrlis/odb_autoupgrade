#!/usr/bin/env bats
# shellcheck disable=SC1090
# ------------------------------------------------------------------------------
# tests/lib_common.bats
# BATS tests for lib/common.sh (WP1 port from odb_datasafe).
# ------------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    LIB="${REPO_ROOT}/lib/common.sh"
    WORK_DIR="${BATS_TMPDIR}/common_test_$$_${RANDOM}"
    mkdir -p "${WORK_DIR}"
}

teardown() {
    rm -rf "${WORK_DIR}"
}

# ---------------------------------------------------------------------------
# Guard: double-source is a no-op
# ---------------------------------------------------------------------------

@test "common.sh: guard prevents double-source" {
    run bash -c "
        source '${LIB}'
        source '${LIB}'
        echo 'loaded_ok'
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"loaded_ok"* ]]
}

# ---------------------------------------------------------------------------
# Bash version check
# ---------------------------------------------------------------------------

@test "common.sh: bash 4.2+ check passes for current shell" {
    run bash -c "source '${LIB}'; echo 'version_ok'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"version_ok"* ]]
}

# ---------------------------------------------------------------------------
# Logging functions
# ---------------------------------------------------------------------------

@test "common.sh: log_info outputs to stderr" {
    run bash -c "source '${LIB}'; log_info 'hello world'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"hello world"* ]]
}

@test "common.sh: log_warn outputs WARN prefix" {
    run bash -c "source '${LIB}'; log_warn 'something bad'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WARN"* ]]
    [[ "${output}" == *"something bad"* ]]
}

@test "common.sh: log_error outputs ERROR prefix" {
    run bash -c "source '${LIB}'; log_error 'fatal issue'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ERROR"* ]]
    [[ "${output}" == *"fatal issue"* ]]
}

@test "common.sh: log_debug suppressed at default log level" {
    run bash -c "source '${LIB}'; LOG_LEVEL=INFO log_debug 'should not appear'"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"should not appear"* ]]
}

# ---------------------------------------------------------------------------
# die function
# ---------------------------------------------------------------------------

@test "common.sh: die exits with code 1 and prints message" {
    run bash -c "source '${LIB}'; die 'fatal error'"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"fatal error"* ]]
}

# ---------------------------------------------------------------------------
# require_cmd
# ---------------------------------------------------------------------------

@test "common.sh: require_cmd passes for ls" {
    run bash -c "source '${LIB}'; require_cmd ls; echo 'ok'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ok"* ]]
}

@test "common.sh: require_cmd fails for nonexistent command" {
    run bash -c "source '${LIB}'; require_cmd __no_such_cmd_xyz__"
    [ "${status}" -ne 0 ]
}

# ---------------------------------------------------------------------------
# require_var
# ---------------------------------------------------------------------------

@test "common.sh: require_var passes for set variable" {
    run bash -c "source '${LIB}'; MY_VAR=foo require_var MY_VAR; echo 'ok'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ok"* ]]
}

@test "common.sh: require_var fails for unset variable" {
    run bash -c "source '${LIB}'; unset MY_VAR; require_var MY_VAR"
    [ "${status}" -ne 0 ]
}

# ---------------------------------------------------------------------------
# No OCI/Python symbols
# ---------------------------------------------------------------------------

@test "common.sh: no OCI references (is_ocid, init_config, PYTHONWARNINGS)" {
    run bash -c "
        grep -E 'is_ocid|init_config|PYTHONWARNINGS|PYTHONIOENCODING|OCI_CLI_SUPPRESS' \
            '${LIB}' | grep -v '^\s*#'
    "
    # grep returns 1 when no match - that is the expected result
    [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

@test "common.sh: _AU_CONF_FILES guard (not _DATASAFE_CONF_FILES)" {
    run bash -c "grep '_DATASAFE_CONF_FILES' '${LIB}'"
    [ "${status}" -ne 0 ] || [ -z "${output}" ]
}
