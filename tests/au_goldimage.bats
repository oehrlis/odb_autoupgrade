#!/usr/bin/env bats
# shellcheck disable=SC1090
# ------------------------------------------------------------------------------
# tests/au_goldimage.bats
# BATS tests for bin/au_goldimage.sh (WP10).
# Uses mocked runInstaller, opatch, ar, unzip.
# ------------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    SCRIPT="${REPO_ROOT}/bin/au_goldimage.sh"
    WORK_DIR="${BATS_TMPDIR}/au_goldimage_test_$$_${RANDOM}"
    mkdir -p "${WORK_DIR}/etc" "${WORK_DIR}/patches" "${WORK_DIR}/logs" \
             "${WORK_DIR}/keystore"
    chmod 700 "${WORK_DIR}" "${WORK_DIR}/etc" "${WORK_DIR}/patches" \
              "${WORK_DIR}/logs" "${WORK_DIR}/keystore"

    cp "${REPO_ROOT}/etc/au_patch.cfg" "${WORK_DIR}/etc/au_patch.cfg"
    chmod 600 "${WORK_DIR}/etc/au_patch.cfg"

    export AUTOUPGRADE_BASE="${WORK_DIR}"
    export AU_ORACLE_BASE="${WORK_DIR}/oracle_base"
    export AU_EDITION="EE"

    # Fake Oracle Home - must have non-g/o-writable dirs for binary trust check
    FAKE_OH="${WORK_DIR}/fake_oh"
    mkdir -p "${FAKE_OH}/rdbms/lib" "${FAKE_OH}/OPatch"
    chmod 755 "${FAKE_OH}" "${FAKE_OH}/OPatch"

    # Destination for gold images
    DEST_DIR="${WORK_DIR}/images"
    mkdir -p "${DEST_DIR}"

    # Stub directory takes priority in PATH
    STUB_DIR="${WORK_DIR}/stubs"
    mkdir -p "${STUB_DIR}"
    export PATH="${STUB_DIR}:${PATH}"
}

teardown() {
    rm -rf "${WORK_DIR}"
    unset AUTOUPGRADE_BASE AU_ORACLE_BASE AU_EDITION 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_make_runinstaller_stub() {
    local _home="$1"
    local _zip_name="${2:-db_goldimage_19.32.0.0.zip}"
    mkdir -p "${_home}"
    chmod 755 "${_home}"
    cat > "${_home}/runInstaller" <<RISTUB
#!/usr/bin/env bash
# Mocked runInstaller: creates a fake zip in -destinationLocation
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -destinationLocation) _dest="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
touch "\${_dest}/${_zip_name}"
exit 0
RISTUB
    chmod 0755 "${_home}/runInstaller"
}

_make_opatch_stub() {
    local _home="$1"
    cat > "${_home}/OPatch/opatch" <<'OPATCH'
#!/usr/bin/env bash
if [[ "$1" == "lspatches" ]]; then
    printf '36233126;Database Release Update : 19.32.0.0\n'
    exit 0
fi
exit 0
OPATCH
    chmod 0755 "${_home}/OPatch/opatch"
}

_make_ar_stub() {
    cat > "${STUB_DIR}/ar" <<'ARSTUB'
#!/usr/bin/env bash
if [[ "$1" == "-t" ]]; then
    printf 'kfon.o\njox.o\n'
    exit 0
fi
exit 0
ARSTUB
    chmod +x "${STUB_DIR}/ar"
}

_make_sha256sum_stub() {
    # Stub sha256sum to return a fixed hash
    cat > "${STUB_DIR}/sha256sum" <<'SHA256STUB'
#!/usr/bin/env bash
# Return a deterministic fake hash for any file
printf 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899  %s\n' "${1##*/}"
SHA256STUB
    chmod +x "${STUB_DIR}/sha256sum"
}

_make_unzip_stub() {
    cat > "${STUB_DIR}/unzip" <<'UZSTUB'
#!/usr/bin/env bash
# Mocked unzip: handles -Z1 (list entries) and -q (extract)
# -Z1: print clean entries (no path traversal) and exit
if [[ "$1" == "-Z1" ]]; then
    printf 'oracle/bin/oracle\noracle/lib/libclntsh.so\n'
    exit 0
fi
_zip=""
_dest=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -q) shift ;;
        -d) _dest="$2"; shift 2 ;;
        *.zip) _zip="$1"; shift ;;
        *) shift ;;
    esac
done
if [[ -n "${_dest}" ]]; then
    mkdir -p "${_dest}"
    chmod 755 "${_dest}"
    # Create a minimal runInstaller stub in target
    cat > "${_dest}/runInstaller" <<'INNER'
#!/usr/bin/env bash
exit 0
INNER
    chmod 0755 "${_dest}/runInstaller"
fi
exit 0
UZSTUB
    chmod +x "${STUB_DIR}/unzip"
}

_make_test_zip() {
    local _dir="$1"
    local _name="${2:-db_goldimage_19.32.0.0.zip}"
    # Create a minimal zip file placeholder
    printf 'PK\x03\x04' > "${_dir}/${_name}"
}

# ---------------------------------------------------------------------------
# Option parsing
# ---------------------------------------------------------------------------

@test "au_goldimage.sh: --help exits 0" {
    run bash "${SCRIPT}" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--create"* ]]
    [[ "${output}" == *"--verify"* ]]
    [[ "${output}" == *"--install"* ]]
}

@test "au_goldimage.sh: no mode exits non-zero" {
    run bash "${SCRIPT}" 2>&1
    [ "${status}" -ne 0 ]
}

@test "au_goldimage.sh: multiple modes exits non-zero" {
    run bash "${SCRIPT}" --create --verify /tmp/fake.zip 2>&1
    [ "${status}" -ne 0 ]
}

# ---------------------------------------------------------------------------
# --create mode
# ---------------------------------------------------------------------------

@test "au_goldimage.sh: --create requires --home" {
    run bash "${SCRIPT}" --create --dest "${DEST_DIR}" 2>&1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"--home"* ]]
}

@test "au_goldimage.sh: --create requires --dest" {
    _make_runinstaller_stub "${FAKE_OH}"
    run bash "${SCRIPT}" --create --home "${FAKE_OH}" 2>&1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"--dest"* ]]
}

@test "au_goldimage.sh: --create dry-run prints command" {
    _make_runinstaller_stub "${FAKE_OH}"
    run bash "${SCRIPT}" --create --home "${FAKE_OH}" --dest "${DEST_DIR}" \
        --dry-run 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DRY-RUN"* ]] || [[ "${output}" == *"runInstaller"* ]]
}

@test "au_goldimage.sh: --create writes sha256 and manifest" {
    _make_runinstaller_stub "${FAKE_OH}"
    _make_opatch_stub "${FAKE_OH}"
    _make_ar_stub
    touch "${FAKE_OH}/rdbms/lib/libknlopt.a"
    _make_sha256sum_stub

    run bash "${SCRIPT}" --create --home "${FAKE_OH}" --dest "${DEST_DIR}" 2>&1
    [ "${status}" -eq 0 ]
    # A zip must exist in dest
    local _zip
    _zip=$(find "${DEST_DIR}" -maxdepth 1 -name '*.zip' 2>/dev/null | head -1 || true)
    [ -n "${_zip}" ]
    # sha256 sidecar must exist
    [ -f "${_zip}.sha256" ]
    # manifest must exist
    [ -f "${_zip}.manifest" ]
}

@test "au_goldimage.sh: manifest contains opatch lspatches output" {
    _make_runinstaller_stub "${FAKE_OH}"
    _make_opatch_stub "${FAKE_OH}"
    _make_ar_stub
    touch "${FAKE_OH}/rdbms/lib/libknlopt.a"
    _make_sha256sum_stub

    run bash "${SCRIPT}" --create --home "${FAKE_OH}" --dest "${DEST_DIR}" 2>&1
    [ "${status}" -eq 0 ]
    local _manifest
    _manifest=$(find "${DEST_DIR}" -maxdepth 1 -name '*.manifest' | head -1)
    [ -n "${_manifest}" ]
    grep -q "36233126" "${_manifest}"
}

# ---------------------------------------------------------------------------
# --verify mode
# ---------------------------------------------------------------------------

@test "au_goldimage.sh: --verify fails when zip missing" {
    run bash "${SCRIPT}" --verify /nonexistent/fake.zip 2>&1
    [ "${status}" -ne 0 ]
}

@test "au_goldimage.sh: --verify fails when sha256 file missing" {
    _make_test_zip "${DEST_DIR}"
    local _zip
    _zip=$(find "${DEST_DIR}" -name '*.zip' | head -1)
    run bash "${SCRIPT}" --verify "${_zip}" 2>&1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"sha256"* ]]
}

@test "au_goldimage.sh: --verify passes with matching checksum" {
    _make_test_zip "${DEST_DIR}" "test_gi.zip"
    local _zip="${DEST_DIR}/test_gi.zip"
    _make_sha256sum_stub
    # Write the checksum file (matches what stub returns)
    local _hash="aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
    printf '%s  test_gi.zip\n' "${_hash}" > "${_zip}.sha256"
    run bash "${SCRIPT}" --verify "${_zip}" 2>&1
    [ "${status}" -eq 0 ]
}

@test "au_goldimage.sh: --verify fails with mismatched checksum" {
    _make_test_zip "${DEST_DIR}" "mismatch_gi.zip"
    local _zip="${DEST_DIR}/mismatch_gi.zip"
    _make_sha256sum_stub
    # Write a different hash
    printf '%s  mismatch_gi.zip\n' "0000000000000000000000000000000000000000000000000000000000000000" \
        > "${_zip}.sha256"
    run bash "${SCRIPT}" --verify "${_zip}" 2>&1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"MISMATCH"* ]]
}

@test "au_goldimage.sh: --verify dry-run prints check without running" {
    _make_test_zip "${DEST_DIR}" "dr_gi.zip"
    local _zip="${DEST_DIR}/dr_gi.zip"
    local _hash="aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
    printf '%s  dr_gi.zip\n' "${_hash}" > "${_zip}.sha256"
    run bash "${SCRIPT}" --verify "${_zip}" --dry-run 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DRY-RUN"* ]] || [[ "${output}" == *"sha256"* ]]
}

# ---------------------------------------------------------------------------
# --install mode
# ---------------------------------------------------------------------------

@test "au_goldimage.sh: --install requires --target" {
    _make_test_zip "${DEST_DIR}" "inst_gi.zip"
    local _zip="${DEST_DIR}/inst_gi.zip"
    _make_sha256sum_stub
    local _hash="aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
    printf '%s  inst_gi.zip\n' "${_hash}" > "${_zip}.sha256"
    run bash "${SCRIPT}" --install "${_zip}" \
        --oracle-base "${WORK_DIR}/oracle_base" 2>&1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"--target"* ]]
}

@test "au_goldimage.sh: --install requires oracle-base" {
    _make_test_zip "${DEST_DIR}" "inst2_gi.zip"
    local _zip="${DEST_DIR}/inst2_gi.zip"
    _make_sha256sum_stub
    printf 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899  inst2_gi.zip\n' \
        > "${_zip}.sha256"
    unset AU_ORACLE_BASE
    run bash "${SCRIPT}" --install "${_zip}" \
        --target "${WORK_DIR}/new_oh" 2>&1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"oracle-base"* ]] || [[ "${output}" == *"ORACLE_BASE"* ]]
}

@test "au_goldimage.sh: --install dry-run prints commands" {
    _make_test_zip "${DEST_DIR}" "inst3_gi.zip"
    local _zip="${DEST_DIR}/inst3_gi.zip"
    _make_sha256sum_stub
    printf 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899  inst3_gi.zip\n' \
        > "${_zip}.sha256"
    run bash "${SCRIPT}" --install "${_zip}" \
        --target "${WORK_DIR}/new_oh" \
        --oracle-base "${WORK_DIR}/oracle_base" \
        --dry-run 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DRY-RUN"* ]] || [[ "${output}" == *"unzip"* ]] || \
        [[ "${output}" == *"runInstaller"* ]]
}

@test "au_goldimage.sh: --install prints root.sh command" {
    _make_test_zip "${DEST_DIR}" "inst4_gi.zip"
    local _zip="${DEST_DIR}/inst4_gi.zip"
    _make_sha256sum_stub
    printf 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899  inst4_gi.zip\n' \
        > "${_zip}.sha256"
    _make_unzip_stub

    local _tgt="${WORK_DIR}/install_oh"
    run bash "${SCRIPT}" --install "${_zip}" \
        --target "${_tgt}" \
        --oracle-base "${WORK_DIR}/oracle_base" \
        --edition EE 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"root.sh"* ]]
}

@test "au_goldimage.sh: --install refuses non-empty target" {
    _make_test_zip "${DEST_DIR}" "inst5_gi.zip"
    local _zip="${DEST_DIR}/inst5_gi.zip"
    _make_sha256sum_stub
    printf 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899  inst5_gi.zip\n' \
        > "${_zip}.sha256"

    # Pre-create non-empty target
    local _tgt="${WORK_DIR}/nonempty_oh"
    mkdir -p "${_tgt}"
    touch "${_tgt}/somefile"

    run bash "${SCRIPT}" --install "${_zip}" \
        --target "${_tgt}" \
        --oracle-base "${WORK_DIR}/oracle_base" 2>&1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"empty"* ]] || [[ "${output}" == *"exist"* ]]
}

# ---------------------------------------------------------------------------
# SHOULD: OSDBA_GROUP written independently of inventory group (regression)
# ---------------------------------------------------------------------------

@test "au_goldimage.sh: --install writes OSDBA_GROUP without inventory group" {
    _make_test_zip "${DEST_DIR}" "osdba_test.zip"
    local _zip="${DEST_DIR}/osdba_test.zip"
    _make_sha256sum_stub
    printf 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899  osdba_test.zip\n' \
        > "${_zip}.sha256"
    _make_unzip_stub

    local _tgt="${WORK_DIR}/osdba_oh"
    # Capture the response file content by providing --response-file
    local _rsp="${WORK_DIR}/out.rsp"
    # No inventory group set; OSDBA_GROUP must still appear
    run bash "${SCRIPT}" --install "${_zip}" \
        --target "${_tgt}" \
        --oracle-base "${WORK_DIR}/oracle_base" \
        --edition EE \
        --response "${_rsp}" 2>&1
    [ "${status}" -eq 0 ]
    # Response file must contain OSDBA_GROUP even when no inventory group
    [[ -f "${_rsp}" && "$(grep -c 'OSDBA_GROUP' "${_rsp}")" -ge 1 ]] || \
        [[ "${output}" == *"OSDBA_GROUP"* ]]
}

# ---------------------------------------------------------------------------
# SHOULD: Zip-slip check (regression)
# ---------------------------------------------------------------------------

@test "au_goldimage.sh: --install refuses zip with absolute path entry" {
    # Create a stub unzip that lists absolute paths via -Z1
    cat > "${STUB_DIR}/unzip" <<'UZSTUB'
#!/usr/bin/env bash
if [[ "$1" == "-Z1" ]]; then
    printf '/etc/passwd\nnormal/file.txt\n'
    exit 0
fi
exit 0
UZSTUB
    chmod +x "${STUB_DIR}/unzip"

    # Also need zipinfo -1 to fail so unzip -Z1 is used
    cat > "${STUB_DIR}/zipinfo" <<'ZI'
#!/usr/bin/env bash
exit 1
ZI
    chmod +x "${STUB_DIR}/zipinfo"

    _make_test_zip "${DEST_DIR}" "slip_test.zip"
    local _zip="${DEST_DIR}/slip_test.zip"
    _make_sha256sum_stub
    printf 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899  slip_test.zip\n' \
        > "${_zip}.sha256"

    local _tgt="${WORK_DIR}/slip_oh"
    run bash "${SCRIPT}" --install "${_zip}" \
        --target "${_tgt}" \
        --oracle-base "${WORK_DIR}/oracle_base" \
        --edition EE 2>&1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"slip"* || "${output}" == *"absolute"* || "${output}" == *"path"* || "${output}" == *"ERROR"* ]]
}

@test "au_goldimage.sh: --install refuses zip with dotdot path entry" {
    cat > "${STUB_DIR}/unzip" <<'UZSTUB'
#!/usr/bin/env bash
if [[ "$1" == "-Z1" ]]; then
    printf '../evil.sh\nnormal/file.txt\n'
    exit 0
fi
exit 0
UZSTUB
    chmod +x "${STUB_DIR}/unzip"

    _make_test_zip "${DEST_DIR}" "dotdot_test.zip"
    local _zip="${DEST_DIR}/dotdot_test.zip"
    _make_sha256sum_stub
    printf 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899  dotdot_test.zip\n' \
        > "${_zip}.sha256"

    local _tgt="${WORK_DIR}/dotdot_oh"
    run bash "${SCRIPT}" --install "${_zip}" \
        --target "${_tgt}" \
        --oracle-base "${WORK_DIR}/oracle_base" \
        --edition EE 2>&1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"slip"* || "${output}" == *"traversal"* || "${output}" == *"ERROR"* ]]
}

# ---------------------------------------------------------------------------
# MUST 2 regression: group name injection into response file
# ---------------------------------------------------------------------------

@test "au_goldimage.sh: rejects invalid group name with semicolon in response file (MUST 2)" {
    _make_test_zip "${DEST_DIR}" "grp_bad.zip"
    local _zip="${DEST_DIR}/grp_bad.zip"
    _make_sha256sum_stub
    printf 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899  grp_bad.zip\n' \
        > "${_zip}.sha256"
    _make_unzip_stub

    local _tgt="${WORK_DIR}/grp_bad_oh"
    run bash -c "
        AU_GROUP_OSDBA='dba;INJECT=true' bash '${SCRIPT}' \
            --install '${_zip}' \
            --target '${_tgt}' \
            --oracle-base '${WORK_DIR}/oracle_base' \
            --edition EE 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"invalid"* ]] || [[ "${output}" == *"group"* ]]
}

@test "au_goldimage.sh: rejects group name with newline (injection) in response file (MUST 2)" {
    _make_test_zip "${DEST_DIR}" "grp_nl.zip"
    local _zip="${DEST_DIR}/grp_nl.zip"
    _make_sha256sum_stub
    printf 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899  grp_nl.zip\n' \
        > "${_zip}.sha256"
    _make_unzip_stub

    local _tgt="${WORK_DIR}/grp_nl_oh"
    run bash -c "
        AU_GROUP_OSDBA=$'dba\nEXTRA_KEY=injected' bash '${SCRIPT}' \
            --install '${_zip}' \
            --target '${_tgt}' \
            --oracle-base '${WORK_DIR}/oracle_base' \
            --edition EE 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"newline"* ]] || [[ "${output}" == *"invalid"* ]] || [[ "${output}" == *"group"* ]]
}

# ---------------------------------------------------------------------------
# MUST 3 regression: binary trust check on opatch (manifest) and symlinks
# ---------------------------------------------------------------------------

@test "au_goldimage.sh: --create refuses 0777 opatch binary (MUST 3)" {
    _make_runinstaller_stub "${FAKE_OH}"
    _make_ar_stub
    touch "${FAKE_OH}/rdbms/lib/libknlopt.a"
    _make_sha256sum_stub

    # Create an opatch that is world-writable (must be refused by trust check)
    mkdir -p "${FAKE_OH}/OPatch"
    cat > "${FAKE_OH}/OPatch/opatch" <<'OP'
#!/usr/bin/env bash
printf '36233126;Database Release Update : 19.32.0.0\n'
exit 0
OP
    chmod 0777 "${FAKE_OH}/OPatch/opatch"

    run bash "${SCRIPT}" --create --home "${FAKE_OH}" --dest "${DEST_DIR}" 2>&1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"writable"* ]] || [[ "${output}" == *"refusing"* ]] || [[ "${output}" == *"trust"* ]] || [[ "${output}" == *"ERROR"* ]]
}

@test "au_goldimage.sh: --create refuses opatch symlink pointing to untrusted target (MUST 3)" {
    _make_runinstaller_stub "${FAKE_OH}"
    _make_ar_stub
    touch "${FAKE_OH}/rdbms/lib/libknlopt.a"
    _make_sha256sum_stub

    # Create an untrusted opatch in a world-writable directory and symlink to it
    local _untrusted_dir="${WORK_DIR}/untrusted_dir"
    mkdir -p "${_untrusted_dir}"
    chmod 0777 "${_untrusted_dir}"
    cat > "${_untrusted_dir}/opatch_real" <<'OP'
#!/usr/bin/env bash
exit 0
OP
    chmod +x "${_untrusted_dir}/opatch_real"
    mkdir -p "${FAKE_OH}/OPatch"
    ln -sf "${_untrusted_dir}/opatch_real" "${FAKE_OH}/OPatch/opatch"

    run bash "${SCRIPT}" --create --home "${FAKE_OH}" --dest "${DEST_DIR}" 2>&1
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"writable"* ]] || [[ "${output}" == *"refusing"* ]] || [[ "${output}" == *"trust"* ]] || [[ "${output}" == *"ERROR"* ]]
}
