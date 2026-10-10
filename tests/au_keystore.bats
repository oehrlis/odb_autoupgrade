#!/usr/bin/env bats
# shellcheck disable=SC1090  # dynamic source path - checked via shellcheck -x
# shellcheck disable=SC2034  # vars set for subshell use
# ------------------------------------------------------------------------------
# tests/au_keystore.bats
# BATS tests for bin/au_keystore.sh (WP6: --check, --resave, --backup)
# and lib/au_tools.sh keystore helper functions.
# External commands: expect, mkstore mocked via PATH stubs in WORK_DIR/bin.
# ------------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    SCRIPT="${REPO_ROOT}/bin/au_keystore.sh"
    TOOLS_LIB="${REPO_ROOT}/lib/au_tools.sh"

    WORK_DIR="${BATS_TMPDIR}/ks_test_$$_${RANDOM}"
    mkdir -p "${WORK_DIR}/bin" "${WORK_DIR}/keystore" "${WORK_DIR}/etc"
    mkdir -p "${WORK_DIR}/jar"

    # Ensure a placeholder jar exists for the repo (for integration context)
    _FAKE_JAR_CREATED=""
    if [[ ! -f "${REPO_ROOT}/jar/autoupgrade.jar" ]]; then
        touch "${REPO_ROOT}/jar/autoupgrade.jar"
        _FAKE_JAR_CREATED="${REPO_ROOT}/jar/autoupgrade.jar"
    fi
    unset AU_KEYSTORE MOS_USER MOS_PASS KS_PASS 2>/dev/null || true
}

teardown() {
    rm -rf "${WORK_DIR}"
    if [[ -n "${_FAKE_JAR_CREATED:-}" ]]; then
        rm -f "${_FAKE_JAR_CREATED}"
    fi
}

# ---------------------------------------------------------------------------
# Mock helpers
# ---------------------------------------------------------------------------

make_mock_au_run() {
    cat > "${WORK_DIR}/bin/au_run.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${WORK_DIR}/bin/au_run.sh"
}

make_mock_expect_success() {
    # Stub expect that just exits 0 (simulates successful keystore creation)
    cat > "${WORK_DIR}/bin/expect" <<'EXPECTSTUB'
#!/usr/bin/env bash
# Consume the heredoc from stdin; create wallet files in CWD
cat > /dev/null
touch ewallet.p12 cwallet.sso
chmod 600 ewallet.p12 cwallet.sso
exit 0
EXPECTSTUB
    chmod +x "${WORK_DIR}/bin/expect"
}

make_mock_expect_fail() {
    cat > "${WORK_DIR}/bin/expect" <<'EXPECTSTUB'
#!/usr/bin/env bash
cat > /dev/null
exit 1
EXPECTSTUB
    chmod +x "${WORK_DIR}/bin/expect"
}

make_mock_mkstore_with_keys() {
    cat > "${WORK_DIR}/bin/mkstore" <<'EOF'
#!/usr/bin/env bash
echo "oracle.security.client.connect_string1"
echo "PKEY1"
echo "PKEY2"
echo "ARU_MAP"
echo "ARU_SECRET"
exit 0
EOF
    chmod +x "${WORK_DIR}/bin/mkstore"
}

make_mock_mkstore_without_keys() {
    cat > "${WORK_DIR}/bin/mkstore" <<'EOF'
#!/usr/bin/env bash
echo "ARU_MAP"
echo "ARU_SECRET"
exit 0
EOF
    chmod +x "${WORK_DIR}/bin/mkstore"
}

make_wallet_files() {
    local ks_dir="${1:-${WORK_DIR}/keystore}"
    mkdir -p "${ks_dir}"
    chmod 700 "${ks_dir}"
    touch "${ks_dir}/ewallet.p12" "${ks_dir}/cwallet.sso"
    chmod 600 "${ks_dir}/ewallet.p12" "${ks_dir}/cwallet.sso"
}

make_cfg() {
    local cfg="${WORK_DIR}/etc/au_keystore.cfg"
    printf 'global.global_log_dir=%s\nglobal.keystore=%s\n' \
        "${WORK_DIR}/logs" "${WORK_DIR}/keystore" > "${cfg}"
    printf '%s\n' "${cfg}"
}

# ---------------------------------------------------------------------------
# lib/au_tools.sh unit tests
# ---------------------------------------------------------------------------

@test "au_jar_version: extracts version from valid MANIFEST" {
    source "${TOOLS_LIB}"
    local jar="${WORK_DIR}/test.jar"
    # Create a minimal JAR with MANIFEST.MF
    mkdir -p "${WORK_DIR}/META-INF"
    printf 'Manifest-Version: 1.0\nMain-Class: oracle.boot.JointBoot\nImplementation-Version: 26.6.260925\n' \
        > "${WORK_DIR}/META-INF/MANIFEST.MF"
    (cd "${WORK_DIR}" && zip -q "${jar}" META-INF/MANIFEST.MF)
    run au_jar_version "${jar}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "26.6.260925" ]
}

@test "au_jar_version: returns 1 for missing file" {
    source "${TOOLS_LIB}"
    run au_jar_version "/nonexistent/file.jar"
    [ "${status}" -eq 1 ]
}

@test "au_version_compare: newer > older returns 1" {
    source "${TOOLS_LIB}"
    run au_version_compare "26.7.261010" "26.6.260925"
    [ "${status}" -eq 1 ]
}

@test "au_version_compare: same version returns 0" {
    source "${TOOLS_LIB}"
    run au_version_compare "26.6.260925" "26.6.260925"
    [ "${status}" -eq 0 ]
}

@test "au_version_compare: older < newer returns 2" {
    source "${TOOLS_LIB}"
    run au_version_compare "26.5.260701" "26.6.260925"
    [ "${status}" -eq 2 ]
}

@test "au_sha256: returns hash string" {
    source "${TOOLS_LIB}"
    local f="${WORK_DIR}/testfile"
    printf 'hello\n' > "${f}"
    run au_sha256 "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" =~ ^[0-9a-f]{64}$ ]]
}

@test "au_file_size: returns correct size" {
    source "${TOOLS_LIB}"
    local f="${WORK_DIR}/sizefile"
    printf 'abc' > "${f}"
    run au_file_size "${f}"
    [ "${status}" -eq 0 ]
    [ "${output}" -eq 3 ]
}

@test "au_file_perms: returns octal perms" {
    source "${TOOLS_LIB}"
    local f="${WORK_DIR}/permfile"
    touch "${f}"
    chmod 600 "${f}"
    run au_file_perms "${f}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "600" ]
}

@test "au_keystore_backup: creates 0600 tar.gz in 0700 backup dir" {
    source "${TOOLS_LIB}"
    make_wallet_files "${WORK_DIR}/keystore"
    run au_keystore_backup "${WORK_DIR}/keystore" "${WORK_DIR}/ks_backup"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *.tar.gz ]]
    local bak="${output}"
    [ -f "${bak}" ]
    local perms
    perms="$(au_file_perms "${bak}")"
    [ "${perms}" = "600" ]
    local dir_perms
    dir_perms="$(au_file_perms "${WORK_DIR}/ks_backup")"
    [ "${dir_perms}" = "700" ]
}

@test "au_prune_backups: keeps only N most recent" {
    source "${TOOLS_LIB}"
    local backup_dir="${WORK_DIR}/ks_backup"
    mkdir -p "${backup_dir}"
    # Create 5 fake backup files with different timestamps via touch
    local i
    for i in 1 2 3 4 5; do
        touch "${backup_dir}/keystore_2026010${i}_120000.tar.gz"
        sleep 0.05 2>/dev/null || true
    done
    au_prune_backups "${backup_dir}" 3
    local remaining
    # shellcheck disable=SC2012
    remaining="$(ls "${backup_dir}"/*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
    [ "${remaining}" -eq 3 ]
}

# ---------------------------------------------------------------------------
# au_keystore.sh --check tests
# ---------------------------------------------------------------------------

@test "--check passes on valid keystore" {
    make_wallet_files "${WORK_DIR}/keystore"
    make_mock_mkstore_with_keys
    # shellcheck disable=SC2030,SC2031
    PATH="${WORK_DIR}/bin:${PATH}" run bash "${SCRIPT}" --check --workdir "${WORK_DIR}/keystore"
    [ "${status}" -eq 0 ]
}

@test "--check fails when keystore dir missing" {
    run bash "${SCRIPT}" --check --workdir "${WORK_DIR}/no_such_dir"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"not found"* || "${stderr}" == *"not found"* ]]
}

@test "--check warns on wrong dir permissions" {
    make_wallet_files "${WORK_DIR}/keystore"
    chmod 755 "${WORK_DIR}/keystore"
    run bash "${SCRIPT}" --check --workdir "${WORK_DIR}/keystore"
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"700"* || "${stderr}" == *"700"* ]]
}

@test "--check warns on wrong ewallet.p12 permissions" {
    make_wallet_files "${WORK_DIR}/keystore"
    chmod 644 "${WORK_DIR}/keystore/ewallet.p12"
    run bash "${SCRIPT}" --check --workdir "${WORK_DIR}/keystore"
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"600"* || "${stderr}" == *"600"* ]]
}

@test "--check fails on symlinked keystore dir" {
    mkdir -p "${WORK_DIR}/real_ks"
    make_wallet_files "${WORK_DIR}/real_ks"
    ln -s "${WORK_DIR}/real_ks" "${WORK_DIR}/link_ks"
    run bash "${SCRIPT}" --check --workdir "${WORK_DIR}/link_ks"
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"symlink"* || "${stderr}" == *"symlink"* ]]
}

@test "--check warns on .autoupgrade subdir group-writable" {
    make_wallet_files "${WORK_DIR}/keystore"
    mkdir -p "${WORK_DIR}/keystore/.autoupgrade"
    chmod 775 "${WORK_DIR}/keystore/.autoupgrade"
    run bash "${SCRIPT}" --check --workdir "${WORK_DIR}/keystore"
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"group/world-writable"* || "${stderr}" == *"group/world-writable"* ]]
}

@test "--check warns when mkstore missing PKEY1/PKEY2" {
    make_wallet_files "${WORK_DIR}/keystore"
    make_mock_mkstore_without_keys
    # shellcheck disable=SC2030,SC2031
    PATH="${WORK_DIR}/bin:${PATH}" run bash "${SCRIPT}" --check --workdir "${WORK_DIR}/keystore"
    # Key pair check is best-effort (WARN not ERROR); basic perms pass -> exit 0
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PKEY"* ]]
}

@test "--check warns when mkstore not available" {
    make_wallet_files "${WORK_DIR}/keystore"
    # Ensure mkstore is not in PATH
    run bash "${SCRIPT}" --check --workdir "${WORK_DIR}/keystore"
    # Should warn but overall check depends on perms only
    [[ "${output}${output}" == *"mkstore not available"* || "${stderr}" == *"mkstore not available"* ]]
}

# ---------------------------------------------------------------------------
# au_keystore.sh --backup tests
# ---------------------------------------------------------------------------

@test "--backup creates tar.gz backup" {
    make_wallet_files "${WORK_DIR}/keystore"
    run bash "${SCRIPT}" --backup --workdir "${WORK_DIR}/keystore" \
        --backup-dir "${WORK_DIR}/ks_backup" --verbose
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Backup created"* ]]
    local bak_count
    # shellcheck disable=SC2012
    bak_count="$(ls "${WORK_DIR}/ks_backup"/*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
    [ "${bak_count}" -eq 1 ]
}

@test "--backup fails when workdir does not exist" {
    run bash "${SCRIPT}" --backup --workdir "${WORK_DIR}/no_such_dir"
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"not found"* || "${stderr}" == *"not found"* ]]
}

# ---------------------------------------------------------------------------
# au_keystore.sh --create tests
# ---------------------------------------------------------------------------

@test "--create skips when wallet already exists (no --force)" {
    make_wallet_files "${WORK_DIR}/keystore"
    local cfg
    cfg="$(make_cfg)"
    run bash "${SCRIPT}" --create --workdir "${WORK_DIR}/keystore" \
        --cfg "${cfg}" --mos-user test@example.com \
        --insecure-argv --mos-pass pass1 --ks-pass pass2 --verbose
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Skipping"* ]]
}

@test "--create requires --mos-user" {
    local cfg
    cfg="$(make_cfg)"
    run bash "${SCRIPT}" --create --workdir "${WORK_DIR}/keystore2" \
        --cfg "${cfg}" --insecure-argv --mos-pass pass1 --ks-pass pass2
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"mos-user"* || "${stderr}" == *"mos-user"* ]]
}

@test "--create refuses symlinked workdir" {
    mkdir -p "${WORK_DIR}/real_ks2"
    ln -s "${WORK_DIR}/real_ks2" "${WORK_DIR}/link_ks2"
    local cfg
    cfg="$(make_cfg)"
    run bash "${SCRIPT}" --create --workdir "${WORK_DIR}/link_ks2" \
        --cfg "${cfg}" --mos-user test@example.com \
        --insecure-argv --mos-pass pass1 --ks-pass pass2
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"symlink"* || "${stderr}" == *"symlink"* ]]
}

@test "--create requires --insecure-argv to use --mos-pass on argv" {
    local cfg
    cfg="$(make_cfg)"
    run bash "${SCRIPT}" --create --workdir "${WORK_DIR}/keystore3" \
        --cfg "${cfg}" --mos-user test@example.com \
        --mos-pass pass1 --ks-pass pass2
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"insecure-argv"* || "${stderr}" == *"insecure-argv"* ]]
}

@test "--create fails when cfg not found" {
    run bash "${SCRIPT}" --create --workdir "${WORK_DIR}/keystore4" \
        --cfg /nonexistent/file.cfg --mos-user test@example.com \
        --insecure-argv --mos-pass pass1 --ks-pass pass2
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"not found"* || "${stderr}" == *"not found"* ]]
}

@test "--auto-login rejects invalid mode" {
    run bash "${SCRIPT}" --check --auto-login INVALID --workdir "${WORK_DIR}/keystore"
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"YES, SHARED, or NO"* || "${stderr}" == *"YES, SHARED, or NO"* ]]
}

@test "--help prints usage and exits 0" {
    run bash "${SCRIPT}" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage:"* ]]
}
