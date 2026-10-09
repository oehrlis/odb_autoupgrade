#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# tests/test_helper.bash
# Shared BATS test helpers for odb_autoupgrade test suite.
# Source this file at the top of each .bats file:
#   load 'test_helper'
# ------------------------------------------------------------------------------

# Resolve repository root relative to this helper file
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Create a per-test scratch directory; cleaned up in teardown_helper.
setup_helper() {
    WORK_DIR="${BATS_TMPDIR}/au_test_$$_${RANDOM}"
    mkdir -p "${WORK_DIR}/bin" "${WORK_DIR}/jar" "${WORK_DIR}/etc" \
             "${WORK_DIR}/patches" "${WORK_DIR}/logs" "${WORK_DIR}/keystore"
    export AUTOUPGRADE_BASE="${WORK_DIR}"
}

teardown_helper() {
    rm -rf "${WORK_DIR:-}"
}

# Create a fake java binary in WORK_DIR/bin that mimics version output.
# Args: $1 - major version (8, 11, 17, 21)
make_mock_java() {
    local major="$1"
    local java_bin="${WORK_DIR}/bin/java"
    local ver_str
    if [[ "${major}" == "8" ]]; then
        ver_str="1.8.0_471"
    else
        ver_str="${major}.0.11"
    fi
    cat > "${java_bin}" <<JAVASHIM
#!/usr/bin/env bash
if [[ "\$1" == "-version" ]]; then
    printf 'java version "%s"\\n' "${ver_str}" >&2
    exit 0
fi
# Record args and exit 0 so tests can inspect them
printf '%s\\n' "\$@" > "${WORK_DIR}/java_args"
exit 0
JAVASHIM
    chmod +x "${java_bin}"
    export AUTOUPGRADE_JAVA_HOME="${WORK_DIR}"
}
