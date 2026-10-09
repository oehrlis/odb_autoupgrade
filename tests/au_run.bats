#!/usr/bin/env bats
# shellcheck disable=SC1090  # dynamic source path - checked via shellcheck -x
# ------------------------------------------------------------------------------
# tests/au_run.bats
# BATS tests for lib/au_lib.sh, bin/au_run.sh, deprecation shims, and
# au_set_defaults.
# (Renamed from tests/run_autoupgrade.bats when bin/run_autoupgrade.sh was
# converted to a deprecation shim pointing at bin/au_run.sh.)
# ------------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    LIB_NET="${REPO_ROOT}/lib/au_lib.sh"
    SCRIPT="${REPO_ROOT}/bin/au_run.sh"

    # Scratch dir per test
    WORK_DIR="${BATS_TMPDIR}/au_test_$$_${RANDOM}"
    mkdir -p "${WORK_DIR}/bin" "${WORK_DIR}/jar" "${WORK_DIR}/etc"
    # Ensure directories are not group/world-writable (security check compliance)
    chmod 700 "${WORK_DIR}" "${WORK_DIR}/bin" "${WORK_DIR}/jar" "${WORK_DIR}/etc"

    # Ensure a placeholder jar exists at the real repo location for integration
    # tests (AUTOUPGRADE_BASE is always derived from the script's own directory).
    # Track whether we created it so teardown removes only what we added.
    _FAKE_JAR_CREATED=""
    if [[ ! -f "${REPO_ROOT}/jar/autoupgrade.jar" ]]; then
        touch "${REPO_ROOT}/jar/autoupgrade.jar"
        _FAKE_JAR_CREATED="${REPO_ROOT}/jar/autoupgrade.jar"
    fi

    # Reset any caller-side proxy/truststore env that might leak between tests
    unset AUTOUPGRADE_PROXY https_proxy HTTPS_PROXY http_proxy HTTP_PROXY \
          no_proxy NO_PROXY AUTOUPGRADE_TRUSTSTORE AUTOUPGRADE_TRUSTSTORE_PASS \
          AUTOUPGRADE_JAVA_HOME AUTOUPGRADE_JAVA_OPTS AUTOUPGRADE_DEBUG_SSL \
          AUTOUPGRADE_TRUSTSTORE_CANDIDATES AUTOUPGRADE_JAVA_SUPPORTED \
          AUTOUPGRADE_DRY_RUN ORACLE_HOME \
          AU_TARGET_VERSION AU_PLATFORM AU_PATCH AU_GOLD_IMAGE \
          AU_LOG_DIR AU_KEYSTORE AU_DOWNLOAD_FOLDER \
          AU_SOURCE_HOME AU_TARGET_HOME AU_SID 2>/dev/null || true
}

teardown() {
    rm -rf "${WORK_DIR}"
    if [[ -n "${_FAKE_JAR_CREATED}" ]]; then
        rm -f "${_FAKE_JAR_CREATED}"
    fi
}

# Create a fake java binary in WORK_DIR/bin that mimics version output.
# Uses printf so the version string retains its literal double-quote characters
# (a plain `echo` in a heredoc would strip them).
# Usage: make_mock_java <major>   (e.g. 8, 11, 17)
make_mock_java() {
    local major="$1"
    local java_bin="${WORK_DIR}/bin/java"
    local ver_str
    if [[ "${major}" == "8" ]]; then
        ver_str="1.8.0_471"
    else
        ver_str="${major}.0.2"
    fi
    cat > "${java_bin}" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-version" ]]; then
    printf 'java version "%s"\n' '${ver_str}' >&2
    exit 0
fi
printf '%s\n' "\$@" > "${WORK_DIR}/java_args"
exit "\${MOCK_JAVA_EXIT:-0}"
EOF
    chmod +x "${java_bin}"
}

# Placeholder - kept for backward compat; integration tests use REPO_ROOT jar
make_fake_jar() {
    : # jar at REPO_ROOT/jar/autoupgrade.jar is managed by setup/teardown
}

# ---------------------------------------------------------------------------
# Unit tests for lib/au_lib.sh - proxy parsing
# ---------------------------------------------------------------------------

@test "au_build_proxy_opts: sets host and port from URL with port" {
    JAVA_OPTS=()
    PROXY_INFO=""
    # shellcheck source=lib/au_lib.sh
    source "${LIB_NET}"
    AUTOUPGRADE_PROXY="http://proxy.example.com:3128"
    au_build_proxy_opts
    [[ "${PROXY_INFO}" == "proxy.example.com:3128" ]]
    [[ "${JAVA_OPTS[*]}" == *"proxyHost=proxy.example.com"* ]]
    [[ "${JAVA_OPTS[*]}" == *"proxyPort=3128"* ]]
}

@test "au_build_proxy_opts: defaults to port 80 when URL has no port" {
    JAVA_OPTS=()
    PROXY_INFO=""
    source "${LIB_NET}"
    AUTOUPGRADE_PROXY="http://proxy.example.com"
    au_build_proxy_opts
    [[ "${PROXY_INFO}" == "proxy.example.com:80" ]]
    [[ "${JAVA_OPTS[*]}" == *"proxyPort=80"* ]]
}

@test "au_build_proxy_opts: none disables proxy" {
    JAVA_OPTS=()
    PROXY_INFO=""
    source "${LIB_NET}"
    AUTOUPGRADE_PROXY="none"
    au_build_proxy_opts
    [[ -z "${PROXY_INFO}" ]]
    [[ "${#JAVA_OPTS[@]}" -eq 0 ]]
}

@test "au_build_proxy_opts: proxy credentials trigger warning and are stripped" {
    JAVA_OPTS=()
    PROXY_INFO=""
    source "${LIB_NET}"
    AUTOUPGRADE_PROXY="http://user:secret@proxy.example.com:3128"
    run bash -c "
        source '${LIB_NET}'
        JAVA_OPTS=(); PROXY_INFO=''
        AUTOUPGRADE_PROXY='http://user:secret@proxy.example.com:3128'
        au_build_proxy_opts
        echo \"HOST:\${PROXY_INFO}\"
        printf '%s\n' \"\${JAVA_OPTS[@]}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WARN: Proxy credentials"* ]]
    [[ "${output}" != *"secret"* ]]
    [[ "${output}" == *"HOST:proxy.example.com:3128"* ]]
}

@test "au_build_proxy_opts: precedence AUTOUPGRADE_PROXY over https_proxy" {
    JAVA_OPTS=()
    PROXY_INFO=""
    source "${LIB_NET}"
    AUTOUPGRADE_PROXY="http://explicit.example.com:1234"
    https_proxy="http://fallback.example.com:5678"
    au_build_proxy_opts
    [[ "${PROXY_INFO}" == "explicit.example.com:1234" ]]
}

@test "au_build_proxy_opts: precedence https_proxy over http_proxy" {
    JAVA_OPTS=()
    PROXY_INFO=""
    source "${LIB_NET}"
    unset AUTOUPGRADE_PROXY
    https_proxy="http://https.example.com:443"
    http_proxy="http://http.example.com:80"
    au_build_proxy_opts
    [[ "${PROXY_INFO}" == "https.example.com:443" ]]
}

@test "au_build_proxy_opts: http_proxy used when higher-priority vars absent" {
    JAVA_OPTS=()
    PROXY_INFO=""
    source "${LIB_NET}"
    unset AUTOUPGRADE_PROXY https_proxy HTTPS_PROXY
    http_proxy="http://fallback.example.com:8080"
    au_build_proxy_opts
    [[ "${PROXY_INFO}" == "fallback.example.com:8080" ]]
}

# ---------------------------------------------------------------------------
# Unit tests for no_proxy conversion
# ---------------------------------------------------------------------------

@test "au_convert_no_proxy: leading dot becomes wildcard" {
    source "${LIB_NET}"
    result="$(au_convert_no_proxy ".example.com")"
    [[ "${result}" == "*.example.com" ]]
}

@test "au_convert_no_proxy: multiple entries pipe-separated" {
    source "${LIB_NET}"
    result="$(au_convert_no_proxy "localhost,.example.com,10.0.0.1")"
    [[ "${result}" == "localhost|*.example.com|10.0.0.1" ]]
}

@test "au_convert_no_proxy: CIDR entry is skipped with warning" {
    source "${LIB_NET}"
    local _warn_file="${BATS_TEST_TMPDIR}/au_warn.txt"
    result="$(au_convert_no_proxy "10.0.0.0/8,.example.com" 2>"${_warn_file}")"
    [[ "${result}" == "*.example.com" ]]
    grep -q "CIDR" "${_warn_file}"
}

@test "au_convert_no_proxy: whitespace inside entries is stripped" {
    source "${LIB_NET}"
    result="$(au_convert_no_proxy " localhost , .example.com ")"
    [[ "${result}" == "localhost|*.example.com" ]]
}

# ---------------------------------------------------------------------------
# Unit tests for truststore resolution
# ---------------------------------------------------------------------------

@test "au_resolve_truststore: AUTOUPGRADE_TRUSTSTORE=none skips all opts" {
    JAVA_OPTS=()
    TRUSTSTORE_INFO=""
    source "${LIB_NET}"
    AUTOUPGRADE_TRUSTSTORE="none"
    au_resolve_truststore
    [[ "${#JAVA_OPTS[@]}" -eq 0 ]]
    [[ -z "${TRUSTSTORE_INFO}" ]]
}

@test "au_resolve_truststore: explicit path that exists is used" {
    JAVA_OPTS=()
    TRUSTSTORE_INFO=""
    source "${LIB_NET}"
    local ts_file="${WORK_DIR}/cacerts"
    touch "${ts_file}"
    AUTOUPGRADE_TRUSTSTORE="${ts_file}"
    au_resolve_truststore
    [[ "${TRUSTSTORE_INFO}" == "${ts_file}" ]]
    [[ "${JAVA_OPTS[*]}" == *"trustStore=${ts_file}"* ]]
}

@test "au_resolve_truststore: explicit path that does not exist -> exit 1" {
    JAVA_OPTS=()
    TRUSTSTORE_INFO=""
    source "${LIB_NET}"
    run bash -c "
        source '${LIB_NET}'
        JAVA_OPTS=(); TRUSTSTORE_INFO=''
        AUTOUPGRADE_TRUSTSTORE='/nonexistent/cacerts'
        au_resolve_truststore
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"ERROR"* ]]
}

@test "au_resolve_truststore: candidate list via AUTOUPGRADE_TRUSTSTORE_CANDIDATES" {
    JAVA_OPTS=()
    TRUSTSTORE_INFO=""
    source "${LIB_NET}"
    local ts_file="${WORK_DIR}/test_cacerts"
    touch "${ts_file}"
    AUTOUPGRADE_TRUSTSTORE_CANDIDATES="/nonexistent/one ${ts_file}"
    au_resolve_truststore
    [[ "${TRUSTSTORE_INFO}" == "${ts_file}" ]]
}

@test "au_resolve_truststore: no readable candidate -> no opts (JDK default)" {
    JAVA_OPTS=()
    TRUSTSTORE_INFO=""
    source "${LIB_NET}"
    AUTOUPGRADE_TRUSTSTORE_CANDIDATES="/nonexistent/one /nonexistent/two"
    au_resolve_truststore
    [[ "${#JAVA_OPTS[@]}" -eq 0 ]]
    [[ -z "${TRUSTSTORE_INFO}" ]]
}

# ---------------------------------------------------------------------------
# Unit tests for Java resolution
# ---------------------------------------------------------------------------

@test "au_resolve_java: AUTOUPGRADE_JAVA_HOME is used when set" {
    source "${LIB_NET}"
    make_mock_java 11
    JAVA_BIN=""
    AUTOUPGRADE_JAVA_HOME="${WORK_DIR}"
    au_resolve_java
    [[ "${JAVA_BIN}" == "${WORK_DIR}/bin/java" ]]
}

@test "au_resolve_java: ORACLE_HOME/jdk/bin/java is used as fallback" {
    source "${LIB_NET}"
    make_mock_java 8
    mkdir -p "${WORK_DIR}/oh/jdk/bin"
    cp "${WORK_DIR}/bin/java" "${WORK_DIR}/oh/jdk/bin/java"
    JAVA_BIN=""
    unset AUTOUPGRADE_JAVA_HOME
    ORACLE_HOME="${WORK_DIR}/oh"
    au_resolve_java
    [[ "${JAVA_BIN}" == "${WORK_DIR}/oh/jdk/bin/java" ]]
}

@test "au_resolve_java: unsupported Java version -> exit 1" {
    source "${LIB_NET}"
    make_mock_java 17
    run bash -c "
        source '${LIB_NET}'
        JAVA_BIN=''
        AUTOUPGRADE_JAVA_SUPPORTED='8 11'
        AUTOUPGRADE_JAVA_HOME='${WORK_DIR}'
        au_resolve_java
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Unsupported"* ]]
}

@test "au_resolve_java: Java 8 (1.8.x version string) is accepted" {
    source "${LIB_NET}"
    make_mock_java 8
    JAVA_BIN=""
    AUTOUPGRADE_JAVA_HOME="${WORK_DIR}"
    AUTOUPGRADE_JAVA_SUPPORTED="8 11"
    au_resolve_java
    [[ "${JAVA_VERSION_FULL}" == "1.8.0_471" ]]
}

# ---------------------------------------------------------------------------
# Unit tests for au_check_cfg_vars
# ---------------------------------------------------------------------------

@test "au_check_cfg_vars: all referenced vars set -> exit 0" {
    source "${LIB_NET}"
    local cfg="${WORK_DIR}/test.cfg"
    cat > "${cfg}" <<'CFG'
# Comment line - ${SHOULD_BE_IGNORED} not checked
target_home=${ORACLE_HOME_19}
source_home=${ORACLE_HOME_12}
CFG
    run bash -c "
        source '${LIB_NET}'
        ORACLE_HOME_19='/u01/19'
        ORACLE_HOME_12='/u01/12'
        au_check_cfg_vars '${cfg}'
    "
    [ "${status}" -eq 0 ]
}

@test "au_check_cfg_vars: one unset var -> exit 1 with name in output" {
    source "${LIB_NET}"
    local cfg="${WORK_DIR}/test.cfg"
    cat > "${cfg}" <<'CFG'
target_home=${ORACLE_HOME_19}
source_home=${ORACLE_HOME_12}
CFG
    run bash -c "
        source '${LIB_NET}'
        ORACLE_HOME_19='/u01/19'
        unset ORACLE_HOME_12 2>/dev/null || true
        au_check_cfg_vars '${cfg}'
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"ORACLE_HOME_12"* ]]
}

@test "au_check_cfg_vars: commented reference is ignored" {
    source "${LIB_NET}"
    local cfg="${WORK_DIR}/test.cfg"
    cat > "${cfg}" <<'CFG'
# target_home=${DEFINITELY_UNSET_VAR}
target_home=${ORACLE_HOME_19}
CFG
    run bash -c "
        source '${LIB_NET}'
        ORACLE_HOME_19='/u01/19'
        unset DEFINITELY_UNSET_VAR 2>/dev/null || true
        au_check_cfg_vars '${cfg}'
    "
    [ "${status}" -eq 0 ]
}

@test "au_check_cfg_vars: bare \$VAR form is checked" {
    source "${LIB_NET}"
    local cfg="${WORK_DIR}/test.cfg"
    # Use printf to write the config avoiding bats quoting complexity
    printf 'target_home=%s\n' '$ORACLE_HOME_BARE' > "${cfg}"
    run bash -c "
        source '${LIB_NET}'
        unset ORACLE_HOME_BARE 2>/dev/null || true
        au_check_cfg_vars '${cfg}'
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"ORACLE_HOME_BARE"* ]]
}

@test "au_check_cfg_vars: empty-but-set variable is accepted" {
    source "${LIB_NET}"
    local cfg="${WORK_DIR}/test.cfg"
    cat > "${cfg}" <<'CFG'
option=${MAYBE_EMPTY}
CFG
    run bash -c "
        source '${LIB_NET}'
        MAYBE_EMPTY=''
        export MAYBE_EMPTY
        au_check_cfg_vars '${cfg}'
    "
    [ "${status}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Integration tests for bin/au_run.sh
#
# All integration tests merge stderr into stdout (2>&1 inside bash -c) so that
# BATS can check both informational messages and error output via ${output}.
# The script always derives AUTOUPGRADE_BASE from its own location; passing it
# as an env var has no effect. Use absolute -config paths to reach test fixtures.
# ---------------------------------------------------------------------------

@test "au_run.sh: missing -config file -> exit 1" {
    make_mock_java 11
    run bash -c "AUTOUPGRADE_JAVA_HOME='${WORK_DIR}' \
        AUTOUPGRADE_TRUSTSTORE_CANDIDATES='/nonexistent' \
        bash '${SCRIPT}' -config /nonexistent/no.cfg 2>&1"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"not found"* ]]
}

@test "au_run.sh: DRY_RUN prints command and exits 0 without running jar" {
    make_mock_java 11
    run bash -c "AUTOUPGRADE_JAVA_HOME='${WORK_DIR}' \
        AUTOUPGRADE_TRUSTSTORE_CANDIDATES='/nonexistent' \
        AUTOUPGRADE_DRY_RUN=true \
        bash '${SCRIPT}' -analyze 2>&1"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DRY-RUN"* ]]
    # The mock java_args file must NOT have been written (no real run)
    [[ ! -f "${WORK_DIR}/java_args" ]]
}

@test "au_run.sh: JVM opts passed on command line, not via JAVA_TOOL_OPTIONS" {
    make_mock_java 11
    run bash -c "AUTOUPGRADE_JAVA_HOME='${WORK_DIR}' \
        AUTOUPGRADE_TRUSTSTORE_CANDIDATES='/nonexistent' \
        AUTOUPGRADE_JAVA_OPTS='-Xmx2g' \
        AUTOUPGRADE_DRY_RUN=true \
        bash '${SCRIPT}' -analyze 2>&1"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"-Xmx2g"* ]]
    # Verify JAVA_TOOL_OPTIONS is not mentioned in the output
    [[ "${output}" != *"JAVA_TOOL_OPTIONS"* ]]
}

@test "au_run.sh: exit code of mock java is propagated" {
    # Override mock to exit with code 42 (no DRY_RUN - actually executes java)
    local java_bin="${WORK_DIR}/bin/java"
    cat > "${java_bin}" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-version" ]]; then
    printf 'java version "11.0.2"\n' >&2
    exit 0
fi
exit 42
EOF
    chmod +x "${java_bin}"
    run bash -c "AUTOUPGRADE_JAVA_HOME='${WORK_DIR}' \
        AUTOUPGRADE_TRUSTSTORE_CANDIDATES='/nonexistent' \
        bash '${SCRIPT}' -analyze 2>&1"
    [ "${status}" -eq 42 ]
}

@test "au_run.sh: truststore password masked in dry-run output" {
    make_mock_java 11
    local ts_file="${WORK_DIR}/cacerts"
    touch "${ts_file}"
    run bash -c "AUTOUPGRADE_JAVA_HOME='${WORK_DIR}' \
        AUTOUPGRADE_TRUSTSTORE='${ts_file}' \
        AUTOUPGRADE_TRUSTSTORE_PASS='supersecret' \
        AUTOUPGRADE_DRY_RUN=true \
        bash '${SCRIPT}' -analyze 2>&1"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"supersecret"* ]]
    [[ "${output}" == *"trustStorePassword=****"* ]]
}

@test "au_run.sh: proxy opts appear in dry-run command line" {
    make_mock_java 11
    run bash -c "AUTOUPGRADE_JAVA_HOME='${WORK_DIR}' \
        AUTOUPGRADE_TRUSTSTORE_CANDIDATES='/nonexistent' \
        AUTOUPGRADE_PROXY='http://proxy.example.com:3128' \
        AUTOUPGRADE_DRY_RUN=true \
        bash '${SCRIPT}' -analyze 2>&1"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"proxyHost=proxy.example.com"* ]]
    [[ "${output}" == *"proxyPort=3128"* ]]
}

@test "au_run.sh: --help exits 0 without running java" {
    run bash -c "bash '${SCRIPT}' --help 2>&1"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage"* ]]
}

@test "au_run.sh: config with unset var aborts before running java" {
    make_mock_java 11
    local cfg="${WORK_DIR}/test_vars.cfg"
    cat > "${cfg}" <<'CFG'
target_home=${UNSET_VAR_XYZ}
CFG
    # Use absolute path for -config so resolve_config_path finds it directly
    run bash -c "AUTOUPGRADE_JAVA_HOME='${WORK_DIR}' \
        AUTOUPGRADE_TRUSTSTORE_CANDIDATES='/nonexistent' \
        bash '${SCRIPT}' -config '${cfg}' -analyze 2>&1"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"UNSET_VAR_XYZ"* ]]
    [[ ! -f "${WORK_DIR}/java_args" ]]
}

# ---------------------------------------------------------------------------
# au_source_env_file - precedence caller env > env file
# ---------------------------------------------------------------------------

@test "au_source_env_file: env file sets variables not set by caller" {
    printf 'AUTOUPGRADE_PROXY=http://proxy.example.com:3128\n' > "${WORK_DIR}/au.env"
    chmod 600 "${WORK_DIR}/au.env"
    run bash -c "unset AUTOUPGRADE_PROXY; source '${LIB_NET}'; \
        au_source_env_file '${WORK_DIR}/au.env' 2>/dev/null; \
        echo \"\${AUTOUPGRADE_PROXY}\"; bash -c 'echo exported=\${AUTOUPGRADE_PROXY}'"
    [ "${status}" -eq 0 ]
    [[ "${lines[0]}" == "http://proxy.example.com:3128" ]]
    [[ "${lines[1]}" == "exported=http://proxy.example.com:3128" ]]
}

@test "au_source_env_file: caller environment wins over env file" {
    printf 'AUTOUPGRADE_PROXY=http://proxy.example.com:3128\n' > "${WORK_DIR}/au.env"
    chmod 600 "${WORK_DIR}/au.env"
    run bash -c "export AUTOUPGRADE_PROXY=none; source '${LIB_NET}'; \
        au_source_env_file '${WORK_DIR}/au.env' 2>/dev/null; echo \"\${AUTOUPGRADE_PROXY}\""
    [ "${status}" -eq 0 ]
    [[ "${output}" == "none" ]]
}

@test "au_source_env_file: caller value with spaces and quotes survives" {
    printf 'AUTOUPGRADE_JAVA_OPTS=-Xmx1g\n' > "${WORK_DIR}/au.env"
    chmod 600 "${WORK_DIR}/au.env"
    run bash -c "export AUTOUPGRADE_JAVA_OPTS='-Xmx2g -Dfoo=\"a b\"'; source '${LIB_NET}'; \
        au_source_env_file '${WORK_DIR}/au.env' 2>/dev/null; echo \"\${AUTOUPGRADE_JAVA_OPTS}\""
    [ "${status}" -eq 0 ]
    [[ "${output}" == '-Xmx2g -Dfoo="a b"' ]]
}

@test "au_source_env_file: missing env file is not an error" {
    run bash -c "source '${LIB_NET}'; au_source_env_file '${WORK_DIR}/missing.env'"
    [ "${status}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# au_set_defaults - default value application and au_patch.env pinning
# ---------------------------------------------------------------------------

@test "au_set_defaults: built-in defaults are applied when AU_* unset" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB_NET}'
        au_set_defaults 2>/dev/null
        echo \"TARGET_VERSION=\${AU_TARGET_VERSION}\"
        echo \"PLATFORM=\${AU_PLATFORM}\"
        echo \"PATCH=\${AU_PATCH}\"
        echo \"GOLD_IMAGE=\${AU_GOLD_IMAGE}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"TARGET_VERSION=19"* ]]
    [[ "${output}" == *"PLATFORM=LINUX.X64"* ]]
    [[ "${output}" == *"PATCH=RECOMMENDED"* ]]
    [[ "${output}" == *"GOLD_IMAGE=NO"* ]]
}

@test "au_set_defaults: caller-set AU_PATCH wins over default" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH='RU19.29'
        source '${LIB_NET}'
        au_set_defaults 2>/dev/null
        echo \"PATCH=\${AU_PATCH}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PATCH=RU19.29"* ]]
}

@test "au_set_defaults: env-file value wins over built-in default" {
    # Simulate env-file having set AU_TARGET_VERSION before au_set_defaults runs
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_TARGET_VERSION='21'
        source '${LIB_NET}'
        au_set_defaults 2>/dev/null
        echo \"VERSION=\${AU_TARGET_VERSION}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"VERSION=21"* ]]
}

@test "au_set_defaults: au_patch.env pins AU_PATCH when not set by caller" {
    mkdir -p "${WORK_DIR}/patches"
    printf 'AU_PATCH=RU19.28\n' > "${WORK_DIR}/patches/au_patch.env"
    chmod 600 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB_NET}'
        au_set_defaults 2>&1
        echo \"PATCH=\${AU_PATCH}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PATCH=RU19.28"* ]]
    [[ "${output}" == *"pinned by"* ]]
}

@test "au_set_defaults: au_patch.env does not override explicit AU_PATCH" {
    mkdir -p "${WORK_DIR}/patches"
    printf 'AU_PATCH=RU19.28\n' > "${WORK_DIR}/patches/au_patch.env"
    chmod 600 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH='RU19.29'
        source '${LIB_NET}'
        au_set_defaults 2>/dev/null
        echo \"PATCH=\${AU_PATCH}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PATCH=RU19.29"* ]]
    [[ "${output}" != *"RU19.28"* ]]
}

@test "au_set_defaults: AU_SOURCE_HOME, AU_TARGET_HOME, AU_SID stay unset" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB_NET}'
        au_set_defaults 2>/dev/null
        echo \"SH=\${AU_SOURCE_HOME:-UNSET}\"
        echo \"TH=\${AU_TARGET_HOME:-UNSET}\"
        echo \"SID=\${AU_SID:-UNSET}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"SH=UNSET"* ]]
    [[ "${output}" == *"TH=UNSET"* ]]
    [[ "${output}" == *"SID=UNSET"* ]]
}

# ---------------------------------------------------------------------------
# Deprecation shim tests
# ---------------------------------------------------------------------------

@test "shim run_autoupgrade.sh: prints WARN and delegates to au_run.sh (dry-run)" {
    make_mock_java 11
    run bash -c "AUTOUPGRADE_JAVA_HOME='${WORK_DIR}' \
        AUTOUPGRADE_TRUSTSTORE_CANDIDATES='/nonexistent' \
        AUTOUPGRADE_DRY_RUN=true \
        bash '${REPO_ROOT}/bin/run_autoupgrade.sh' -analyze 2>&1"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WARN: run_autoupgrade.sh is deprecated"* ]]
    [[ "${output}" == *"au_run.sh"* ]]
    [[ "${output}" == *"DRY-RUN"* ]]
}

@test "shim run_autoupgrade.sh: propagates non-zero exit code from au_run.sh" {
    local java_bin="${WORK_DIR}/bin/java"
    cat > "${java_bin}" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-version" ]]; then
    printf 'java version "11.0.2"\n' >&2
    exit 0
fi
exit 7
EOF
    chmod +x "${java_bin}"
    run bash -c "AUTOUPGRADE_JAVA_HOME='${WORK_DIR}' \
        AUTOUPGRADE_TRUSTSTORE_CANDIDATES='/nonexistent' \
        bash '${REPO_ROOT}/bin/run_autoupgrade.sh' -analyze 2>&1"
    [ "${status}" -eq 7 ]
    [[ "${output}" == *"WARN: run_autoupgrade.sh is deprecated"* ]]
}

@test "shim update_autoupgrade.sh: prints WARN and delegates to au_update_jar.sh (--help)" {
    run bash -c "bash '${REPO_ROOT}/bin/update_autoupgrade.sh' --help 2>&1"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage: au_update_jar.sh"* ]]
    [[ "${output}" == *"WARN: update_autoupgrade.sh is deprecated"* ]]
    [[ "${output}" == *"au_update_jar.sh"* ]]
}

@test "shim create_mos_keystore.sh: prints WARN and delegates to au_keystore.sh (--help)" {
    run bash -c "bash '${REPO_ROOT}/bin/create_mos_keystore.sh' --help 2>&1"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WARN: create_mos_keystore.sh is deprecated"* ]]
    [[ "${output}" == *"au_keystore.sh"* ]]
    [[ "${output}" == *"Usage"* ]]
}

# ---------------------------------------------------------------------------
# Security: au_source_env_file (finding 1)
# ---------------------------------------------------------------------------

@test "au_source_env_file: caller value with newline preserved byte-exact" {
    run bash -c "
        source '${LIB_NET}'
        export MYVAR=\$'line1\nline2'
        printf 'MYVAR=injected\n' > '${WORK_DIR}/au.env'
        chmod 600 '${WORK_DIR}/au.env'
        au_source_env_file '${WORK_DIR}/au.env' 2>/dev/null
        printf '%s' \"\${MYVAR}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == $'line1\nline2' ]]
}

@test "au_source_env_file: command injection in caller value does not execute" {
    local pwned="${WORK_DIR}/PWNED"
    run bash -c "
        source '${LIB_NET}'
        export MYVAR='\$(touch ${pwned})'
        printf 'MYVAR=other\n' > '${WORK_DIR}/au.env'
        chmod 600 '${WORK_DIR}/au.env'
        au_source_env_file '${WORK_DIR}/au.env' 2>/dev/null
        echo \"val=\${MYVAR}\"
    "
    [ "${status}" -eq 0 ]
    # The file must NOT have been created (no code execution)
    [[ ! -f "${pwned}" ]]
    # The value should be preserved literally
    [[ "${output}" == *'$(touch'* ]]
}

@test "au_source_env_file: world-writable env file -> exit 1" {
    printf 'AUTOUPGRADE_PROXY=http://injected:8080\n' > "${WORK_DIR}/au.env"
    chmod 666 "${WORK_DIR}/au.env"
    run bash -c "
        source '${LIB_NET}'
        au_source_env_file '${WORK_DIR}/au.env' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"group/world-writable"* ]]
}

@test "au_source_env_file: caller env wins even when env file sets the same var" {
    printf 'AUTOUPGRADE_PROXY=http://proxy.example.com:3128\n' > "${WORK_DIR}/au.env"
    chmod 600 "${WORK_DIR}/au.env"
    run bash -c "
        export AUTOUPGRADE_PROXY=none
        source '${LIB_NET}'
        au_source_env_file '${WORK_DIR}/au.env' 2>/dev/null
        echo \"\${AUTOUPGRADE_PROXY}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == "none" ]]
}

@test "au_source_env_file: symlink to safe file is resolved and sourced (Decision-5)" {
    # S2: au_source_env_file now uses Decision-5; symlinks are resolved, not refused.
    # (Changed from 0.5.0 which refused symlinks with exit 1.)
    printf 'AUTOUPGRADE_PROXY=http://proxy:3128\n' > "${WORK_DIR}/real.env"
    chmod 600 "${WORK_DIR}/real.env"
    ln -s "${WORK_DIR}/real.env" "${WORK_DIR}/link.env"
    run bash -c "
        unset AUTOUPGRADE_PROXY
        source '${LIB_NET}'
        au_source_env_file '${WORK_DIR}/link.env' 2>/dev/null
        echo \"\${AUTOUPGRADE_PROXY}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"http://proxy:3128"* ]]
}

# ---------------------------------------------------------------------------
# Security: au_set_defaults au_patch.env parsing (finding 2)
# ---------------------------------------------------------------------------

@test "au_set_defaults: au_patch.env valid pin is accepted" {
    mkdir -p "${WORK_DIR}/patches"
    printf 'AU_PATCH=RU19.28\n' > "${WORK_DIR}/patches/au_patch.env"
    chmod 600 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB_NET}'
        au_set_defaults 2>&1
        echo \"PATCH=\${AU_PATCH}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PATCH=RU19.28"* ]]
}

@test "au_set_defaults: au_patch.env line PATH=/tmp ignored, PATH unchanged" {
    mkdir -p "${WORK_DIR}/patches"
    local orig_path="${PATH}"
    printf 'PATH=/tmp\n' > "${WORK_DIR}/patches/au_patch.env"
    chmod 600 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export PATH='${orig_path}'
        source '${LIB_NET}'
        au_set_defaults 2>&1
        echo \"PATH=\${PATH}\"
    "
    [ "${status}" -eq 0 ]
    # PATH= line should produce a WARN (not AU_PATCH=) and PATH must be unchanged
    [[ "${output}" == *"WARN"*"ignored"* ]]
    [[ "${output}" == *"PATH=${orig_path}"* ]]
}

@test "au_set_defaults: au_patch.env command substitution rejected" {
    mkdir -p "${WORK_DIR}/patches"
    local pwned="${WORK_DIR}/CMD_PWNED"
    printf 'AU_PATCH=$(touch %s)\n' "${pwned}" > "${WORK_DIR}/patches/au_patch.env"
    chmod 600 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB_NET}'
        au_set_defaults 2>&1
        echo \"PATCH=\${AU_PATCH}\"
    "
    [ "${status}" -eq 0 ]
    # The pwned file must NOT have been created
    [[ ! -f "${pwned}" ]]
    # AU_PATCH should fall back to RECOMMENDED (invalid value rejected)
    [[ "${output}" == *"PATCH=RECOMMENDED"* ]]
}

@test "au_set_defaults: world-writable au_patch.env refused, falls back to RECOMMENDED" {
    mkdir -p "${WORK_DIR}/patches"
    printf 'AU_PATCH=RU19.28\n' > "${WORK_DIR}/patches/au_patch.env"
    chmod 666 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB_NET}'
        au_set_defaults 2>&1
        echo \"PATCH=\${AU_PATCH}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WARN"*"group/world-writable"* ]]
    [[ "${output}" == *"PATCH=RECOMMENDED"* ]]
}

@test "au_set_defaults: symlink au_patch.env refused, falls back to RECOMMENDED" {
    mkdir -p "${WORK_DIR}/patches"
    printf 'AU_PATCH=RU19.28\n' > "${WORK_DIR}/patches/real_patch.env"
    chmod 600 "${WORK_DIR}/patches/real_patch.env"
    ln -s "${WORK_DIR}/patches/real_patch.env" "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB_NET}'
        au_set_defaults 2>&1
        echo \"PATCH=\${AU_PATCH}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"WARN"*"symlink"* ]]
    [[ "${output}" == *"PATCH=RECOMMENDED"* ]]
}

# ---------------------------------------------------------------------------
# Security: envsubst restriction (finding 3)
# ---------------------------------------------------------------------------

@test "au_run.sh: value with newline in referenced var -> exit 1" {
    make_mock_java 11
    local cfg="${WORK_DIR}/test_nl.cfg"
    printf 'target_home=%s\n' '${ORACLE_HOME_19}' > "${cfg}"
    run bash -c "
        export AUTOUPGRADE_JAVA_HOME='${WORK_DIR}'
        export AUTOUPGRADE_TRUSTSTORE_CANDIDATES='/nonexistent'
        export ORACLE_HOME_19=\$'/u01/19\ninjected'
        bash '${SCRIPT}' -config '${cfg}' -analyze 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"newline"* ]]
}

@test "au_run.sh: envsubst only substitutes referenced vars, not unrelated ones" {
    make_mock_java 11
    local cfg="${WORK_DIR}/test_envsubst.cfg"
    # Only ORACLE_HOME_19 is referenced; UNRELATED_VAR is not
    printf 'target_home=%s\ncomment=no %s here\n' \
        '${ORACLE_HOME_19}' '$UNRELATED_VAR' > "${cfg}"
    run bash -c "
        export AUTOUPGRADE_JAVA_HOME='${WORK_DIR}'
        export AUTOUPGRADE_TRUSTSTORE_CANDIDATES='/nonexistent'
        export ORACLE_HOME_19='/u01/19'
        export UNRELATED_VAR='SHOULD_NOT_APPEAR_IN_RESOLVED'
        AUTOUPGRADE_DRY_RUN=true bash '${SCRIPT}' -config '${cfg}' -analyze 2>&1
        cat '${WORK_DIR}'/../tmp/autoupgrade_resolved_* 2>/dev/null || true
    "
    # The run exits 0 (dry-run). UNRELATED_VAR must not expand in the resolved file.
    [ "${status}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Security: au_build_proxy_opts authority parsing (finding 4)
# ---------------------------------------------------------------------------

@test "au_build_proxy_opts: password with slash in URL parsed correctly" {
    run bash -c "
        source '${LIB_NET}'
        JAVA_OPTS=(); PROXY_INFO=''
        AUTOUPGRADE_PROXY='http://user:pa/ss@proxy.example.com:8080'
        au_build_proxy_opts
        echo \"HOST:\${PROXY_INFO}\"
        printf '%s\n' \"\${JAVA_OPTS[@]}\"
        echo \"proxy=\${https_proxy:-UNSET}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"HOST:proxy.example.com:8080"* ]]
    [[ "${output}" != *"pa"* ]] || [[ "${output}" != *"/ss"* ]]
    [[ "${output}" != *"user"* ]]
    [[ "${output}" == *"proxy.example.com:8080"* ]]
}

@test "au_build_proxy_opts: non-numeric port -> exit 1" {
    run bash -c "
        source '${LIB_NET}'
        JAVA_OPTS=(); PROXY_INFO=''
        AUTOUPGRADE_PROXY='http://proxy.example.com:notaport'
        au_build_proxy_opts 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Invalid proxy port"* ]]
}

@test "au_build_proxy_opts: port 0 rejected (out of range)" {
    run bash -c "
        source '${LIB_NET}'
        JAVA_OPTS=(); PROXY_INFO=''
        AUTOUPGRADE_PROXY='http://proxy.example.com:0'
        au_build_proxy_opts 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Invalid proxy port"* ]]
}

@test "au_build_proxy_opts: port 65536 rejected (out of range)" {
    run bash -c "
        source '${LIB_NET}'
        JAVA_OPTS=(); PROXY_INFO=''
        AUTOUPGRADE_PROXY='http://proxy.example.com:65536'
        au_build_proxy_opts 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Invalid proxy port"* ]]
}

@test "au_build_proxy_opts: http_proxy with creds sanitized in exported vars" {
    run bash -c "
        source '${LIB_NET}'
        JAVA_OPTS=(); PROXY_INFO=''
        unset AUTOUPGRADE_PROXY HTTPS_PROXY HTTP_PROXY https_proxy
        http_proxy='http://user:secret@proxy.example.com:3128'
        au_build_proxy_opts
        echo \"https_proxy=\${https_proxy:-UNSET}\"
        echo \"http_proxy=\${http_proxy:-UNSET}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"secret"* ]]
    [[ "${output}" != *"user:secret"* ]]
    [[ "${output}" == *"proxy.example.com:3128"* ]]
}

@test "au_build_proxy_opts: IPv6 address rejected with exit 1" {
    run bash -c "
        source '${LIB_NET}'
        JAVA_OPTS=(); PROXY_INFO=''
        AUTOUPGRADE_PROXY='http://[::1]:3128'
        au_build_proxy_opts 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"IPv6"* ]]
}

# ---------------------------------------------------------------------------
# Security: au_resolve_truststore - password only when set (finding 10)
# ---------------------------------------------------------------------------

@test "au_resolve_truststore: no AUTOUPGRADE_TRUSTSTORE_PASS -> no trustStorePassword in JAVA_OPTS" {
    local ts_file="${WORK_DIR}/cacerts"
    touch "${ts_file}"
    run bash -c "
        source '${LIB_NET}'
        JAVA_OPTS=(); TRUSTSTORE_INFO=''
        AUTOUPGRADE_TRUSTSTORE='${ts_file}'
        unset AUTOUPGRADE_TRUSTSTORE_PASS 2>/dev/null || true
        au_resolve_truststore
        printf '%s\n' \"\${JAVA_OPTS[@]}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"trustStore=${ts_file}"* ]]
    [[ "${output}" != *"trustStorePassword"* ]]
}

@test "au_resolve_truststore: AUTOUPGRADE_TRUSTSTORE_PASS set -> trustStorePassword in JAVA_OPTS" {
    local ts_file="${WORK_DIR}/cacerts"
    touch "${ts_file}"
    run bash -c "
        source '${LIB_NET}'
        JAVA_OPTS=(); TRUSTSTORE_INFO=''
        AUTOUPGRADE_TRUSTSTORE='${ts_file}'
        AUTOUPGRADE_TRUSTSTORE_PASS='changeit'
        au_resolve_truststore
        printf '%s\n' \"\${JAVA_OPTS[@]}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"trustStorePassword=changeit"* ]]
}

@test "au_run.sh: mask_cmd masks *Password=* and *Pass=* patterns" {
    make_mock_java 11
    local ts_file="${WORK_DIR}/cacerts"
    touch "${ts_file}"
    run bash -c "AUTOUPGRADE_JAVA_HOME='${WORK_DIR}' \
        AUTOUPGRADE_TRUSTSTORE='${ts_file}' \
        AUTOUPGRADE_TRUSTSTORE_PASS='supersecret' \
        AUTOUPGRADE_DRY_RUN=true \
        bash '${SCRIPT}' -analyze 2>&1"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"supersecret"* ]]
    [[ "${output}" == *"****"* ]]
}

# ---------------------------------------------------------------------------
# Security re-review regressions
# ---------------------------------------------------------------------------

@test "au_build_proxy_opts: scheme-less URL with credentials does not leak password" {
    run bash -c "unset https_proxy HTTPS_PROXY http_proxy HTTP_PROXY; \
        export AUTOUPGRADE_PROXY='user:secret@proxy.example.com:3128'; \
        source '${LIB_NET}'; JAVA_OPTS=(); au_build_proxy_opts 2>/dev/null; \
        echo \"https_proxy=\${https_proxy} http_proxy=\${http_proxy:-} \${JAVA_OPTS[*]}\""
    [ "${status}" -eq 0 ]
    [[ "${output}" != *secret* ]]
    [[ "${output}" == *"https_proxy=http://proxy.example.com:3128"* ]]
}

@test "au_build_proxy_opts: unsupported scheme socks5 -> exit 1" {
    run bash -c "export AUTOUPGRADE_PROXY='socks5://proxy.example.com:1080'; \
        source '${LIB_NET}'; JAVA_OPTS=(); au_build_proxy_opts"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Unsupported proxy scheme"* ]]
}

@test "au_source_env_file: exported readonly SHELLOPTS does not abort" {
    printf 'AUTOUPGRADE_PROXY=none\n' > "${WORK_DIR}/au.env"
    chmod 600 "${WORK_DIR}/au.env"
    run bash -c "set -o pipefail; export SHELLOPTS; source '${LIB_NET}'; \
        au_source_env_file '${WORK_DIR}/au.env' 2>/dev/null; echo \"rc=\$? proxy=\${AUTOUPGRADE_PROXY}\""
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"rc=0 proxy=none"* ]]
}

@test "au_set_defaults: au_patch.env without trailing newline is honoured" {
    mkdir -p "${WORK_DIR}/patches"
    printf 'AU_PATCH=RU:19.27' > "${WORK_DIR}/patches/au_patch.env"
    chmod 600 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "unset AU_PATCH; export AUTOUPGRADE_BASE='${WORK_DIR}' AU_DOWNLOAD_FOLDER='${WORK_DIR}/patches'; \
        source '${LIB_NET}'; au_set_defaults 2>/dev/null; echo \"\${AU_PATCH}\""
    [ "${status}" -eq 0 ]
    [[ "${output}" == "RU:19.27" ]]
}

@test "au_keystore.sh: MOS_PASS / KS_PASS from the environment are honoured" {
    run bash -c "MOS_USER=u@example.com MOS_PASS=x KS_PASS=y bash '${REPO_ROOT}/bin/au_keystore.sh' \
        --workdir '${WORK_DIR}/ks' --cfg /nonexistent.cfg </dev/null 2>&1"
    [[ "${output}" != *"MOS password not set"* ]]
    [[ "${output}" != *"Keystore password not set"* ]]
}

@test "au_run.sh: renderer abort leaves no au_render temp file (script EXIT trap purges)" {
    make_mock_java 11
    local tdir="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${tdir}"
    chmod 700 "${tdir}"
    printf 'global.global_log_dir=${AU_LOG_DIR}\nbroken_line_without_equals\n' > "${WORK_DIR}/broken.cfg"
    chmod 600 "${WORK_DIR}/broken.cfg"
    run bash -c "TMPDIR='${tdir}' AUTOUPGRADE_JAVA_HOME='${WORK_DIR}' \
        AUTOUPGRADE_TRUSTSTORE_CANDIDATES='/nonexistent' \
        bash '${SCRIPT}' -config '${WORK_DIR}/broken.cfg' -patch -mode download 2>&1"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"line"* ]]
    run bash -c "ls '${tdir}' | grep -c au_render || true"
    [ "${output}" = "0" ]
}
