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
    # Unverified key pair -> exit 2 (warning, not hard error)
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"PKEY"* ]]
}

@test "--check exits 2 when mkstore not available (PKEY unverified)" {
    make_wallet_files "${WORK_DIR}/keystore"
    # WORK_DIR/bin has no mkstore stub; system mkstore not installed.
    # command -v mkstore fails -> "not available" warn -> exit 2.
    PATH="${WORK_DIR}/bin:${PATH}" \
        run bash "${SCRIPT}" --check --workdir "${WORK_DIR}/keystore"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"mkstore not available"* || "${output}" == *"PKEY"* ]]
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

# ---------------------------------------------------------------------------
# MUST-1: au_version_compare injection guard (SECURITY)
# Old code: arithmetic on unvalidated string could execute code.
# New code: au_version_validate rejects non-numeric strings, returns 3.
# ---------------------------------------------------------------------------

@test "au_version_validate: accepts valid version strings" {
    source "${TOOLS_LIB}"
    run au_version_validate "26.6.260925"
    [ "${status}" -eq 0 ]
}

@test "au_version_validate: rejects non-numeric version component" {
    source "${TOOLS_LIB}"
    run au_version_validate "26.a.260925"
    [ "${status}" -ne 0 ]
}

@test "au_version_compare: returns 3 for non-numeric version (injection guard)" {
    source "${TOOLS_LIB}"
    run au_version_compare "26.INVALID.260925" "26.6.260925"
    [ "${status}" -eq 3 ]
}

@test "au_version_compare: returns 3 for version with special chars" {
    source "${TOOLS_LIB}"
    # A crafted string that would execute code in old (unvalidated) arithmetic
    # The string contains characters that are invalid in a numeric version.
    # Using 'a1' prefix: au_version_validate rejects it before any arithmetic.
    run au_version_compare "a1.2.3" "26.6.260925"
    [ "${status}" -eq 3 ]
}

# ---------------------------------------------------------------------------
# MUST-2: passwords not exported to child processes
# Old code: export -n only in run_create/run_resave; --check exposed them.
# New code: export -n in main(), covers all operations including --check.
# ---------------------------------------------------------------------------

@test "--check: MOS_PASS and KS_PASS not exported to child processes" {
    make_wallet_files "${WORK_DIR}/keystore"
    local env_dump="${WORK_DIR}/mkstore_env.txt"
    # mkstore stub dumps its environment and reports PKEY1/PKEY2 present
    cat > "${WORK_DIR}/bin/mkstore" <<EOF
#!/usr/bin/env bash
env > "${env_dump}"
echo "PKEY1"
echo "PKEY2"
exit 0
EOF
    chmod +x "${WORK_DIR}/bin/mkstore"
    MOS_PASS="SECRETMOS_UNIQUE_XYZ" KS_PASS="SECRETKS_UNIQUE_XYZ" \
        PATH="${WORK_DIR}/bin:${PATH}" \
        run bash "${SCRIPT}" --check --workdir "${WORK_DIR}/keystore"
    [ "${status}" -eq 0 ]
    # mkstore must have been called (env dump must exist)
    [ -f "${env_dump}" ]
    # Passwords must NOT appear in the child process environment
    run grep "SECRETMOS_UNIQUE_XYZ" "${env_dump}"
    [ "${status}" -ne 0 ]
    run grep "SECRETKS_UNIQUE_XYZ" "${env_dump}"
    [ "${status}" -ne 0 ]
}

@test "--backup: MOS_PASS and KS_PASS not exported to child processes (tar)" {
    make_wallet_files "${WORK_DIR}/keystore"
    local env_dump="${WORK_DIR}/tar_env.txt"
    # tar stub dumps its environment
    cat > "${WORK_DIR}/bin/tar" <<EOF
#!/usr/bin/env bash
env > "${env_dump}"
exit 0
EOF
    chmod +x "${WORK_DIR}/bin/tar"
    MOS_PASS="SECRETMOS_UNIQUE_TAR" KS_PASS="SECRETKS_UNIQUE_TAR" \
        PATH="${WORK_DIR}/bin:${PATH}" \
        run bash "${SCRIPT}" --backup --workdir "${WORK_DIR}/keystore" \
            --backup-dir "${WORK_DIR}/ks_backup"
    # tar was called (env dump must exist)
    [ -f "${env_dump}" ]
    run grep "SECRETMOS_UNIQUE_TAR" "${env_dump}"
    [ "${status}" -ne 0 ]
    run grep "SECRETKS_UNIQUE_TAR" "${env_dump}"
    [ "${status}" -ne 0 ]
}

# ---------------------------------------------------------------------------
# MUST-3: backup-before-change correctness
# ---------------------------------------------------------------------------

# MUST-3a: backup failure must die, not continue
@test "--create --force: backup failure causes die not continue" {
    make_wallet_files "${WORK_DIR}/keystore"
    make_mock_expect_success
    make_mock_au_run
    # Create a FILE at the backup root path so mkdir -p fails (cannot mkdir over a file)
    touch "${WORK_DIR}/ks_backup_file"
    local cfg
    cfg="$(make_cfg)"
    PATH="${WORK_DIR}/bin:${PATH}" \
        run bash "${SCRIPT}" --create --force --yes \
            --workdir "${WORK_DIR}/keystore" \
            --backup-dir "${WORK_DIR}/ks_backup_file" \
            --cfg "${cfg}" --mos-user test@example.com \
            --insecure-argv --mos-pass pass1 --ks-pass pass2
    # Must exit non-zero (old code: log_warn "continuing" and proceeded)
    [ "${status}" -ne 0 ]
}

# MUST-3b: relative workdir does not put backup inside the keystore directory
@test "--backup with relative workdir: backup placed outside keystore" {
    local abs_ks="${WORK_DIR}/keystore"
    make_wallet_files "${abs_ks}"
    # Run from WORK_DIR with relative --workdir; no explicit --backup-dir
    run bash -c "cd '${WORK_DIR}' && bash '${SCRIPT}' --backup --workdir 'keystore'"
    [ "${status}" -eq 0 ]
    # Backup must be in sibling directory, not inside the keystore
    local bak_count
    bak_count="$(ls "${WORK_DIR}/keystore_backup"/*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
    [ "${bak_count}" -ge 1 ]
    # Must NOT have created backup inside the keystore directory
    [ ! -d "${abs_ks}/keystore_backup" ]
}

# MUST-3c: --dry-run must not trigger backup
@test "--create --dry-run --force does not write any backup" {
    make_wallet_files "${WORK_DIR}/keystore"
    local cfg
    cfg="$(make_cfg)"
    run bash "${SCRIPT}" --create --dry-run --force --yes \
        --workdir "${WORK_DIR}/keystore" \
        --backup-dir "${WORK_DIR}/ks_backup" \
        --cfg "${cfg}" --mos-user test@example.com \
        --insecure-argv --mos-pass pass1 --ks-pass pass2
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DRY-RUN"* ]]
    # No backup directory should have been created by --dry-run
    [ ! -d "${WORK_DIR}/ks_backup" ]
}

# MUST-3d: partial backup file removed on tar failure
@test "au_keystore_backup: cleans up partial backup on tar failure" {
    source "${TOOLS_LIB}"
    make_wallet_files "${WORK_DIR}/keystore"
    # tar stub creates a file then exits non-zero (simulates partial write)
    local partial_marker="${WORK_DIR}/tar_was_called"
    cat > "${WORK_DIR}/bin/tar" <<EOF
#!/usr/bin/env bash
# Find -f argument and write a partial file there
_next=0
for arg in "\$@"; do
    if [[ "\${_next}" == "1" ]]; then
        printf 'partial_data' > "\${arg}"
        break
    fi
    [[ "\${arg}" == "-f" ]] && _next=1
done
touch "${partial_marker}"
exit 1
EOF
    chmod +x "${WORK_DIR}/bin/tar"
    PATH="${WORK_DIR}/bin:${PATH}" \
        run au_keystore_backup "${WORK_DIR}/keystore" "${WORK_DIR}/ks_backup"
    [ "${status}" -ne 0 ]
    # tar was called
    [ -f "${partial_marker}" ]
    # Partial backup file must have been removed
    local remaining
    remaining="$(ls "${WORK_DIR}/ks_backup"/*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
    [ "${remaining}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# SHOULD-9: --mos-pass-file and --ks-pass-file permission checks
# ---------------------------------------------------------------------------

@test "--mos-pass-file refuses group-readable file" {
    local cfg
    cfg="$(make_cfg)"
    local pass_file="${WORK_DIR}/mos_pass.txt"
    printf 'mypassword\n' > "${pass_file}"
    chmod 640 "${pass_file}"  # group-readable
    run bash "${SCRIPT}" --create --workdir "${WORK_DIR}/keystore_pf" \
        --cfg "${cfg}" --mos-user test@example.com \
        --mos-pass-file "${pass_file}" --insecure-argv --ks-pass testks
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"readable"* || "${output}" == *"permission"* || \
       "${output}" == *"group"* || "${output}" == *"world"* ]]
}

@test "--ks-pass-file refuses world-readable file" {
    local cfg
    cfg="$(make_cfg)"
    local ks_file="${WORK_DIR}/ks_pass.txt"
    printf 'mykspass\n' > "${ks_file}"
    chmod 604 "${ks_file}"  # world-readable
    run bash "${SCRIPT}" --create --workdir "${WORK_DIR}/keystore_kf" \
        --cfg "${cfg}" --mos-user test@example.com \
        --insecure-argv --mos-pass testmos --ks-pass-file "${ks_file}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"readable"* || "${output}" == *"permission"* || \
       "${output}" == *"group"* || "${output}" == *"world"* ]]
}

@test "--mos-pass-file accepts owner-only readable file" {
    make_mock_expect_success
    make_mock_au_run
    local cfg
    cfg="$(make_cfg)"
    local pass_file="${WORK_DIR}/mos_pass_ok.txt"
    printf 'mypassword\n' > "${pass_file}"
    chmod 600 "${pass_file}"  # owner-only
    local ks_dir="${WORK_DIR}/keystore_pf_ok"
    mkdir -p "${ks_dir}"
    chmod 700 "${ks_dir}"
    PATH="${WORK_DIR}/bin:${PATH}" \
        run bash "${SCRIPT}" --create --workdir "${ks_dir}" \
            --cfg "${cfg}" --mos-user test@example.com \
            --mos-pass-file "${pass_file}" --insecure-argv --ks-pass testks
    [ "${status}" -eq 0 ]
}
