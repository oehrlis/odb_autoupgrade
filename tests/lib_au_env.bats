#!/usr/bin/env bats
# shellcheck disable=SC1090
# ------------------------------------------------------------------------------
# tests/lib_au_env.bats
# BATS tests for lib/au_env.sh - WP2 (au_load_config) and WP14 (au_render_cfg,
# au_check_cfg_mode).
# ------------------------------------------------------------------------------

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    LIB="${REPO_ROOT}/lib/au_lib.sh"
    WORK_DIR="${BATS_TMPDIR}/au_env_test_$$_${RANDOM}"
    mkdir -p "${WORK_DIR}/etc" "${WORK_DIR}/patches" "${WORK_DIR}/logs" \
             "${WORK_DIR}/keystore"
    # Ensure directories are not group/world-writable (security check compliance)
    chmod 700 "${WORK_DIR}" "${WORK_DIR}/etc" "${WORK_DIR}/patches" \
              "${WORK_DIR}/logs" "${WORK_DIR}/keystore"
    export AUTOUPGRADE_BASE="${WORK_DIR}"
}

teardown() {
    rm -rf "${WORK_DIR}"
    unset AUTOUPGRADE_BASE ORADBA_CONFIG_DIR ORADBA_ETC AUTOUPGRADE_ENV_FILE \
          AU_TARGET_VERSION AU_PLATFORM AU_PATCH AU_GOLD_IMAGE \
          AU_LOG_DIR AU_KEYSTORE AU_DOWNLOAD_FOLDER \
          AU_SOURCE_HOME AU_TARGET_HOME AU_SID 2>/dev/null || true
}

# =============================================================================
# WP2: au_load_config
# =============================================================================

@test "au_load_config: applies built-in defaults" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_load_config 2>/dev/null
        echo \"TV=\${AU_TARGET_VERSION}\"
        echo \"PL=\${AU_PLATFORM}\"
        echo \"PA=\${AU_PATCH}\"
        echo \"GI=\${AU_GOLD_IMAGE}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"TV=19"* ]]
    [[ "${output}" == *"PL=LINUX.X64"* ]]
    [[ "${output}" == *"PA=RECOMMENDED"* ]]
    [[ "${output}" == *"GI=NO"* ]]
}

@test "au_load_config: caller environment wins over level-5 env file" {
    printf 'AU_TARGET_VERSION=21\n' > "${WORK_DIR}/etc/autoupgrade.env"
    chmod 600 "${WORK_DIR}/etc/autoupgrade.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_TARGET_VERSION=19
        source '${LIB}'
        au_load_config 2>/dev/null
        echo \"TV=\${AU_TARGET_VERSION}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"TV=19"* ]]
}

@test "au_load_config: level-5 env file sets variables not set by caller" {
    printf 'AU_TARGET_VERSION=21\n' > "${WORK_DIR}/etc/autoupgrade.env"
    chmod 600 "${WORK_DIR}/etc/autoupgrade.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_load_config 2>/dev/null
        echo \"TV=\${AU_TARGET_VERSION}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"TV=21"* ]]
}

@test "au_load_config: AUTOUPGRADE_ENV_FILE missing is fatal" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AUTOUPGRADE_ENV_FILE='/nonexistent/no.env'
        source '${LIB}'
        au_load_config 2>/dev/null
    "
    [ "${status}" -ne 0 ]
}

@test "au_load_config: level-3 AUTOUPGRADE_ENV_FILE loaded and caller wins" {
    printf 'AU_PLATFORM=LINUX.AARCH64\n' > "${WORK_DIR}/custom.env"
    chmod 600 "${WORK_DIR}/custom.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AUTOUPGRADE_ENV_FILE='${WORK_DIR}/custom.env'
        source '${LIB}'
        au_load_config 2>/dev/null
        echo \"PL=\${AU_PLATFORM}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PL=LINUX.AARCH64"* ]]
}

@test "au_load_config: pin file sets AU_PATCH when not pre-set" {
    printf 'AU_PATCH=RU19.30\n' > "${WORK_DIR}/patches/au_patch.env"
    chmod 600 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_load_config 2>/dev/null
        echo \"PA=\${AU_PATCH}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PA=RU19.30"* ]]
}

@test "au_load_config: caller AU_PATCH wins over pin file" {
    printf 'AU_PATCH=RU19.28\n' > "${WORK_DIR}/patches/au_patch.env"
    chmod 600 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH=RU19.99
        source '${LIB}'
        au_load_config 2>/dev/null
        echo \"PA=\${AU_PATCH}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PA=RU19.99"* ]]
    [[ "${output}" != *"RU19.28"* ]]
}

@test "au_load_config: ORADBA_CONFIG_DIR level-4 loaded" {
    mkdir -p "${WORK_DIR}/site"
    chmod 700 "${WORK_DIR}/site"
    printf 'AU_GOLD_IMAGE=YES\n' > "${WORK_DIR}/site/autoupgrade.env"
    chmod 600 "${WORK_DIR}/site/autoupgrade.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export ORADBA_CONFIG_DIR='${WORK_DIR}/site'
        source '${LIB}'
        au_load_config 2>/dev/null
        echo \"GI=\${AU_GOLD_IMAGE}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"GI=YES"* ]]
}

# =============================================================================
# WP2: Security checks in au_load_config (_au_check_file_security)
# =============================================================================

@test "au_load_config: g+w level-5 file is fatal" {
    printf 'AU_TARGET_VERSION=21\n' > "${WORK_DIR}/etc/autoupgrade.env"
    chmod 664 "${WORK_DIR}/etc/autoupgrade.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_load_config 2>&1
    "
    [ "${status}" -ne 0 ]
}

@test "au_load_config: o+w level-5 file is fatal" {
    printf 'AU_TARGET_VERSION=21\n' > "${WORK_DIR}/etc/autoupgrade.env"
    chmod 646 "${WORK_DIR}/etc/autoupgrade.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_load_config 2>&1
    "
    [ "${status}" -ne 0 ]
}

# =============================================================================
# WP14: au_render_cfg
# =============================================================================

@test "au_render_cfg: expands variables in config" {
    local cfg="${WORK_DIR}/test.cfg"
    local out="${WORK_DIR}/rendered.cfg"
    printf 'global.global_log_dir=${AU_LOG_DIR}\n' > "${cfg}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_LOG_DIR='${WORK_DIR}/logs'
        source '${LIB}'
        AU_CFG_VARS=(AU_LOG_DIR)
        au_render_cfg '${cfg}' '' '${out}'
        cat '${out}'
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"global.global_log_dir=${WORK_DIR}/logs"* ]]
}

@test "au_render_cfg: drops lines with empty value and names them" {
    local cfg="${WORK_DIR}/test.cfg"
    local out="${WORK_DIR}/rendered.cfg"
    printf 'patch1.source_home=${AU_SOURCE_HOME}\npatch1.patch=${AU_PATCH}\n' > "${cfg}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_SOURCE_HOME=''
        export AU_PATCH='RU19.28'
        source '${LIB}'
        AU_CFG_VARS=(AU_SOURCE_HOME AU_PATCH)
        au_render_cfg '${cfg}' '' '${out}' 2>&1
        echo '---'
        cat '${out}'
    "
    [ "${status}" -eq 0 ]
    # dropped key named in output
    [[ "${output}" == *"dropped"* ]]
    [[ "${output}" == *"patch1.source_home"* ]]
    # kept key present in rendered output
    [[ "${output}" == *"patch1.patch=RU19.28"* ]]
    # dropped line not in rendered output
    [[ "${output}" != *"patch1.source_home="* ]]
}

@test "au_render_cfg: global.keystore dropped for create_home mode" {
    local cfg="${WORK_DIR}/test.cfg"
    local out="${WORK_DIR}/rendered.cfg"
    printf 'global.global_log_dir=${AU_LOG_DIR}\nglobal.keystore=${AU_KEYSTORE}\n' > "${cfg}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_LOG_DIR='${WORK_DIR}/logs'
        export AU_KEYSTORE='${WORK_DIR}/keystore'
        source '${LIB}'
        AU_CFG_VARS=(AU_LOG_DIR AU_KEYSTORE)
        au_render_cfg '${cfg}' 'create_home' '${out}' 2>&1
        echo '---'
        cat '${out}'
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dropped"* ]]
    [[ "${output}" == *"global.keystore"* ]]
    [[ "${output}" != *"global.keystore=${WORK_DIR}/keystore"* ]]
}

@test "au_render_cfg: global.keystore kept for download mode" {
    local cfg="${WORK_DIR}/test.cfg"
    local out="${WORK_DIR}/rendered.cfg"
    printf 'global.keystore=${AU_KEYSTORE}\n' > "${cfg}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_KEYSTORE='${WORK_DIR}/keystore'
        source '${LIB}'
        AU_CFG_VARS=(AU_KEYSTORE)
        au_render_cfg '${cfg}' 'download' '${out}'
        cat '${out}'
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"global.keystore=${WORK_DIR}/keystore"* ]]
}

@test "au_render_cfg: injection guard rejects newline in variable" {
    local cfg="${WORK_DIR}/test.cfg"
    local out="${WORK_DIR}/rendered.cfg"
    printf 'patch1.sid=${AU_SID}\n' > "${cfg}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_SID=$'sid\ninjected'
        source '${LIB}'
        AU_CFG_VARS=(AU_SID)
        au_render_cfg '${cfg}' '' '${out}' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"injection"* || "${output}" == *"newline"* || "${output}" == *"carriage"* ]]
}

# =============================================================================
# WP14: au_check_cfg_mode
# =============================================================================

@test "au_check_cfg_mode: download passes when AU_PATCH is set" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PATCH='RECOMMENDED'
        source '${LIB}'
        au_check_cfg_mode 'download' 2>/dev/null
        echo 'ok'
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ok"* ]]
}

@test "au_check_cfg_mode: download fails when AU_PATCH unset" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        unset AU_PATCH
        source '${LIB}'
        au_check_cfg_mode 'download' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"AU_PATCH"* ]]
}

@test "au_check_cfg_mode: create_home fails when AU_TARGET_HOME unset" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        unset AU_TARGET_HOME
        source '${LIB}'
        au_check_cfg_mode 'create_home' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"AU_TARGET_HOME"* ]]
}

@test "au_check_cfg_mode: deploy fails when AU_SID unset" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_SOURCE_HOME='/fake'
        export AU_TARGET_HOME='/fake2'
        unset AU_SID
        source '${LIB}'
        au_check_cfg_mode 'deploy' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"AU_SID"* ]]
}

@test "au_check_cfg_mode: analyze mode passes without any AU_ vars" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_check_cfg_mode 'analyze' 2>/dev/null
        echo 'ok'
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ok"* ]]
}

@test "au_check_cfg_mode: empty mode passes (other modes no check)" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_check_cfg_mode '' 2>/dev/null
        echo 'ok'
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ok"* ]]
}

# =============================================================================
# Backward compat: au_source_env_file (0.5.0 behavior)
# =============================================================================

@test "au_source_env_file: symlink to safe file is resolved and sourced (S2 Decision-5)" {
    # S2: au_source_env_file uses Decision-5; symlinks resolved (not refused).
    local real_env="${WORK_DIR}/real.env"
    local link_env="${WORK_DIR}/link.env"
    printf 'AU_PATCH=RU19.28\n' > "${real_env}"
    chmod 600 "${real_env}"
    ln -s "${real_env}" "${link_env}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        unset AU_PATCH
        source '${LIB}'
        au_source_env_file '${link_env}' 2>/dev/null
        echo \"PA=\${AU_PATCH}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PA=RU19.28"* ]]
}

@test "au_source_env_file: g+w file is refused with ERROR" {
    local env_file="${WORK_DIR}/grp.env"
    printf 'AU_PATCH=RU19.28\n' > "${env_file}"
    chmod 664 "${env_file}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_source_env_file '${env_file}' 2>&1
    "
    [ "${status}" -ne 0 ]
}

# =============================================================================
# Pin file (au_read_pin)
# =============================================================================

@test "au_read_pin: valid AU_PATCH accepted" {
    printf 'AU_PATCH=RU19.28,OJVM\n' > "${WORK_DIR}/patches/au_patch.env"
    chmod 600 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_DOWNLOAD_FOLDER='${WORK_DIR}/patches'
        source '${LIB}'
        au_read_pin 2>/dev/null
        echo \"PA=\${AU_PATCH}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PA=RU19.28,OJVM"* ]]
}

@test "au_read_pin: symlink pin file is skipped with WARN" {
    local real_pin="${WORK_DIR}/real_pin.env"
    local link_pin="${WORK_DIR}/patches/au_patch.env"
    printf 'AU_PATCH=RU19.28\n' > "${real_pin}"
    ln -s "${real_pin}" "${link_pin}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_DOWNLOAD_FOLDER='${WORK_DIR}/patches'
        source '${LIB}'
        au_read_pin 2>&1
        echo \"PA=\${AU_PATCH:-UNSET}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"symlink"* ]]
    [[ "${output}" == *"PA=UNSET"* ]]
}

@test "au_read_pin: invalid characters in value warn and skip" {
    printf 'AU_PATCH=RU19.28;echo evil\n' > "${WORK_DIR}/patches/au_patch.env"
    chmod 600 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_DOWNLOAD_FOLDER='${WORK_DIR}/patches'
        source '${LIB}'
        au_read_pin 2>&1
        echo \"PA=\${AU_PATCH:-UNSET}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"invalid characters"* ]]
    [[ "${output}" == *"PA=UNSET"* ]]
}

@test "au_read_pin: unknown lines in pin file warn and are ignored" {
    printf 'UNKNOWN_VAR=foo\nAU_PATCH=RU19.28\n' > "${WORK_DIR}/patches/au_patch.env"
    chmod 600 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_DOWNLOAD_FOLDER='${WORK_DIR}/patches'
        source '${LIB}'
        au_read_pin 2>&1
        echo \"PA=\${AU_PATCH}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ignored"* ]]
    [[ "${output}" == *"PA=RU19.28"* ]]
}

# =============================================================================
# M1: _au_check_file_security - directory permission checks
# =============================================================================

@test "M1: 600 file in 777 dir -> refused (no sticky)" {
    local unsafe_dir="${WORK_DIR}/unsafe_dir"
    mkdir -p "${unsafe_dir}"
    chmod 777 "${unsafe_dir}"
    printf 'AU_PATCH=RU19.28\n' > "${unsafe_dir}/test.env"
    chmod 600 "${unsafe_dir}/test.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_source_env_file '${unsafe_dir}/test.env' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"group/world-writable"* || "${output}" == *"refusing"* ]]
}

@test "M1: symlink in 777 dir -> refused (original path unsafe)" {
    local unsafe_dir="${WORK_DIR}/unsafe_link_dir"
    local safe_dir="${WORK_DIR}/safe_dir"
    mkdir -p "${unsafe_dir}" "${safe_dir}"
    chmod 777 "${unsafe_dir}"
    chmod 700 "${safe_dir}"
    printf 'AU_PATCH=RU19.28\n' > "${safe_dir}/real.env"
    chmod 600 "${safe_dir}/real.env"
    ln -s "${safe_dir}/real.env" "${unsafe_dir}/link.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_source_env_file '${unsafe_dir}/link.env' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"refusing"* || "${output}" == *"writable"* ]]
}

@test "M1: chain of two symlinks to safe file in safe dirs -> ok, target sourced" {
    local dir_a="${WORK_DIR}/dir_a"
    local dir_b="${WORK_DIR}/dir_b"
    local dir_c="${WORK_DIR}/dir_c"
    mkdir -p "${dir_a}" "${dir_b}" "${dir_c}"
    chmod 700 "${dir_a}" "${dir_b}" "${dir_c}"
    printf 'AU_PLATFORM=LINUX.AARCH64\n' > "${dir_c}/real.env"
    chmod 600 "${dir_c}/real.env"
    ln -s "${dir_c}/real.env" "${dir_b}/link2.env"
    ln -s "${dir_b}/link2.env" "${dir_a}/link1.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        unset AU_PLATFORM
        source '${LIB}'
        au_source_env_file '${dir_a}/link1.env' 2>/dev/null
        echo \"PL=\${AU_PLATFORM}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PL=LINUX.AARCH64"* ]]
}

@test "M1: sticky dir owned by root (BATS_TMPDIR) -> ok" {
    # BATS_TMPDIR is typically /tmp which is sticky and owned by root
    # Only run if BATS_TMPDIR has sticky bit set
    local _sticky
    _sticky=$(find "${BATS_TMPDIR}" -maxdepth 0 -perm -1000 2>/dev/null || true)
    if [[ -z "${_sticky}" ]]; then
        skip "BATS_TMPDIR (${BATS_TMPDIR}) does not have sticky bit - skip"
    fi
    local _dir="${BATS_TMPDIR}/au_m1_sticky_$$"
    mkdir -p "${_dir}"
    chmod 700 "${_dir}"
    printf 'AU_PLATFORM=LINUX.X64\n' > "${_dir}/sticky.env"
    chmod 600 "${_dir}/sticky.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        unset AU_PLATFORM
        source '${LIB}'
        au_source_env_file '${_dir}/sticky.env' 2>/dev/null
        echo \"PL=\${AU_PLATFORM}\"
    "
    rm -rf "${_dir}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PL=LINUX.X64"* ]]
}

# =============================================================================
# M2: Numeric uid comparison; fail closed on empty stat/id output
# =============================================================================

@test "M2: stat returning empty uid -> refused (fail closed)" {
    local safe_dir="${WORK_DIR}/m2_safe"
    mkdir -p "${safe_dir}"
    chmod 700 "${safe_dir}"
    printf 'AU_PATCH=RU19.28\n' > "${safe_dir}/test.env"
    chmod 600 "${safe_dir}/test.env"
    # Fake a stat that returns nothing (simulated via PATH stub)
    local stub_dir="${WORK_DIR}/stubs"
    mkdir -p "${stub_dir}"
    cat > "${stub_dir}/stat" <<'STUBEOF'
#!/usr/bin/env bash
# Return nothing to simulate stat failure
exit 1
STUBEOF
    chmod +x "${stub_dir}/stat"
    run bash -c "
        export PATH='${stub_dir}:${PATH}'
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_source_env_file '${safe_dir}/test.env' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"stat failed"* || "${output}" == *"refusing"* ]]
}

@test "M2: id -u failure -> refused (fail closed)" {
    local safe_dir="${WORK_DIR}/m2_id_safe"
    mkdir -p "${safe_dir}"
    chmod 700 "${safe_dir}"
    printf 'AU_PATCH=RU19.28\n' > "${safe_dir}/test.env"
    chmod 600 "${safe_dir}/test.env"
    local stub_dir="${WORK_DIR}/id_stubs"
    mkdir -p "${stub_dir}"
    cat > "${stub_dir}/id" <<'STUBEOF'
#!/usr/bin/env bash
# Fail to simulate id -u failure
exit 1
STUBEOF
    chmod +x "${stub_dir}/id"
    run bash -c "
        export PATH='${stub_dir}:${PATH}'
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_source_env_file '${safe_dir}/test.env' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"id"*"failed"* || "${output}" == *"uid"* || "${output}" == *"refusing"* ]]
}

# =============================================================================
# M3: au_load_config: level-3/4 paths computed from caller snapshot
# =============================================================================

@test "M3: caller ORADBA_CONFIG_DIR wins; env file trying to redirect is ignored" {
    # Set up two site config dirs
    local site_a="${WORK_DIR}/site_a"
    local site_b="${WORK_DIR}/site_b"
    mkdir -p "${site_a}" "${site_b}"
    chmod 700 "${site_a}" "${site_b}"
    printf 'AU_GOLD_IMAGE=YES\n' > "${site_a}/autoupgrade.env"
    chmod 600 "${site_a}/autoupgrade.env"
    printf 'AU_GOLD_IMAGE=AUTO\n' > "${site_b}/autoupgrade.env"
    chmod 600 "${site_b}/autoupgrade.env"
    # Level-5 etc/autoupgrade.env tries to set ORADBA_CONFIG_DIR to site_b
    printf 'ORADBA_CONFIG_DIR=%s\n' "${site_b}" > "${WORK_DIR}/etc/autoupgrade.env"
    chmod 600 "${WORK_DIR}/etc/autoupgrade.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export ORADBA_CONFIG_DIR='${site_a}'
        source '${LIB}'
        au_load_config 2>/dev/null
        echo \"GI=\${AU_GOLD_IMAGE}\"
    "
    [ "${status}" -eq 0 ]
    # site_a (caller value) must win; site_b must never be loaded
    [[ "${output}" == *"GI=YES"* ]]
    [[ "${output}" != *"GI=AUTO"* ]]
}

@test "M3: caller AUTOUPGRADE_ENV_FILE wins; level-5 cannot redirect it" {
    local m3_dir="${WORK_DIR}/m3_envs"
    mkdir -p "${m3_dir}"
    chmod 700 "${m3_dir}"
    local custom_env="${m3_dir}/custom.env"
    local other_env="${m3_dir}/other.env"
    printf 'AU_PLATFORM=LINUX.AARCH64\n' > "${custom_env}"
    chmod 600 "${custom_env}"
    printf 'AU_PLATFORM=WIN64\n' > "${other_env}"
    chmod 600 "${other_env}"
    # Level-5 tries to redirect AUTOUPGRADE_ENV_FILE to other_env
    printf 'AUTOUPGRADE_ENV_FILE=%s\n' "${other_env}" > "${WORK_DIR}/etc/autoupgrade.env"
    chmod 600 "${WORK_DIR}/etc/autoupgrade.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AUTOUPGRADE_ENV_FILE='${custom_env}'
        source '${LIB}'
        au_load_config 2>/dev/null
        echo \"PL=\${AU_PLATFORM}\"
    "
    [ "${status}" -eq 0 ]
    # custom_env must be loaded (LINUX.AARCH64); other_env must never load
    [[ "${output}" == *"PL=LINUX.AARCH64"* ]]
    [[ "${output}" != *"PL=WIN64"* ]]
}

# =============================================================================
# S1: readonly restore - die if env file made caller var readonly with diff value
# =============================================================================

@test "S1: env file making caller var readonly with different value -> die" {
    local s1_dir="${WORK_DIR}/s1_test"
    mkdir -p "${s1_dir}"
    chmod 700 "${s1_dir}"
    local env_f="${s1_dir}/readonly_trap.env"
    printf 'readonly AU_PLATFORM=WIN64\n' > "${env_f}"
    chmod 600 "${env_f}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AUTOUPGRADE_ENV_FILE='${env_f}'
        export AU_PLATFORM='LINUX.X64'
        source '${LIB}'
        au_load_config 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"readonly"* ]]
}

# =============================================================================
# S3: au_render_cfg key whitespace trimming
# =============================================================================

@test "S3: au_render_cfg: key with surrounding whitespace is trimmed" {
    local cfg="${WORK_DIR}/s3_test.cfg"
    local out="${WORK_DIR}/s3_out.cfg"
    printf '  global.keystore  = ${AU_KEYSTORE}\n' > "${cfg}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_KEYSTORE='${WORK_DIR}/keystore'
        source '${LIB}'
        AU_CFG_VARS=(AU_KEYSTORE)
        au_render_cfg '${cfg}' 'download' '${out}'
        cat '${out}'
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"global.keystore=${WORK_DIR}/keystore"* ]]
}

# =============================================================================
# S4: au_render_cfg line without '=' -> die with line number
# =============================================================================

@test "S4: au_render_cfg: non-comment line without '=' -> die naming line number" {
    local cfg="${WORK_DIR}/s4_test.cfg"
    local out="${WORK_DIR}/s4_out.cfg"
    printf '# comment ok\npatch1.sid=foo\nbadline_no_equals\n' > "${cfg}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        AU_CFG_VARS=()
        au_render_cfg '${cfg}' '' '${out}' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no '='"* || "${output}" == *"separator"* ]]
    [[ "${output}" == *"3"* ]]
}

# =============================================================================
# S7: Guards on function existence cannot be bypassed via env var
# =============================================================================

@test "S7: common.sh guard on declare -F cannot be bypassed with env var" {
    run bash -c "
        # Pre-setting old guard var should NOT skip bash 4.2 check or log_info definition
        export COMMON_SH_LOADED=1
        source '${LIB}'
        declare -F log_info >/dev/null 2>&1 && echo 'log_info_defined'
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"log_info_defined"* ]]
}


# =============================================================================
# Fix 1: TOCTOU - sourcing uses /dev/fd (already-opened fd), not path
# =============================================================================

@test "Fix1: TOCTOU: _au_source_file loads content via /dev/fd (functional)" {
    local env_f="${WORK_DIR}/toctou_test.env"
    printf 'AU_GOLD_IMAGE=TOCTOU_OK\n' > "${env_f}"
    chmod 600 "${env_f}"
    # Functional: _au_source_file uses already-opened fd; content must be loaded
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        _au_source_file '${env_f}' 'test' 2>/dev/null
        echo \"GI=\${AU_GOLD_IMAGE:-UNSET}\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"GI=TOCTOU_OK"* ]]
}

# =============================================================================
# Fix 2: _au_check_parent_dir: non-sticky, non-writable dir owned by another uid
# =============================================================================

@test "Fix2: 755 dir owned by another uid -> refused" {
    # Use stat stub to simulate a dir owned by uid 9999
    local safe_dir="${WORK_DIR}/fix2_safe"
    mkdir -p "${safe_dir}"
    chmod 700 "${safe_dir}"
    local env_f="${safe_dir}/test.env"
    printf 'AU_GOLD_IMAGE=YES\n' > "${env_f}"
    chmod 600 "${env_f}"
    local stub_dir="${WORK_DIR}/fix2_stubs"
    mkdir -p "${stub_dir}"
    # Stub stat: returns 9999 for the directory uid, passes through for file
    cat > "${stub_dir}/stat" << STUBEOF
#!/usr/bin/env bash
# Return 9999 for directory uid checks, real uid for file checks
if [[ "\$*" == *"${safe_dir}"* && "\$*" != *"test.env"* ]]; then
    echo "9999"
else
    /usr/bin/stat "\$@"
fi
STUBEOF
    chmod +x "${stub_dir}/stat"
    run bash -c "
        export PATH='${stub_dir}:${PATH}'
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_source_env_file '${env_f}' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"refusing"* || "${output}" == *"owned by uid"* || "${output}" == *"9999"* ]]
}

# =============================================================================
# Fix 3: Mid-chain symlink hops: parent dir of every hop is checked
# =============================================================================

@test "Fix3: symlink chain through world-writable dir -> refused" {
    # Setup: safe/l3 -> w777/hop -> safe/f.env
    local safe="${WORK_DIR}/fix3_safe"
    local unsafe="${WORK_DIR}/fix3_w777"
    mkdir -p "${safe}" "${unsafe}"
    chmod 700 "${safe}"
    chmod 777 "${unsafe}"
    printf 'AU_GOLD_IMAGE=SHOULD_NOT_LOAD\n' > "${safe}/f.env"
    chmod 600 "${safe}/f.env"
    # Create intermediate hop symlink in the writable dir
    ln -sf "${safe}/f.env" "${unsafe}/hop"
    # Create the entry-point symlink in safe dir
    ln -sf "${unsafe}/hop" "${safe}/l3"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_source_env_file '${safe}/l3' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"refusing"* || "${output}" == *"writable"* ]]
}

# =============================================================================
# Fix 4: load_config removed from common.sh - only au_load_config exists
# =============================================================================

@test "Fix4: load_config is removed from common.sh (au_load_config only)" {
    run bash -c "
        source '${LIB}'
        declare -F load_config && echo 'PRESENT' || echo 'ABSENT'
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ABSENT"* ]]
    [[ "${output}" != *"PRESENT"* ]]
}

# =============================================================================
# Fix 5: au_render_cfg temp file cleaned on die (EXIT, not RETURN trap)
# =============================================================================

@test "Fix5: au_render_cfg temp file removed after die in rendering" {
    local cfg="${WORK_DIR}/fix5_test.cfg"
    local out="${WORK_DIR}/fix5_out.cfg"
    # Line without '=' triggers S4 die; temp file must not remain
    printf 'patch1.sid=foo\nbadline_no_equals\n' > "${cfg}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export TMPDIR='${BATS_TEST_TMPDIR}'
        source '${LIB}'
        AU_CFG_VARS=()
        au_render_cfg '${cfg}' '' '${out}' 2>&1
    "
    [ "${status}" -ne 0 ]
    # No au_render_* temp file should remain in TMPDIR
    local remaining
    remaining=$(find "${BATS_TEST_TMPDIR}" -maxdepth 1 -name 'au_render_*' 2>/dev/null | head -1)
    [[ -z "${remaining}" ]]
}

# =============================================================================
# Fix 6: au_source_env_file: readonly conflict -> die message on stderr
# =============================================================================

@test "Fix6: au_source_env_file readonly conflict -> die message visible on stderr" {
    local s6_dir="${WORK_DIR}/fix6_test"
    mkdir -p "${s6_dir}"
    chmod 700 "${s6_dir}"
    local env_f="${s6_dir}/ro_trap.env"
    printf 'readonly AU_PLATFORM=WIN64\n' > "${env_f}"
    chmod 600 "${env_f}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PLATFORM='LINUX.X64'
        source '${LIB}'
        au_source_env_file '${env_f}' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"readonly"* ]]
}
