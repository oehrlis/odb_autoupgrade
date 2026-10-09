#!/usr/bin/env bats
# shellcheck disable=SC1090
# ------------------------------------------------------------------------------
# tests/lib_au_net.bats
# BATS tests for lib/au_net.sh (WP1: functions moved from au_lib.sh).
# Verifies all functions are accessible after sourcing au_lib.sh.
# ------------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    LIB="${REPO_ROOT}/lib/au_lib.sh"
    WORK_DIR="${BATS_TMPDIR}/au_net_test_$$_${RANDOM}"
    mkdir -p "${WORK_DIR}/bin"
    unset AUTOUPGRADE_PROXY https_proxy HTTPS_PROXY http_proxy HTTP_PROXY \
          no_proxy NO_PROXY AUTOUPGRADE_TRUSTSTORE AUTOUPGRADE_TRUSTSTORE_PASS \
          AUTOUPGRADE_JAVA_HOME AUTOUPGRADE_JAVA_OPTS AUTOUPGRADE_DEBUG_SSL \
          AUTOUPGRADE_TRUSTSTORE_CANDIDATES AUTOUPGRADE_JAVA_SUPPORTED \
          ORACLE_HOME 2>/dev/null || true
}

teardown() {
    rm -rf "${WORK_DIR}"
}

make_mock_java() {
    local major="$1"
    local java_bin="${WORK_DIR}/bin/java"
    local ver_str
    [[ "${major}" == "8" ]] && ver_str="1.8.0_471" || ver_str="${major}.0.11"
    cat > "${java_bin}" <<JAVASHIM
#!/usr/bin/env bash
if [[ "\$1" == "-version" ]]; then
    printf 'java version "%s"\\n' "${ver_str}" >&2; exit 0
fi
exit 0
JAVASHIM
    chmod +x "${java_bin}"
}

# ---------------------------------------------------------------------------
# au_resolve_java
# ---------------------------------------------------------------------------

@test "au_net.sh: au_resolve_java resolves Java 11 via AUTOUPGRADE_JAVA_HOME" {
    make_mock_java 11
    run bash -c "
        export AUTOUPGRADE_JAVA_HOME='${WORK_DIR}'
        export AUTOUPGRADE_JAVA_SUPPORTED='8 11'
        source '${LIB}'
        au_resolve_java
        echo \"BIN=\${JAVA_BIN}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"BIN=${WORK_DIR}/bin/java"* ]]
}

@test "au_net.sh: au_resolve_java rejects unsupported Java version" {
    make_mock_java 21
    run bash -c "
        export AUTOUPGRADE_JAVA_HOME='${WORK_DIR}'
        export AUTOUPGRADE_JAVA_SUPPORTED='8 11'
        source '${LIB}'
        au_resolve_java 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Unsupported"* ]]
}

@test "au_net.sh: au_resolve_java fails when no java binary" {
    run bash -c "
        export AUTOUPGRADE_JAVA_HOME='${WORK_DIR}'
        source '${LIB}'
        au_resolve_java 2>&1
    "
    [ "${status}" -ne 0 ]
}

# ---------------------------------------------------------------------------
# au_convert_no_proxy
# ---------------------------------------------------------------------------

@test "au_net.sh: au_convert_no_proxy converts comma list to pipe-separated" {
    run bash -c "
        source '${LIB}'
        au_convert_no_proxy 'internal.example.com,10.0.0.1'
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == "internal.example.com|10.0.0.1" ]]
}

@test "au_net.sh: au_convert_no_proxy leading dot becomes wildcard" {
    run bash -c "
        source '${LIB}'
        au_convert_no_proxy '.example.com'
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == "*.example.com" ]]
}

@test "au_net.sh: au_convert_no_proxy skips CIDR entries with WARN" {
    run bash -c "
        source '${LIB}'
        au_convert_no_proxy '10.0.0.0/8' 2>&1
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CIDR"* ]]
}

# ---------------------------------------------------------------------------
# au_build_proxy_opts
# ---------------------------------------------------------------------------

@test "au_net.sh: au_build_proxy_opts sets JAVA_OPTS for valid proxy" {
    run bash -c "
        source '${LIB}'
        JAVA_OPTS=()
        export AUTOUPGRADE_PROXY='http://proxy.example.com:3128'
        au_build_proxy_opts
        printf '%s\n' \"\${JAVA_OPTS[@]}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"proxyHost=proxy.example.com"* ]]
    [[ "${output}" == *"proxyPort=3128"* ]]
}

@test "au_net.sh: au_build_proxy_opts with none unsets all proxy vars" {
    run bash -c "
        source '${LIB}'
        JAVA_OPTS=()
        export AUTOUPGRADE_PROXY='none'
        export https_proxy='http://proxy.example.com:3128'
        au_build_proxy_opts
        echo \"proxy=\${https_proxy:-UNSET}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"proxy=UNSET"* ]]
}

@test "au_net.sh: au_build_proxy_opts rejects IPv6 address" {
    run bash -c "
        source '${LIB}'
        JAVA_OPTS=()
        export AUTOUPGRADE_PROXY='http://[::1]:3128'
        au_build_proxy_opts 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"IPv6"* ]]
}

# ---------------------------------------------------------------------------
# au_resolve_truststore
# ---------------------------------------------------------------------------

@test "au_net.sh: au_resolve_truststore none produces no JAVA_OPTS" {
    run bash -c "
        source '${LIB}'
        JAVA_OPTS=()
        export AUTOUPGRADE_TRUSTSTORE='none'
        au_resolve_truststore
        echo \"opts=\${#JAVA_OPTS[@]}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"opts=0"* ]]
}

@test "au_net.sh: au_resolve_truststore uses AUTOUPGRADE_TRUSTSTORE_CANDIDATES" {
    local fake_ts="${WORK_DIR}/fake_cacerts"
    touch "${fake_ts}"
    run bash -c "
        source '${LIB}'
        JAVA_OPTS=()
        export AUTOUPGRADE_TRUSTSTORE_CANDIDATES='${fake_ts}'
        au_resolve_truststore
        printf '%s\n' \"\${JAVA_OPTS[@]}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"trustStore=${fake_ts}"* ]]
}

# ---------------------------------------------------------------------------
# au_build_jvm_opts (integration)
# ---------------------------------------------------------------------------

@test "au_net.sh: au_build_jvm_opts appends AUTOUPGRADE_JAVA_OPTS" {
    run bash -c "
        source '${LIB}'
        JAVA_OPTS=()
        unset AUTOUPGRADE_PROXY https_proxy HTTPS_PROXY http_proxy HTTP_PROXY
        export AUTOUPGRADE_TRUSTSTORE=none
        export AUTOUPGRADE_JAVA_OPTS='-Xmx2g -Dfoo=bar'
        au_build_jvm_opts
        printf '%s\n' \"\${JAVA_OPTS[@]}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"-Xmx2g"* ]]
    [[ "${output}" == *"-Dfoo=bar"* ]]
}

@test "au_net.sh: au_build_jvm_opts adds SSL debug when AUTOUPGRADE_DEBUG_SSL=true" {
    run bash -c "
        source '${LIB}'
        JAVA_OPTS=()
        unset AUTOUPGRADE_PROXY https_proxy HTTPS_PROXY http_proxy HTTP_PROXY
        export AUTOUPGRADE_TRUSTSTORE=none
        export AUTOUPGRADE_DEBUG_SSL=true
        au_build_jvm_opts
        printf '%s\n' \"\${JAVA_OPTS[@]}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ssl:handshake"* ]]
}
