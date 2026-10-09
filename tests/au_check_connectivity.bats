#!/usr/bin/env bats
# shellcheck disable=SC1090  # dynamic source path - checked via shellcheck -x
# shellcheck disable=SC2034  # vars set for subshell use, not local scope
# ------------------------------------------------------------------------------
# tests/au_check_connectivity.bats
# BATS tests for bin/au_check_connectivity.sh and related lib/au_lib.sh changes
# ------------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    LIB="${REPO_ROOT}/lib/au_lib.sh"
    SCRIPT="${REPO_ROOT}/bin/au_check_connectivity.sh"

    WORK_DIR="${BATS_TMPDIR}/au_conn_test_$$_${RANDOM}"
    mkdir -p "${WORK_DIR}/bin" "${WORK_DIR}/keystore" "${WORK_DIR}/etc"

    # Create placeholder jar so JAR check passes in integration tests
    _FAKE_JAR_CREATED=""
    if [[ ! -f "${REPO_ROOT}/jar/autoupgrade.jar" ]]; then
        touch "${REPO_ROOT}/jar/autoupgrade.jar"
        _FAKE_JAR_CREATED="${REPO_ROOT}/jar/autoupgrade.jar"
    fi

    # Reset proxy/truststore env between tests
    unset AUTOUPGRADE_PROXY https_proxy HTTPS_PROXY http_proxy HTTP_PROXY \
          no_proxy NO_PROXY AUTOUPGRADE_TRUSTSTORE AUTOUPGRADE_TRUSTSTORE_PASS \
          AUTOUPGRADE_JAVA_HOME AUTOUPGRADE_TRUSTSTORE_CANDIDATES \
          AUTOUPGRADE_JAVA_SUPPORTED ORACLE_HOME 2>/dev/null || true
}

teardown() {
    rm -rf "${WORK_DIR}"
    if [[ -n "${_FAKE_JAR_CREATED}" ]]; then
        rm -f "${_FAKE_JAR_CREATED}"
    fi
}

# Create a mock java binary that outputs a valid version string
make_mock_java() {
    local major="${1:-11}"
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
# Print env for proxy inspection tests
if [[ "\$1" == "--print-env" ]]; then
    env | sort
    exit 0
fi
exit 0
EOF
    chmod +x "${java_bin}"
}

# Create a mock curl at WORK_DIR/bin/curl.
# Behavior controlled by env vars:
#   MOCK_CURL_EXIT     exit code (default 0)
#   MOCK_CURL_HTTP     HTTP code appended to stdout via -w (default 200)
#   MOCK_CURL_ISSUER   issuer line in verbose stderr (default DigiCert public CA)
#   MOCK_CURL_<HOST>_EXIT, MOCK_CURL_<HOST>_HTTP, MOCK_CURL_<HOST>_ISSUER
#   for per-host overrides (HOST is uppercase, hyphens replaced by underscores)
make_mock_curl() {
    cat > "${WORK_DIR}/bin/curl" << 'CURLEOF'
#!/usr/bin/env bash
# Extract URL from args (last non-option arg)
url=""
for a in "$@"; do
    case "${a}" in
        -*)  : ;;
        *)   url="${a}" ;;
    esac
done

# Derive host key: extract hostname, uppercase, replace . and - with _
host="${url#*://}"
host="${host%%/*}"
host="${host%%:*}"
host_key="${host^^}"
host_key="${host_key//./_}"
host_key="${host_key//-/_}"

# Per-host override or global default
rc_var="MOCK_CURL_${host_key}_EXIT"
http_var="MOCK_CURL_${host_key}_HTTP"
issuer_var="MOCK_CURL_${host_key}_ISSUER"

exit_code="${!rc_var:-${MOCK_CURL_EXIT:-0}}"
http_code="${!http_var:-${MOCK_CURL_HTTP:-200}}"
issuer="${!issuer_var:-${MOCK_CURL_ISSUER:-DigiCert Inc}}"

# Emit verbose issuer line to stderr (simulates curl -v TLS info).
# Uses O= format so the _is_public_ca O=-extraction logic works correctly.
# MOCK_CURL_ISSUER should be the O= value (e.g. "DigiCert Inc" or "CorpMITM").
printf '* issuer: CN=Test CA, O=%s, C=US\r\n' "${issuer}" >&2

# If -w '%{http_code}' is in args, print http code to stdout
if [[ "$*" == *'%{http_code}'* ]]; then
    printf '%s' "${http_code}"
fi

exit "${exit_code}"
CURLEOF
    chmod +x "${WORK_DIR}/bin/curl"
}

# Create a mock keytool at WORK_DIR/bin/keytool.
# MOCK_KEYTOOL_COUNT  number of trustedCertEntry lines (default 5)
# MOCK_KEYTOOL_EXIT   exit code (default 0)
# When -rfc flag is present, emit PEM blocks instead of list lines.
make_mock_keytool() {
    cat > "${WORK_DIR}/bin/keytool" << 'EOF'
#!/usr/bin/env bash
count="${MOCK_KEYTOOL_COUNT:-5}"
exit_rc="${MOCK_KEYTOOL_EXIT:-0}"
if [[ "$*" == *"-rfc"* ]]; then
    for (( i=1; i<=count; i++ )); do
        # Use '%s\n' format: avoids macOS bash treating leading dashes as flags
        printf '%s\n' "-----BEGIN CERTIFICATE-----"
        printf 'MIIFakeBase64Data%d==\n' "${i}"
        printf '%s\n' "-----END CERTIFICATE-----"
    done
    exit "${exit_rc}"
fi
for (( i=1; i<=count; i++ )); do
    printf 'alias%d, trustedCertEntry,\n' "${i}"
done
exit "${exit_rc}"
EOF
    chmod +x "${WORK_DIR}/bin/keytool"
}

# Create a mock mkstore at WORK_DIR/bin/mkstore.
# MOCK_MKSTORE_OUTPUT controls the list output (default: both PKEY1 and PKEY2)
make_mock_mkstore() {
    cat > "${WORK_DIR}/bin/mkstore" << 'EOF'
#!/usr/bin/env bash
output="${MOCK_MKSTORE_OUTPUT:-Oracle Secret Store entries:
PKEY1
PKEY2
}"
printf '%s\n' "${output}"
exit 0
EOF
    chmod +x "${WORK_DIR}/bin/mkstore"
}

# Create a keystore directory with valid wallet files (perms 0600)
make_keystore() {
    local ks_dir="${WORK_DIR}/keystore"
    mkdir -p "${ks_dir}"
    touch "${ks_dir}/ewallet.p12" "${ks_dir}/cwallet.sso"
    chmod 600 "${ks_dir}/ewallet.p12" "${ks_dir}/cwallet.sso"
}

# Run the connectivity script with PATH pointing to mock binaries.
# Merges stderr into stdout for BATS output capture.
run_conn() {
    run bash -c "PATH='${WORK_DIR}/bin:${PATH}' \
        AUTOUPGRADE_JAVA_HOME='${WORK_DIR}' \
        AUTOUPGRADE_TRUSTSTORE_CANDIDATES='/nonexistent' \
        bash '${SCRIPT}' $* 2>&1"
}

# ---------------------------------------------------------------------------
# Unit tests for lib/au_lib.sh - https_proxy export behavior
# ---------------------------------------------------------------------------

@test "au_build_proxy_opts: exports lowercase https_proxy without credentials" {
    run bash -c "
        source '${LIB}'
        JAVA_OPTS=(); PROXY_INFO=''; TRUSTSTORE_INFO=''
        AUTOUPGRADE_PROXY='http://user:secret@proxy.example.com:3128'
        au_build_proxy_opts
        echo \"https_proxy=\${https_proxy:-UNSET}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"https_proxy=http://proxy.example.com:3128"* ]]
    [[ "${output}" != *"secret"* ]]
}

@test "au_build_proxy_opts: AUTOUPGRADE_PROXY=none unsets https_proxy" {
    run bash -c "
        source '${LIB}'
        JAVA_OPTS=(); PROXY_INFO=''; TRUSTSTORE_INFO=''
        export https_proxy='http://old.example.com:8080'
        AUTOUPGRADE_PROXY=none
        au_build_proxy_opts
        echo \"https_proxy=\${https_proxy:-UNSET}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"https_proxy=UNSET"* ]]
}

@test "au_build_proxy_opts: empty proxy unsets https_proxy" {
    run bash -c "
        source '${LIB}'
        JAVA_OPTS=(); PROXY_INFO=''; TRUSTSTORE_INFO=''
        export https_proxy='http://old.example.com:8080'
        unset AUTOUPGRADE_PROXY https_proxy HTTPS_PROXY http_proxy HTTP_PROXY
        au_build_proxy_opts
        echo \"https_proxy=\${https_proxy:-UNSET}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"https_proxy=UNSET"* ]]
}

@test "au_build_proxy_opts: HTTPS_PROXY-only input exports lowercase https_proxy" {
    run bash -c "
        source '${LIB}'
        JAVA_OPTS=(); PROXY_INFO=''; TRUSTSTORE_INFO=''
        unset AUTOUPGRADE_PROXY https_proxy http_proxy HTTP_PROXY
        HTTPS_PROXY='https://corporate.proxy.example.com:8443'
        au_build_proxy_opts
        echo \"https_proxy=\${https_proxy:-UNSET}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"https_proxy="*"corporate.proxy.example.com:8443"* ]]
}

@test "au_build_proxy_opts: credentials not present in exported https_proxy" {
    run bash -c "
        source '${LIB}'
        JAVA_OPTS=(); PROXY_INFO=''; TRUSTSTORE_INFO=''
        https_proxy='http://myuser:mypass@proxy.example.com:8080'
        au_build_proxy_opts
        echo \"proxy=\${https_proxy:-UNSET}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"myuser"* ]]
    [[ "${output}" != *"mypass"* ]]
    [[ "${output}" == *"proxy.example.com:8080"* ]]
}

# ---------------------------------------------------------------------------
# Integration: endpoint connectivity checks
# ---------------------------------------------------------------------------

@test "au_check_connectivity: all endpoints OK with public CA -> exit 0" {
    make_mock_java 11
    make_mock_curl
    make_mock_keytool
    make_mock_mkstore
    make_keystore
    local ts_file="${WORK_DIR}/cacerts"
    touch "${ts_file}"
    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="DigiCert Inc" \
    AUTOUPGRADE_TRUSTSTORE="${ts_file}" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"[OK]"* ]]
}

@test "au_check_connectivity: DNS failure for one endpoint -> exit 1, host in summary" {
    make_mock_java 11
    make_mock_curl
    make_keystore
    # Override login-ext host to return curl exit 6 (DNS failure)
    MOCK_CURL_LOGIN_EXT_IDENTITY_ORACLECLOUD_COM_EXIT=6 \
    MOCK_CURL_HTTP=200 \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"[FAIL]"* ]]
    [[ "${output}" == *"DNS resolution failed"* ]]
    [[ "${output}" == *"login-ext.identity.oraclecloud.com"* ]]
}

@test "au_check_connectivity: PKIX error -> FAIL with TLS error message" {
    make_mock_java 11
    make_mock_curl
    make_keystore
    MOCK_CURL_UPDATES_ORACLE_COM_EXIT=60 \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"TLS certificate error"* ]]
}

@test "au_check_connectivity: non-public issuer -> WARN, host in summary" {
    make_mock_java 11
    make_mock_curl
    make_keystore
    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="CorpMITM" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[WARN]"* ]]
    [[ "${output}" == *"TLS inspection"* ]]
    [[ "${output}" == *"Network team"* ]]
}

@test "au_check_connectivity: proxy credentials never printed" {
    make_mock_java 11
    make_mock_curl
    make_keystore
    MOCK_CURL_HTTP=200 \
    AUTOUPGRADE_PROXY="http://proxyuser:s3cr3t@proxy.example.com:3128" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [[ "${output}" != *"s3cr3t"* ]]
    [[ "${output}" != *"proxyuser"* ]]
}

@test "au_check_connectivity: --dry-run lists endpoints and exits 0" {
    make_mock_java 11
    run_conn "--dry-run --keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DRY-RUN"* ]]
    [[ "${output}" == *"login-ext.identity.oraclecloud.com"* ]]
}

@test "au_check_connectivity: endpoints override file is used" {
    make_mock_java 11
    make_mock_curl
    make_keystore
    local ep_file="${WORK_DIR}/endpoints.txt"
    cat > "${ep_file}" <<'EPEOF'
# comment line
custom.example.com|https://custom.example.com/|Custom endpoint|test
EPEOF
    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="DigiCert Inc" \
    run_conn "--endpoints '${ep_file}' --keystore '${WORK_DIR}/keystore'"
    [[ "${output}" == *"custom.example.com"* ]]
    # Built-in endpoints should NOT appear
    [[ "${output}" != *"login-ext.identity.oraclecloud.com"* ]]
}

@test "au_check_connectivity: keystore missing -> FAIL" {
    make_mock_java 11
    make_mock_curl
    run_conn "--keystore '${WORK_DIR}/nodir'"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"[FAIL]"* ]]
    [[ "${output}" == *"directory not found"* ]]
}

@test "au_check_connectivity: keystore file perms wrong -> WARN" {
    make_mock_java 11
    make_mock_curl
    make_keystore
    chmod 644 "${WORK_DIR}/keystore/ewallet.p12"
    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="DigiCert Inc" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[WARN]"* ]]
    [[ "${output}" == *"expected 0600"* ]]
}

@test "au_check_connectivity: keystore .autoupgrade symlink -> FAIL" {
    make_mock_java 11
    make_mock_curl
    make_keystore
    mkdir -p "${WORK_DIR}/keystore/.autoupgrade_target"
    ln -s "${WORK_DIR}/keystore/.autoupgrade_target" \
        "${WORK_DIR}/keystore/.autoupgrade"
    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="DigiCert Inc" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"[FAIL]"* ]]
    [[ "${output}" == *"symlink"* ]]
}

@test "au_check_connectivity: mkstore OK with PKEY1 and PKEY2 -> [OK]" {
    make_mock_java 11
    make_mock_curl
    make_mock_mkstore
    make_keystore
    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="DigiCert Inc" \
    MOCK_MKSTORE_OUTPUT="PKEY1
PKEY2" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [[ "${output}" == *"[OK] keystore keypair: PKEY1 and PKEY2 present"* ]]
}

@test "au_check_connectivity: mkstore missing PKEY1/PKEY2 -> [FAIL]" {
    make_mock_java 11
    make_mock_curl
    make_mock_mkstore
    make_keystore
    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="DigiCert Inc" \
    MOCK_MKSTORE_OUTPUT="Oracle Secret Store entries:
oracle.security.client.connect_string1
oracle.security.client.username1" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"[FAIL] keystore keypair"* ]]
}

@test "au_check_connectivity: exit 0 when all checks pass" {
    make_mock_java 11
    make_mock_curl
    make_mock_mkstore
    make_mock_keytool
    make_keystore
    # Provide a readable truststore candidate so truststore check is OK
    local ts_file="${WORK_DIR}/cacerts"
    touch "${ts_file}"
    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="DigiCert Inc" \
    AUTOUPGRADE_TRUSTSTORE="${ts_file}" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 0 ]
}

@test "au_check_connectivity: exit 2 when only WARN" {
    make_mock_java 11
    make_mock_curl
    make_keystore
    # Non-public issuer on all hosts -> all WARN, no FAIL
    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="CorpIntercept" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 2 ]
}

@test "au_check_connectivity: exit 1 when FAIL present" {
    make_mock_java 11
    make_mock_curl
    make_keystore
    MOCK_CURL_EXIT=6 \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 1 ]
}

# ---------------------------------------------------------------------------
# HTTP status classification (any answer after TLS = reachable)
# ---------------------------------------------------------------------------

@test "au_check_connectivity: HTTP 405 and 404 count as reachable, not flagged" {
    make_mock_java 11
    make_mock_curl
    make_mock_keytool
    make_mock_mkstore
    make_keystore
    touch "${WORK_DIR}/cacerts"
    MOCK_CURL_LOGIN_EXT_IDENTITY_ORACLECLOUD_COM_HTTP=405 \
    MOCK_CURL_OBJECTSTORAGE_US_ASHBURN_1_ORACLECLOUD_COM_HTTP=404 \
    AUTOUPGRADE_TRUSTSTORE="${WORK_DIR}/cacerts" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Network team"* ]]
}

@test "au_check_connectivity: HTTP 407 -> FAIL proxy authentication, host flagged" {
    make_mock_java 11
    make_mock_curl
    make_keystore
    MOCK_CURL_UPDATES_ORACLE_COM_HTTP=407 \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"proxy authentication required"* ]]
    [[ "${output}" == *"Network team"* ]]
}

@test "au_check_connectivity: HTTP 502 -> WARN, host flagged" {
    make_mock_java 11
    make_mock_curl
    make_mock_keytool
    make_mock_mkstore
    make_keystore
    touch "${WORK_DIR}/cacerts"
    MOCK_CURL_TRANSPORT_ORACLE_COM_HTTP=502 \
    AUTOUPGRADE_TRUSTSTORE="${WORK_DIR}/cacerts" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[WARN] transport.oracle.com"* ]]
}

@test "au_check_connectivity: unusable Java -> FAIL, network checks still run" {
    make_mock_curl
    make_keystore
    mkdir -p "${WORK_DIR}/nojava/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${WORK_DIR}/nojava/bin/java"
    chmod +x "${WORK_DIR}/nojava/bin/java"
    AUTOUPGRADE_JAVA_HOME="${WORK_DIR}/nojava" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"[FAIL] java"* ]]
    [[ "${output}" == *"updates.oracle.com"* ]]
}

# ---------------------------------------------------------------------------
# Security: au_check_truststore with -storepass:env (finding 8)
# ---------------------------------------------------------------------------

@test "au_check_truststore: keytool exit non-zero -> FAIL" {
    make_mock_java 11
    make_mock_curl
    make_mock_keytool
    make_keystore
    touch "${WORK_DIR}/cacerts"
    # keytool exits 1
    MOCK_KEYTOOL_EXIT=1 \
    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="DigiCert Inc" \
    AUTOUPGRADE_TRUSTSTORE="${WORK_DIR}/cacerts" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"[FAIL] truststore"* ]]
    [[ "${output}" == *"keytool failed"* ]]
}

@test "au_check_truststore: 0 trusted cert entries -> FAIL" {
    make_mock_java 11
    make_mock_curl
    make_mock_keytool
    make_keystore
    touch "${WORK_DIR}/cacerts"
    # keytool exits 0 but prints 0 trustedCertEntry lines
    MOCK_KEYTOOL_COUNT=0 \
    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="DigiCert Inc" \
    AUTOUPGRADE_TRUSTSTORE="${WORK_DIR}/cacerts" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"[FAIL] truststore"* ]]
    [[ "${output}" == *"0 trusted cert entries"* ]]
}

@test "au_check_truststore: 5 entries -> OK" {
    make_mock_java 11
    make_mock_curl
    make_mock_keytool
    make_mock_mkstore
    make_keystore
    touch "${WORK_DIR}/cacerts"
    MOCK_KEYTOOL_COUNT=5 \
    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="DigiCert Inc" \
    AUTOUPGRADE_TRUSTSTORE="${WORK_DIR}/cacerts" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [[ "${output}" == *"[OK] truststore"* ]]
    [[ "${output}" == *"5 trusted cert entries"* ]]
}

# ---------------------------------------------------------------------------
# Security: truststore PEM for curl --cacert alignment (finding 9)
# ---------------------------------------------------------------------------

@test "au_check_connectivity: truststore PEM built - curl receives --cacert" {
    make_mock_java 11
    make_mock_keytool
    make_mock_mkstore
    make_keystore
    touch "${WORK_DIR}/cacerts"

    # Create a curl mock that records its arguments
    cat > "${WORK_DIR}/bin/curl" << 'CURLEOF'
#!/usr/bin/env bash
# Record all args to a file for inspection
printf '%s\n' "$@" >> "${WORK_DIR_PASS}/curl_args"
# Emit issuer line
printf '* issuer: CN=Test CA, O=DigiCert Inc, C=US\r\n' >&2
# Print http code if requested
if [[ "$*" == *'%{http_code}'* ]]; then
    printf '200'
fi
exit 0
CURLEOF
    chmod +x "${WORK_DIR}/bin/curl"
    # Rewrite the curl mock to inject WORK_DIR at runtime
    cat > "${WORK_DIR}/bin/curl" << CURLEOF2
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "${WORK_DIR}/curl_args"
printf '* issuer: CN=Test CA, O=DigiCert Inc, C=US\r\n' >&2
if [[ "\$*" == *'%{http_code}'* ]]; then
    printf '200'
fi
exit 0
CURLEOF2
    chmod +x "${WORK_DIR}/bin/curl"

    MOCK_KEYTOOL_COUNT=3 \
    AUTOUPGRADE_TRUSTSTORE="${WORK_DIR}/cacerts" \
    run_conn "--keystore '${WORK_DIR}/keystore'"

    # --cacert must appear in curl args (truststore PEM was built)
    [[ -f "${WORK_DIR}/curl_args" ]]
    grep -q -- '--cacert' "${WORK_DIR}/curl_args"
}

@test "au_check_connectivity: no keytool -> WARN about CA bundle mismatch" {
    make_mock_java 11
    make_mock_curl
    make_keystore
    touch "${WORK_DIR}/cacerts"

    # Remove mock keytool so it's not available
    rm -f "${WORK_DIR}/bin/keytool"

    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="DigiCert Inc" \
    AUTOUPGRADE_TRUSTSTORE="${WORK_DIR}/cacerts" \
    run_conn "--keystore '${WORK_DIR}/keystore'"

    # Should warn that curl and Java may use different trust anchors
    [[ "${output}" == *"TLS results may differ"* ]]
}

# ---------------------------------------------------------------------------
# Security: issuer O= heuristic - Oracle/Microsoft not in public CA list (finding 11)
# ---------------------------------------------------------------------------

@test "au_check_connectivity: Oracle Corporation issuer -> WARN (not in public CA list)" {
    make_mock_java 11
    make_mock_curl
    make_keystore
    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="Oracle Corporation" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[WARN]"* ]]
    [[ "${output}" == *"non-public issuer"* ]]
}

@test "au_check_connectivity: Microsoft Corporation issuer -> WARN (not in public CA list)" {
    make_mock_java 11
    make_mock_curl
    make_keystore
    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="Microsoft Corporation" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"[WARN]"* ]]
    [[ "${output}" == *"non-public issuer"* ]]
}

@test "au_check_connectivity: DigiCert Inc issuer -> OK (known public CA)" {
    make_mock_java 11
    make_mock_curl
    make_mock_keytool
    make_mock_mkstore
    make_keystore
    touch "${WORK_DIR}/cacerts"
    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="DigiCert Inc" \
    AUTOUPGRADE_TRUSTSTORE="${WORK_DIR}/cacerts" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"[OK]"*"DigiCert Inc"* ]]
}

@test "au_check_connectivity: Amazon issuer -> OK (known public CA)" {
    make_mock_java 11
    make_mock_curl
    make_mock_keytool
    make_mock_mkstore
    make_keystore
    touch "${WORK_DIR}/cacerts"
    MOCK_CURL_HTTP=200 \
    MOCK_CURL_ISSUER="Amazon" \
    AUTOUPGRADE_TRUSTSTORE="${WORK_DIR}/cacerts" \
    run_conn "--keystore '${WORK_DIR}/keystore'"
    [ "${status}" -eq 0 ]
}

@test "_is_public_ca: O= anchored, commas inside values, every O= checked" {
    run bash -c "source <(sed -n '/^AU_PUBLIC_CA_PATTERNS=/,/^done$/p;/^_is_public_ca()/,/^}/p' '${REPO_ROOT}/bin/au_check_connectivity.sh'); \
        _is_public_ca 'C=US; O=Entrust, Inc.; CN=Entrust Certification Authority - L1K' && echo entrust=ok; \
        _is_public_ca 'CN=fakeO=DigiCert Inc; O=Contoso' || echo fake=rejected; \
        _is_public_ca 'C=US; O=DigiCert Inc; CN=DigiCert Global G2 TLS RSA SHA256 2020 CA1' && echo digicert=ok"
    [[ "${output}" == *"entrust=ok"* ]]
    [[ "${output}" == *"fake=rejected"* ]]
    [[ "${output}" == *"digicert=ok"* ]]
}
