#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Name.......: env.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.02.17
# Revision...: 0.4.0
# Purpose....: Optional odb_autoupgrade environment hook
# Notes......: This file is sourced by OraDBA only when BOTH conditions are met:
#              - ORADBA_EXTENSIONS_SOURCE_ETC=true
#              - .extension contains: load_env: true
#              Default for odb_autoupgrade is load_env: false.
#              Keep this file idempotent.
# ------------------------------------------------------------------------------

_ext_env_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ext_base_dir="$(cd "${_ext_env_dir}/.." && pwd)"

export ODB_AUTOUPGRADE_BASE="${ODB_AUTOUPGRADE_BASE:-${_ext_base_dir}}"
export AUTOUPGRADE_BASE="${AUTOUPGRADE_BASE:-${ODB_AUTOUPGRADE_BASE}}"

if [[ -d "${ODB_AUTOUPGRADE_BASE}/bin" ]]; then
    case ":${PATH}:" in
        *":${ODB_AUTOUPGRADE_BASE}/bin:"*) ;;
        *) PATH="${ODB_AUTOUPGRADE_BASE}/bin:${PATH}" ;;
    esac
    export PATH
fi

unset _ext_env_dir _ext_base_dir
