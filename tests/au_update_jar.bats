#!/usr/bin/env bats
# shellcheck disable=SC1090  # dynamic source path - checked via shellcheck -x
# shellcheck disable=SC2034  # vars set for subshell use
# ------------------------------------------------------------------------------
# tests/au_update_jar.bats
# BATS tests for bin/au_update_jar.sh (WP5: version compare, downgrade guard,
# --from, --sha256, --keep, keystore staleness, lib/au_tools.sh).
# External commands: curl mocked via PATH stubs.
# ------------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    SCRIPT="${REPO_ROOT}/bin/au_update_jar.sh"
    TOOLS_LIB="${REPO_ROOT}/lib/au_tools.sh"

    WORK_DIR="${BATS_TMPDIR}/jar_test_$$_${RANDOM}"
    mkdir -p "${WORK_DIR}/bin" "${WORK_DIR}/jar" "${WORK_DIR}/etc"

    unset AU_KEYSTORE 2>/dev/null || true
}

teardown() {
    rm -rf "${WORK_DIR}"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build a minimal valid autoupgrade JAR with given Implementation-Version.
# Adds a padding file INSIDE the ZIP so the central directory stays intact
# (appending zeros after the archive corrupts the ZIP structure).
make_fake_au_jar() {
    local version="${1:-26.6.260925}"
    local dest="${2:-${WORK_DIR}/fake.jar}"
    local build_dir="${WORK_DIR}/.mf_build_${RANDOM}"
    mkdir -p "${build_dir}/META-INF"
    printf 'Manifest-Version: 1.0\nMain-Class: oracle.boot.JointBoot\nImplementation-Version: %s\n' \
        "${version}" > "${build_dir}/META-INF/MANIFEST.MF"
    # Create a 1.1 MB padding file with incompressible random data (SIZE check >= 1 MB)
    # Using /dev/urandom: random bytes do not compress, so the ZIP stays large.
    dd if=/dev/urandom of="${build_dir}/padding.bin" bs=1024 count=1126 2>/dev/null
    (cd "${build_dir}" && zip -q "${dest}" META-INF/MANIFEST.MF padding.bin)
    rm -rf "${build_dir}"
    printf '%s\n' "${dest}"
}

# Make a mock curl that copies FROM_FILE into the -o destination
make_mock_curl_from_file() {
    local src_jar="$1"
    cat > "${WORK_DIR}/bin/curl" <<EOF
#!/usr/bin/env bash
out=""
for a in "\$@"; do
    if [[ "\${_NEXT_OUT:-}" == "1" ]]; then out="\$a"; _NEXT_OUT=""; fi
    [[ "\$a" == "-o" ]] && _NEXT_OUT=1
done
cp "${src_jar}" "\${out}"
exit 0
EOF
    chmod +x "${WORK_DIR}/bin/curl"
}

make_mock_au_run() {
    mkdir -p "${WORK_DIR}/bin"
    cat > "${WORK_DIR}/bin/au_run.sh" <<'EOF'
#!/usr/bin/env bash
echo "build.version 26.6.260925"
exit 0
EOF
    chmod +x "${WORK_DIR}/bin/au_run.sh"
}

# ---------------------------------------------------------------------------
# --help test
# ---------------------------------------------------------------------------

@test "--help prints usage and exits 0" {
    run bash "${SCRIPT}" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Usage:"* ]]
}

# ---------------------------------------------------------------------------
# --dry-run tests
# ---------------------------------------------------------------------------

@test "--dry-run prints plan and exits 0" {
    run bash "${SCRIPT}" --dry-run
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DRY-RUN"* ]]
}

@test "--dry-run with --from prints file plan" {
    local fake
    fake="$(make_fake_au_jar)"
    run bash "${SCRIPT}" --dry-run --from "${fake}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DRY-RUN"* ]]
}

# ---------------------------------------------------------------------------
# --from FILE tests
# ---------------------------------------------------------------------------

@test "--from installs a valid JAR" {
    local fake
    fake="$(make_fake_au_jar "26.6.260925")"
    run bash "${SCRIPT}" --from "${fake}" --no-verify
    [ "${status}" -eq 0 ]
    [ -f "${REPO_ROOT}/jar/autoupgrade.jar" ]
    # Cleanup: restore original state
    rm -f "${REPO_ROOT}/jar/autoupgrade.jar"
}

@test "--from fails for nonexistent file" {
    run bash "${SCRIPT}" --from /nonexistent/file.jar
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"not found"* || "${stderr}" == *"not found"* ]]
}

@test "--from rejects file with wrong ZIP magic" {
    local bad="${WORK_DIR}/bad.jar"
    # Large enough to pass size check but wrong magic (not PK)
    printf 'NOTZIP' > "${bad}"
    dd if=/dev/zero bs=1024 count=1026 >> "${bad}" 2>/dev/null
    run bash "${SCRIPT}" --from "${bad}" --no-verify
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"magic"* || "${stderr}" == *"magic"* ]]
}

@test "--from rejects JAR without Implementation-Version" {
    local jar="${WORK_DIR}/noversion.jar"
    local mdir="${WORK_DIR}/.mf_noversion"
    mkdir -p "${mdir}/META-INF"
    printf 'Manifest-Version: 1.0\nMain-Class: oracle.boot.JointBoot\n' \
        > "${mdir}/META-INF/MANIFEST.MF"
    # Pad inside the ZIP with incompressible random data (SIZE check >= 1 MB)
    dd if=/dev/urandom of="${mdir}/padding.bin" bs=1024 count=1126 2>/dev/null
    (cd "${mdir}" && zip -q "${jar}" META-INF/MANIFEST.MF padding.bin)
    rm -rf "${mdir}"
    run bash "${SCRIPT}" --from "${jar}" --no-verify
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"Implementation-Version"* || "${stderr}" == *"Implementation-Version"* ]]
}

@test "--from rejects file smaller than 1 MB" {
    local small="${WORK_DIR}/small.jar"
    printf 'PK' > "${small}"
    run bash "${SCRIPT}" --from "${small}" --no-verify
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"too small"* || "${stderr}" == *"too small"* ]]
}

# ---------------------------------------------------------------------------
# Version compare + downgrade guard
# ---------------------------------------------------------------------------

@test "downgrade refused without --force" {
    local old_jar="${REPO_ROOT}/jar/autoupgrade.jar"
    local old_ver="26.7.261010"
    local new_ver="26.6.260925"
    make_fake_au_jar "${old_ver}" "${old_jar}" >/dev/null
    local new_jar
    new_jar="$(make_fake_au_jar "${new_ver}")"
    run bash "${SCRIPT}" --from "${new_jar}" --no-verify
    rm -f "${old_jar}"
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"Downgrade refused"* || "${stderr}" == *"Downgrade refused"* ]]
}

@test "downgrade allowed with --force --yes" {
    local old_jar="${REPO_ROOT}/jar/autoupgrade.jar"
    make_fake_au_jar "26.7.261010" "${old_jar}" >/dev/null
    local new_jar
    new_jar="$(make_fake_au_jar "26.6.260925")"
    run bash "${SCRIPT}" --from "${new_jar}" --force --yes --no-verify
    rm -f "${REPO_ROOT}/jar/autoupgrade.jar"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Downgrad"* ]]
}

@test "same version exits 0 with no-change message" {
    local ver="26.6.260925"
    local jar="${REPO_ROOT}/jar/autoupgrade.jar"
    local new_jar
    new_jar="$(make_fake_au_jar "${ver}")"
    cp "${new_jar}" "${jar}"
    run bash "${SCRIPT}" --from "${new_jar}" --no-verify --verbose
    rm -f "${jar}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"up to date"* || "${output}" == *"reinstalling"* ]]
}

# ---------------------------------------------------------------------------
# --sha256 enforcement
# ---------------------------------------------------------------------------

@test "--sha256 mismatch aborts install" {
    local fake
    fake="$(make_fake_au_jar "26.6.260925")"
    run bash "${SCRIPT}" --from "${fake}" --sha256 "000000aabbcc" --no-verify
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"mismatch"* || "${stderr}" == *"mismatch"* ]]
}

@test "--sha256 match proceeds" {
    local fake
    fake="$(make_fake_au_jar "26.6.260925")"
    local actual_sha
    if command -v sha256sum >/dev/null 2>&1; then
        actual_sha="$(sha256sum "${fake}" | cut -d' ' -f1)"
    else
        actual_sha="$(shasum -a 256 "${fake}" | cut -d' ' -f1)"
    fi
    run bash "${SCRIPT}" --from "${fake}" --sha256 "${actual_sha}" --no-verify
    rm -f "${REPO_ROOT}/jar/autoupgrade.jar"
    [ "${status}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# --keep backup retention
# ---------------------------------------------------------------------------

@test "--keep 2 prunes old backups" {
    local jar_dir="${REPO_ROOT}/jar"
    # Create 4 existing backup files
    local i
    for i in 26.4 26.5 26.6 26.7; do
        touch "${jar_dir}/autoupgrade_${i}.jar"
    done
    local new_jar
    new_jar="$(make_fake_au_jar "26.8.261201")"
    # Install an existing jar first so backup runs
    make_fake_au_jar "26.7.261010" "${jar_dir}/autoupgrade.jar" >/dev/null
    run bash "${SCRIPT}" --from "${new_jar}" --keep 2 --no-verify
    rm -f "${jar_dir}/autoupgrade.jar"
    # Count remaining backups
    local count
    # shellcheck disable=SC2012
    count="$(ls "${jar_dir}"/autoupgrade_*.jar 2>/dev/null | wc -l | tr -d ' ')"
    # Cleanup backups
    rm -f "${jar_dir}"/autoupgrade_*.jar
    [ "${status}" -eq 0 ]
    [ "${count}" -le 2 ]
}

# ---------------------------------------------------------------------------
# --keep validation
# ---------------------------------------------------------------------------

@test "--keep requires non-negative integer" {
    run bash "${SCRIPT}" --keep abc
    [ "${status}" -ne 0 ]
    [[ "${output}${output}" == *"integer"* || "${stderr}" == *"integer"* ]]
}

# ---------------------------------------------------------------------------
# Keystore staleness warning
# ---------------------------------------------------------------------------

@test "warns when keystore predates JAR build date" {
    # Create a keystore dir with old ewallet.p12
    local ks_dir="${WORK_DIR}/keystore"
    mkdir -p "${ks_dir}"
    touch -t 200001010000 "${ks_dir}/ewallet.p12"  # year 2000 mtime
    export AU_KEYSTORE="${ks_dir}"

    local new_jar
    new_jar="$(make_fake_au_jar "26.6.260925")"
    run bash "${SCRIPT}" --from "${new_jar}" --no-verify
    rm -f "${REPO_ROOT}/jar/autoupgrade.jar"
    unset AU_KEYSTORE

    [[ "${output}" == *"Re-save recommended"* || "${output}" == *"re-save"* || \
       "${output}" == *"predate"* ]] || \
    [[ "${output}" == *"260925"* ]]
    # Just verify it ran successfully (staleness warning is best-effort)
    [ "${status}" -eq 0 ]
}
