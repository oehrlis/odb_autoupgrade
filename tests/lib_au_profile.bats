#!/usr/bin/env bats
# shellcheck disable=SC1090
# ------------------------------------------------------------------------------
# tests/lib_au_profile.bats
# BATS tests for profile and edition/group functions in lib/au_env.sh (WP13/WP15)
# ------------------------------------------------------------------------------

load 'test_helper'

LIB=""

setup() {
    setup_helper
    LIB="${REPO_ROOT}/lib/au_lib.sh"
    export LOG_LEVEL=4   # quiet by default; tests override when needed
    # Security check compliance: WORK_DIR must not be group/world-writable
    chmod 700 "${WORK_DIR}"
}

teardown() {
    teardown_helper
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

make_profile() {
    local dir="$1" name="$2"
    shift 2
    mkdir -p "${dir}"
    printf '%s\n' "$@" > "${dir}/${name}.profile"
    chmod 644 "${dir}/${name}.profile"
}

# ---------------------------------------------------------------------------
# au_find_profile: search order
# ---------------------------------------------------------------------------

@test "au_find_profile: explicit path with slash" {
    local pfile="${WORK_DIR}/myprofile.profile"
    cat > "${pfile}" <<'PROF'
AU_PROFILE_DESC="test"
AU_PATCH=RECOMMENDED
AU_TARGET_VERSION=19
AU_PLATFORM=LINUX.X64
AU_GOLD_IMAGE=NO
PROF
    chmod 644 "${pfile}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_find_profile '${pfile}'
        echo \"PATH=\${_AU_PROFILE_PATH}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PATH=${pfile}"* ]]
}

@test "au_find_profile: name found in etc/profiles/" {
    make_profile "${WORK_DIR}/etc/profiles" "testprofile" \
        'AU_PROFILE_DESC="test"' \
        'AU_PATCH=RECOMMENDED' \
        'AU_TARGET_VERSION=19' \
        'AU_PLATFORM=LINUX.X64' \
        'AU_GOLD_IMAGE=NO'
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_find_profile testprofile
        echo \"PATH=\${_AU_PROFILE_PATH}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"testprofile.profile"* ]]
}

@test "au_find_profile: AU_PROFILE_DIR overrides etc/profiles" {
    make_profile "${WORK_DIR}/etc/profiles" "ptest" \
        'AU_PROFILE_DESC="shipped"' 'AU_PATCH=RECOMMENDED' \
        'AU_TARGET_VERSION=19' 'AU_PLATFORM=LINUX.X64' 'AU_GOLD_IMAGE=NO'
    make_profile "${WORK_DIR}/custom_profiles" "ptest" \
        'AU_PROFILE_DESC="custom"' 'AU_PATCH=RU:19.29,OPATCH' \
        'AU_TARGET_VERSION=19' 'AU_PLATFORM=LINUX.X64' 'AU_GOLD_IMAGE=NO'
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PROFILE_DIR='${WORK_DIR}/custom_profiles'
        source '${LIB}'
        au_find_profile ptest
        echo \"PATH=\${_AU_PROFILE_PATH}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"custom_profiles"* ]]
}

@test "au_find_profile: shadowing reported by name" {
    make_profile "${WORK_DIR}/etc/profiles" "dupe" \
        'AU_PROFILE_DESC="shipped"' 'AU_PATCH=RECOMMENDED' \
        'AU_TARGET_VERSION=19' 'AU_PLATFORM=LINUX.X64' 'AU_GOLD_IMAGE=NO'
    make_profile "${WORK_DIR}/custom" "dupe" \
        'AU_PROFILE_DESC="site"' 'AU_PATCH=RU:19.30,OPATCH' \
        'AU_TARGET_VERSION=19' 'AU_PLATFORM=LINUX.X64' 'AU_GOLD_IMAGE=NO'
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        export AU_PROFILE_DIR='${WORK_DIR}/custom'
        export LOG_LEVEL=3
        source '${LIB}'
        au_find_profile dupe 2>&1
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"shadow"* || "${output}" == *"Other"* || "${output}" == *"not used"* ]]
}

@test "au_find_profile: not found -> exit 1 listing dirs" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_find_profile nonexistent_xyz 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"not found"* || "${output}" == *"ERROR"* ]]
}

# ---------------------------------------------------------------------------
# au_apply_profile: allow-list and unknown keys
# ---------------------------------------------------------------------------

@test "au_apply_profile: known keys are applied" {
    local pfile="${WORK_DIR}/valid.profile"
    cat > "${pfile}" <<'PROF'
AU_PROFILE_DESC="desc"
AU_PATCH=RU:19.32,OPATCH
AU_TARGET_VERSION=19
AU_PLATFORM=LINUX.X64
AU_GOLD_IMAGE=NO
PROF
    chmod 644 "${pfile}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_apply_profile '${pfile}'
        echo \"PATCH=\${AU_PATCH}\"
        echo \"VER=\${AU_TARGET_VERSION}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PATCH=RU:19.32,OPATCH"* ]]
    [[ "${output}" == *"VER=19"* ]]
}

@test "au_apply_profile: unknown key -> exit 1" {
    local pfile="${WORK_DIR}/badkey.profile"
    cat > "${pfile}" <<'PROF'
AU_PROFILE_DESC="desc"
AU_PATCH=RECOMMENDED
AU_UNKNOWN_KEY=evil
PROF
    chmod 644 "${pfile}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_apply_profile '${pfile}' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"unknown key"* || "${output}" == *"AU_UNKNOWN_KEY"* ]]
}

@test "au_apply_profile: AU_EDITION=SE2 accepted" {
    local pfile="${WORK_DIR}/se2.profile"
    cat > "${pfile}" <<'PROF'
AU_PROFILE_DESC="SE2"
AU_PATCH=RECOMMENDED
AU_TARGET_VERSION=19
AU_PLATFORM=LINUX.X64
AU_GOLD_IMAGE=NO
AU_EDITION=SE2
PROF
    chmod 644 "${pfile}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_apply_profile '${pfile}'
        echo \"EDITION=\${AU_EDITION}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"EDITION=SE2"* ]]
}

@test "au_apply_profile: invalid AU_GOLD_IMAGE -> exit 1" {
    local pfile="${WORK_DIR}/badgi.profile"
    cat > "${pfile}" <<'PROF'
AU_PROFILE_DESC="bad"
AU_PATCH=RECOMMENDED
AU_TARGET_VERSION=19
AU_PLATFORM=LINUX.X64
AU_GOLD_IMAGE=MAYBE
PROF
    chmod 644 "${pfile}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_apply_profile '${pfile}' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"AU_GOLD_IMAGE"* || "${output}" == *"YES|NO|AUTO|ALL"* ]]
}

@test "au_apply_profile: file security - group/world-writable -> exit 1" {
    local pfile="${WORK_DIR}/ww.profile"
    cat > "${pfile}" <<'PROF'
AU_PROFILE_DESC="ww"
AU_PATCH=RECOMMENDED
PROF
    chmod 666 "${pfile}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_apply_profile '${pfile}' 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"writable"* || "${output}" == *"refusing"* || "${output}" == *"ERROR"* ]]
}

# ---------------------------------------------------------------------------
# au_validate_profile: keyword rules
# ---------------------------------------------------------------------------

@test "au_validate_profile: JDK, OCW, GI accepted without warning (F14)" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_PATCH='RU:19.28,OPATCH,OJVM,DPBP,MRP,JDK,OCW,JDK:19.28,OCW:19.28'
        export AU_TARGET_VERSION=19
        export AU_PLATFORM=LINUX.X64
        au_validate_profile 2>&1
        AU_PATCH='GI,GI:19.28,MRP,OPATCH' au_validate_profile 2>&1
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"unknown keyword"* ]]
}

@test "au_validate_profile: unknown keyword still warns (F14)" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_PATCH='RU:19.28,OPATCH,JDKX'
        export AU_TARGET_VERSION=19
        export AU_PLATFORM=LINUX.X64
        au_validate_profile 2>&1
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"unknown keyword 'JDKX'"* ]]
}

@test "au_validate_profile: CSPU on LINUX.X64 for 19c -> exit 1" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_PATCH='RU:19.28,OPATCH,CSPU'
        export AU_TARGET_VERSION=19
        export AU_PLATFORM=LINUX.X64
        au_validate_profile 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CSPU"* && "${output}" == *"Linux"* ]]
}

@test "au_validate_profile: CSPU on LINUX.X64 for 23c -> exit 1" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_PATCH='RU:23.5,OPATCH,CSPU'
        export AU_TARGET_VERSION=23
        export AU_PLATFORM=LINUX.X64
        au_validate_profile 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CSPU"* ]]
}

@test "au_validate_profile: CSPU on 21c LINUX.X64 is valid" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_PATCH='RU:21.3,OPATCH,CSPU'
        export AU_TARGET_VERSION=21
        export AU_PLATFORM=LINUX.X64
        au_validate_profile 2>&1
    "
    [ "${status}" -eq 0 ]
}

@test "au_validate_profile: MRP with version number -> exit 1" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_PATCH='RU:19.28,OPATCH,MRP:19.28'
        export AU_TARGET_VERSION=19
        export AU_PLATFORM=LINUX.X64
        au_validate_profile 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"MRP"* && "${output}" == *"version"* ]]
}

@test "au_validate_profile: DPBP with version number -> exit 1" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_PATCH='RU:19.28,OPATCH,DPBP:19.28'
        export AU_TARGET_VERSION=19
        export AU_PLATFORM=LINUX.X64
        au_validate_profile 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"DPBP"* ]]
}

@test "au_validate_profile: OJVM mismatch RU:19.28 vs OJVM:19.27 -> exit 1" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_PATCH='RU:19.28,OPATCH,OJVM:19.27'
        export AU_TARGET_VERSION=19
        export AU_PLATFORM=LINUX.X64
        au_validate_profile 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"OJVM"* || "${output}" == *"match"* ]]
}

@test "au_validate_profile: OJVM:19.28 matches RU:19.28 -> pass" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_PATCH='RU:19.28,OPATCH,OJVM:19.28,DPBP,MRP'
        export AU_TARGET_VERSION=19
        export AU_PLATFORM=LINUX.X64
        au_validate_profile 2>&1
    "
    [ "${status}" -eq 0 ]
}

@test "au_validate_profile: MRP on 21c -> exit 1" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_PATCH='RU:21.3,OPATCH,MRP'
        export AU_TARGET_VERSION=21
        export AU_PLATFORM=LINUX.X64
        au_validate_profile 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"MRP"* && "${output}" == *"21c"* ]]
}

@test "au_validate_profile: RECOMMENDED + RU:x.y -> exit 1" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_PATCH='RECOMMENDED,RU:19.28,OPATCH'
        export AU_TARGET_VERSION=19
        export AU_PLATFORM=LINUX.X64
        au_validate_profile 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"RECOMMENDED"* && "${output}" == *"RU"* ]]
}

@test "au_validate_profile: plain patch number accepted" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_PATCH='RU:19.32,OPATCH,OJVM:19.32,DPBP,37056207'
        export AU_TARGET_VERSION=19
        export AU_PLATFORM=LINUX.X64
        au_validate_profile 2>&1
    "
    [ "${status}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# WP15: Edition defaults
# ---------------------------------------------------------------------------

@test "au_set_edition_defaults: no source home -> defaults to EE" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        unset AU_EDITION AU_SOURCE_HOME 2>/dev/null || true
        export AU_SOURCE_HOME=''
        au_set_edition_defaults
        echo \"EDITION=\${AU_EDITION}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"EDITION=EE"* ]]
}

@test "au_set_edition_defaults: with source home -> AU_EDITION stays empty" {
    mkdir -p "${WORK_DIR}/fake_oh"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        unset AU_EDITION 2>/dev/null || true
        export AU_SOURCE_HOME='${WORK_DIR}/fake_oh'
        au_set_edition_defaults
        echo \"EDITION=\${AU_EDITION:-UNSET}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"EDITION=UNSET"* ]]
}

@test "au_set_edition_defaults: SE2 set explicitly -> accepted" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_EDITION=SE2
        export AU_SOURCE_HOME=''
        au_set_edition_defaults
        echo \"EDITION=\${AU_EDITION}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"EDITION=SE2"* ]]
}

@test "au_set_edition_defaults: invalid edition -> exit 1" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_EDITION=ENTERPRISE
        export AU_SOURCE_HOME=''
        au_set_edition_defaults 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"EE"* || "${output}" == *"SE2"* || "${output}" == *"invalid"* ]]
}

# ---------------------------------------------------------------------------
# WP15: Group defaults
# ---------------------------------------------------------------------------

@test "au_set_group_defaults: no source home -> defaults applied" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_SOURCE_HOME=''
        unset AU_GROUP_OSDBA AU_GROUP_OSOPER 2>/dev/null || true
        au_set_group_defaults
        echo \"DBA=\${AU_GROUP_OSDBA}\"
        echo \"OPER=\${AU_GROUP_OSOPER}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DBA=dba"* ]]
    [[ "${output}" == *"OPER=oper"* ]]
}

@test "au_set_group_defaults: caller value wins over default" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_SOURCE_HOME=''
        export AU_GROUP_OSDBA=osdba
        unset AU_GROUP_OSOPER 2>/dev/null || true
        au_set_group_defaults
        echo \"DBA=\${AU_GROUP_OSDBA}\"
        echo \"OPER=\${AU_GROUP_OSOPER}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DBA=osdba"* ]]
    [[ "${output}" == *"OPER=oper"* ]]
}

@test "au_set_group_defaults: with source home -> groups stay empty" {
    mkdir -p "${WORK_DIR}/fake_oh"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_SOURCE_HOME='${WORK_DIR}/fake_oh'
        unset AU_GROUP_OSDBA AU_GROUP_OSOPER 2>/dev/null || true
        au_set_group_defaults
        echo \"DBA=\${AU_GROUP_OSDBA:-UNSET}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DBA=UNSET"* ]]
}

# ---------------------------------------------------------------------------
# WP15: Group derivation from config.c
# ---------------------------------------------------------------------------

@test "au_derive_groups_from_config_c: reads SS_DBA_GRP etc." {
    local cfg="${REPO_ROOT}/tests/fixtures/config_c_sample.c"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        unset AU_GROUP_OSDBA AU_GROUP_OSOPER AU_GROUP_OSBACKUPDBA 2>/dev/null || true
        unset AU_GROUP_OSDGDBA AU_GROUP_OSKMDBA AU_GROUP_OSRACDBA 2>/dev/null || true
        au_derive_groups_from_config_c '${cfg}'
        echo \"DBA=\${AU_GROUP_OSDBA}\"
        echo \"OPER=\${AU_GROUP_OSOPER}\"
        echo \"BKP=\${AU_GROUP_OSBACKUPDBA}\"
        echo \"DGD=\${AU_GROUP_OSDGDBA}\"
        echo \"KMT=\${AU_GROUP_OSKMDBA}\"
        echo \"RAC=\${AU_GROUP_OSRACDBA}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DBA=dba"* ]]
    [[ "${output}" == *"OPER=oper"* ]]
    [[ "${output}" == *"BKP=backupdba"* ]]
    [[ "${output}" == *"DGD=dgdba"* ]]
    [[ "${output}" == *"KMT=kmdba"* ]]
    [[ "${output}" == *"RAC=racdba"* ]]
}

@test "au_derive_groups_from_config_c: caller value wins" {
    local cfg="${REPO_ROOT}/tests/fixtures/config_c_sample.c"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_GROUP_OSDBA=custom_dba
        au_derive_groups_from_config_c '${cfg}'
        echo \"DBA=\${AU_GROUP_OSDBA}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DBA=custom_dba"* ]]
}

# ---------------------------------------------------------------------------
# WP15: Group membership pre-check
# ---------------------------------------------------------------------------

@test "au_check_group_membership: user in own primary group passes" {
    # Get the current user's primary group
    local mygroup
    mygroup=$(id -gn)
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_GROUP_OSDBA='${mygroup}'
        unset AU_GROUP_OSOPER AU_GROUP_OSBACKUPDBA AU_GROUP_OSDGDBA \
              AU_GROUP_OSKMDBA AU_GROUP_OSRACDBA 2>/dev/null || true
        au_check_group_membership 2>&1
    "
    [ "${status}" -eq 0 ]
}

@test "au_check_group_membership: non-existent group -> exit 1" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_GROUP_OSDBA='totally_nonexistent_group_xyz_9999'
        unset AU_GROUP_OSOPER AU_GROUP_OSBACKUPDBA AU_GROUP_OSDGDBA \
              AU_GROUP_OSKMDBA AU_GROUP_OSRACDBA 2>/dev/null || true
        au_check_group_membership 2>&1
    "
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"totally_nonexistent_group_xyz_9999"* ]]
}

@test "au_check_group_membership: empty group vars skipped" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        unset AU_GROUP_OSDBA AU_GROUP_OSOPER AU_GROUP_OSBACKUPDBA \
              AU_GROUP_OSDGDBA AU_GROUP_OSKMDBA AU_GROUP_OSRACDBA 2>/dev/null || true
        export AU_GROUP_OSDBA=''
        au_check_group_membership 2>&1
    "
    [ "${status}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# MUST: au_apply_profile - full Decision-5 security checks (regression)
# ---------------------------------------------------------------------------

@test "au_apply_profile: profile in g+w dir -> refused" {
    local safe_dir="${WORK_DIR}/safe_profiles"
    local bad_dir="${WORK_DIR}/bad_profiles"
    mkdir -p "${safe_dir}" "${bad_dir}"
    # Make the parent dir group-writable
    chmod 775 "${bad_dir}"
    local pfile="${bad_dir}/insecure.profile"
    cat > "${pfile}" <<'PROF'
AU_PROFILE_DESC="insecure"
AU_PATCH=RECOMMENDED
PROF
    chmod 644 "${pfile}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_apply_profile '${pfile}' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"writable"* || "${output}" == *"refusing"* || "${output}" == *"ERROR"* ]]
}

@test "au_apply_profile: symlinked profile via 777 hop -> refused" {
    local real_dir="${WORK_DIR}/real_profiles"
    local hop_dir="${WORK_DIR}/hop_dir_777"
    mkdir -p "${real_dir}" "${hop_dir}"
    chmod 777 "${hop_dir}"
    local real_file="${real_dir}/real.profile"
    cat > "${real_file}" <<'PROF'
AU_PROFILE_DESC="real"
AU_PATCH=RECOMMENDED
PROF
    chmod 644 "${real_file}"
    # Symlink: profiles/via_hop.profile -> hop_dir_777/link_target.profile -> real.profile
    ln -s "${real_file}" "${hop_dir}/link_target.profile"
    mkdir -p "${WORK_DIR}/profiles"
    chmod 700 "${WORK_DIR}/profiles"
    ln -s "${hop_dir}/link_target.profile" "${WORK_DIR}/profiles/via_hop.profile"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_apply_profile '${WORK_DIR}/profiles/via_hop.profile' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"writable"* || "${output}" == *"refusing"* || "${output}" == *"ERROR"* ]]
}

@test "au_apply_profile: stat stub returning empty -> refused" {
    # Override stat in PATH so it returns nothing (simulates stat failure)
    local stub_dir="${WORK_DIR}/stat_stubs"
    mkdir -p "${stub_dir}"
    chmod 700 "${stub_dir}"
    # Stub that exits 0 but prints nothing (empty output = fail-closed)
    cat > "${stub_dir}/stat" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${stub_dir}/stat"
    local pfile="${WORK_DIR}/test.profile"
    cat > "${pfile}" <<'PROF'
AU_PROFILE_DESC="test"
AU_PATCH=RECOMMENDED
PROF
    chmod 644 "${pfile}"
    run bash -c "
        export PATH='${stub_dir}:${PATH}'
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_apply_profile '${pfile}' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"stat"* || "${output}" == *"owner"* || "${output}" == *"refusing"* || "${output}" == *"ERROR"* ]]
}

@test "au_apply_profile: normal profile in safe dir -> applied" {
    local pdir="${WORK_DIR}/safe_dir"
    mkdir -p "${pdir}"
    chmod 700 "${pdir}"
    local pfile="${pdir}/normal.profile"
    cat > "${pfile}" <<'PROF'
AU_PROFILE_DESC="safe"
AU_PATCH=RU:19.32,OPATCH
AU_TARGET_VERSION=19
AU_PLATFORM=LINUX.X64
AU_GOLD_IMAGE=NO
PROF
    chmod 644 "${pfile}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_apply_profile '${pfile}'
        echo \"PATCH=\${AU_PATCH}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PATCH=RU:19.32,OPATCH"* ]]
}

# ---------------------------------------------------------------------------
# SHOULD: Pin vs profile precedence
# ---------------------------------------------------------------------------

@test "au_read_pin: pin wins over profile AU_PATCH" {
    mkdir -p "${WORK_DIR}/patches"
    chmod 700 "${WORK_DIR}/patches"
    printf 'AU_PATCH=RU:19.32,OPATCH\n' > "${WORK_DIR}/patches/au_patch.env"
    chmod 600 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        # Simulate profile having set AU_PATCH and the flag
        export AU_PATCH=RECOMMENDED
        _au_patch_from_profile=true
        export AU_DOWNLOAD_FOLDER='${WORK_DIR}/patches'
        au_read_pin
        echo \"PATCH=\${AU_PATCH}\"
        echo \"PINNED=\${_au_patch_pinned}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PATCH=RU:19.32,OPATCH"* ]]
    [[ "${output}" == *"PINNED=true"* ]]
}

@test "au_read_pin: caller env AU_PATCH is not overridden by pin, warns" {
    mkdir -p "${WORK_DIR}/patches"
    chmod 700 "${WORK_DIR}/patches"
    printf 'AU_PATCH=RU:19.32,OPATCH\n' > "${WORK_DIR}/patches/au_patch.env"
    chmod 600 "${WORK_DIR}/patches/au_patch.env"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        export AU_PATCH=RECOMMENDED
        _au_patch_from_profile=false
        export AU_DOWNLOAD_FOLDER='${WORK_DIR}/patches'
        au_read_pin
        echo \"PATCH=\${AU_PATCH}\"
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PATCH=RECOMMENDED"* ]]
    [[ "${output}" == *"caller"* || "${output}" == *"WARN"* || "${output}" == *"pin"* ]]
}

# ---------------------------------------------------------------------------
# SHOULD: Profile value validation
# ---------------------------------------------------------------------------

@test "au_apply_profile: invalid AU_TARGET_VERSION -> exit 1" {
    local pdir="${WORK_DIR}/val_dir"
    mkdir -p "${pdir}"
    chmod 700 "${pdir}"
    local pfile="${pdir}/badver.profile"
    cat > "${pfile}" <<'PROF'
AU_PROFILE_DESC="bad version"
AU_PATCH=RECOMMENDED
AU_TARGET_VERSION=1920
PROF
    chmod 644 "${pfile}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_apply_profile '${pfile}' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"AU_TARGET_VERSION"* || "${output}" == *"2-digit"* || "${output}" == *"ERROR"* ]]
}

@test "au_apply_profile: invalid AU_PLATFORM -> exit 1" {
    local pdir="${WORK_DIR}/plat_dir"
    mkdir -p "${pdir}"
    chmod 700 "${pdir}"
    local pfile="${pdir}/badplat.profile"
    cat > "${pfile}" <<'PROF'
AU_PROFILE_DESC="bad platform"
AU_PATCH=RECOMMENDED
AU_TARGET_VERSION=19
AU_PLATFORM=linux.x64
PROF
    chmod 644 "${pfile}"
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        au_apply_profile '${pfile}' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"AU_PLATFORM"* || "${output}" == *"ERROR"* ]]
}

# ---------------------------------------------------------------------------
# SHOULD: Group name validation
# ---------------------------------------------------------------------------

@test "_au_validate_group_name: valid group name passes" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        _au_validate_group_name 'dba' 'AU_GROUP_OSDBA'
        echo 'OK'
    " 2>&1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"OK"* ]]
}

@test "_au_validate_group_name: too-long group name -> exit 1" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        _au_validate_group_name 'this_group_name_is_way_too_long_xyz' 'AU_GROUP_OSDBA' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Invalid"* || "${output}" == *"ERROR"* ]]
}

@test "_au_validate_group_name: special chars -> exit 1" {
    run bash -c "
        export AUTOUPGRADE_BASE='${WORK_DIR}'
        source '${LIB}'
        _au_validate_group_name 'dba;evil' 'AU_GROUP_OSDBA' 2>&1
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Invalid"* || "${output}" == *"ERROR"* ]]
}

# ---------------------------------------------------------------------------
# Shipped profiles (F14, F15)
# ---------------------------------------------------------------------------

@test "shipped profiles: apply and validate without unknown-keyword warning (F14)" {
    local p name
    for p in "${REPO_ROOT}"/etc/profiles/*.profile; do
        name="${p##*/}"
        # copy: the check must not depend on the checkout's directory mode
        install -m 600 "${p}" "${WORK_DIR}/${name}"
        run bash -c "
            export AUTOUPGRADE_BASE='${WORK_DIR}'
            source '${LIB}'
            au_apply_profile '${WORK_DIR}/${name}'
            au_validate_profile 2>&1
        "
        [ "${status}" -eq 0 ] || { echo "${name}: ${output}"; return 1; }
        [[ "${output}" != *"unknown keyword"* ]] || { echo "${name}: ${output}"; return 1; }
    done
}

@test "shipped cputest-example: MRP keyword, no placeholder patch number (F15)" {
    local p="${REPO_ROOT}/etc/profiles/cputest-example.profile"
    grep -qx 'AU_PATCH=RU:19.32,OPATCH,OJVM:19.32,DPBP,JDK,MRP' "${p}"
    run grep -c '99999999' "${p}"
    [ "${output}" = "0" ]
    grep -q '^# Record\.*: MOS MRP' "${p}"
}
