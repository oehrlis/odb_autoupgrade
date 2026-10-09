#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Module.....: au_lib.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.10.09
# Version....: v0.6.0
# Purpose....: Library loader for AutoUpgrade wrapper scripts .
#              Sources: lib/common.sh, lib/au_env.sh, lib/au_net.sh,
#                       lib/au_tools.sh.
#              All AU_* functions remain available to callers that source this
#              file directly; function definitions now live in the sub-modules.
# Notes......: Requires bash 4.2+ (enforced by common.sh at load time).
# Reference..: https://github.com/oehrlis/odb_autoupgrade
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.08 oehrli - initial version, extracted from bin/run_autoupgrade.sh
# 2026.10.09 oehrli - WP1 refactor: convert to pure loader, move all functions
#                     to common.sh / au_env.sh / au_net.sh / au_tools.sh
# ------------------------------------------------------------------------------

# Guard on function existence (au_load_config is defined last, by au_env.sh).
# Cannot be bypassed by pre-setting an env var.
declare -F au_load_config >/dev/null 2>&1 && return 0

# Locate sibling modules relative to this file (works when sourced from any CWD)
_AU_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Load generic framework (bash 4.2 check, log_*, die, setup_error_handling, ...)
if [[ ! -f "${_AU_LIB_DIR}/common.sh" ]]; then
    echo "ERROR: Cannot find common.sh in ${_AU_LIB_DIR}" >&2
    exit 1
fi
# shellcheck source=lib/common.sh
. "${_AU_LIB_DIR}/common.sh"

# Load environment / config module (au_source_env_file, au_load_config,
# au_set_defaults, au_check_cfg_vars, au_render_cfg, au_check_cfg_mode)
if [[ ! -f "${_AU_LIB_DIR}/au_env.sh" ]]; then
    echo "ERROR: Cannot find au_env.sh in ${_AU_LIB_DIR}" >&2
    exit 1
fi
# shellcheck source=lib/au_env.sh
. "${_AU_LIB_DIR}/au_env.sh"

# Load network / JVM module (au_resolve_java, au_build_proxy_opts,
# au_resolve_truststore, au_build_jvm_opts, au_convert_no_proxy)
if [[ ! -f "${_AU_LIB_DIR}/au_net.sh" ]]; then
    echo "ERROR: Cannot find au_net.sh in ${_AU_LIB_DIR}" >&2
    exit 1
fi
# shellcheck source=lib/au_net.sh
. "${_AU_LIB_DIR}/au_net.sh"

# Load tools module (au_jar_version, au_keystore_state, au_log_scan)
if [[ ! -f "${_AU_LIB_DIR}/au_tools.sh" ]]; then
    echo "ERROR: Cannot find au_tools.sh in ${_AU_LIB_DIR}" >&2
    exit 1
fi
# shellcheck source=lib/au_tools.sh
. "${_AU_LIB_DIR}/au_tools.sh"

unset _AU_LIB_DIR
